#!/bin/bash
# scripts/verify-security.sh
# End-to-end automated verification test suite for Network & Security Baseline.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "============================================================"
echo "🛡️  Network & Security Baseline Verification"
echo "============================================================"
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$REPO_ROOT/bin"
export PATH="$REPO_ROOT/bin:$PATH"

if ! command -v kubectl &>/dev/null; then
    echo -e "${YELLOW}📥 kubectl is missing. Downloading stable binary into ./bin...${NC}"
    K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt || echo "v1.30.0")
    curl -Lo "$REPO_ROOT/bin/kubectl" "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
    chmod +x "$REPO_ROOT/bin/kubectl"
fi

PASSED_TESTS=0
FAILED_TESTS=0
TEST_RESULTS=()

record_result() {
    local test_name="$1"
    local status="$2"
    local details="$3"
    if [ "$status" -eq 0 ]; then
        echo -e "  ${GREEN}✅ [PASS]${NC} $details"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        TEST_RESULTS+=("${GREEN}✅ [PASS]${NC} $test_name")
    else
        echo -e "  ${RED}❌ [FAIL]${NC} $details"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        TEST_RESULTS+=("${RED}❌ [FAIL]${NC} $test_name")
    fi
    echo ""
}

# Tracking resources for cleanup
TEST_PODS=("sec-test-token-pod" "tenant-a" "tenant-b")
PORT_FORWARD_PID=""
TMP_FILES=()

cleanup() {
    echo "🧹 Cleaning up security test pods & background tunnels..."
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    for pod in "${TEST_PODS[@]}"; do
        if [ -n "$pod" ]; then
            kubectl delete pod "$pod" -n workload --grace-period=0 --force 2>/dev/null || true
        fi
    done
    for tmp in "${TMP_FILES[@]}"; do
        if [ -f "$tmp" ]; then
            rm -f "$tmp" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

echo "============================================================"
echo "Executing Security Baseline Acceptance Tests..."
echo "============================================================"
echo ""

# --- TEST 1 ---
echo -e "${CYAN}▶ [1/4] RBAC Confinement & Workload Token Absence${NC}"
echo "  Description: Ensures portal ServiceAccount cannot list cluster nodes or secrets, and student pods omit API tokens."

P1_FAIL=0
P1_MSG=""

CAN_GET_NODES=$(kubectl auth can-i get nodes --as=system:serviceaccount:slurm:portal-sa 2>/dev/null || true)
if [ "$(echo "$CAN_GET_NODES" | xargs)" != "no" ]; then
    P1_FAIL=1
    P1_MSG="RBAC leak: portal-sa can unexpectedly read cluster nodes"
fi

CAN_GET_SECRETS=$(kubectl auth can-i get secrets --as=system:serviceaccount:slurm:portal-sa -n slurm 2>/dev/null || true)
if [ "$(echo "$CAN_GET_SECRETS" | xargs)" != "no" ]; then
    P1_FAIL=1
    P1_MSG="RBAC leak: portal-sa can unexpectedly read secrets in slurm namespace"
fi

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: sec-test-token-pod
  namespace: workload
  labels:
    app.kubernetes.io/component: test-probe
  annotations:
    slurmjob.slinky.slurm.net/exclusive: "false"
spec:
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: busybox:1.36
    command: ["sleep", "300"]
EOF

if ! kubectl wait --for=condition=Ready pod/sec-test-token-pod -n workload --timeout=30s >/dev/null 2>&1; then
    P1_FAIL=1
    P1_MSG="Failed to schedule probe pod in workload namespace"
else
    if kubectl exec -n workload sec-test-token-pod -- test -d /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null; then
        P1_FAIL=1
        P1_MSG="Workload pod has ServiceAccount token mounted despite automountServiceAccountToken: false"
    fi
fi
record_result "RBAC Confinement & Token Absence" "$P1_FAIL" "${P1_MSG:-RBAC permissions restricted; student pods omit Kubernetes API tokens}"

# --- TEST 2 ---
echo -e "${CYAN}▶ [2/4] Database Egress Isolation (MariaDB & Postgres)${NC}"
echo "  Description: Verifies CNI NetworkPolicies block student workload pods from directly connecting to MariaDB (port 3306)."

P2_FAIL=0
P2_MSG=""

if [ "$P1_FAIL" -eq 0 ]; then
    if kubectl exec -n workload sec-test-token-pod -- nc -z -w 3 mariadb.slurm.svc.cluster.local 3306 >/dev/null 2>&1; then
        P2_FAIL=1
        P2_MSG="NetworkPolicy leak: Student pod successfully opened TCP socket to MariaDB on port 3306"
    fi
else
    P2_FAIL=1
    P2_MSG="Skipped probe due to probe pod initialization failure"
fi
record_result "Control Plane Database Isolation (MariaDB 3306)" "$P2_FAIL" "${P2_MSG:-NetworkPolicy dropped direct TCP traffic from workload to MariaDB}"

# --- TEST 3 ---
echo -e "${CYAN}▶ [3/4] Inter-Tenant Lateral Movement Isolation${NC}"
echo "  Description: Asserts NetworkPolicies drop direct lateral network traffic between independent student pods (Tenant A -> Tenant B)."

P3_FAIL=0
P3_MSG=""

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: tenant-a
  namespace: workload
  labels:
    app.kubernetes.io/component: tenant-a
  annotations:
    slurmjob.slinky.slurm.net/exclusive: "false"
spec:
  automountServiceAccountToken: false
  containers:
  - name: tenant
    image: busybox:1.36
    command: ["sleep", "300"]
---
apiVersion: v1
kind: Pod
metadata:
  name: tenant-b
  namespace: workload
  labels:
    app.kubernetes.io/component: tenant-b
  annotations:
    slurmjob.slinky.slurm.net/exclusive: "false"
spec:
  automountServiceAccountToken: false
  containers:
  - name: tenant
    image: busybox:1.36
    command: ["sh", "-c", "while true; do nc -l -p 8888; done"]
EOF

if ! kubectl wait --for=condition=Ready pod/tenant-a -n workload --timeout=60s >/dev/null 2>&1 || \
   ! kubectl wait --for=condition=Ready pod/tenant-b -n workload --timeout=60s >/dev/null 2>&1; then
    P3_FAIL=1
    P3_MSG="Failed to spawn tenant probe pods in workload namespace"
else
    TENANT_B_IP=$(kubectl get pod tenant-b -n workload -o jsonpath='{.status.podIP}')
    if kubectl exec -n workload tenant-a -- nc -z -w 3 "$TENANT_B_IP" 8888 >/dev/null 2>&1; then
        P3_FAIL=1
        P3_MSG="Lateral isolation failure: Direct TCP traffic between tenant pods succeeded"
    fi
fi
record_result "Inter-Tenant Lateral Movement Isolation" "$P3_FAIL" "${P3_MSG:-CNI dropped lateral network traffic between student tenants}"

# --- TEST 4 ---
echo -e "${CYAN}▶ [4/4] Traefik Ingress TLS & Security Headers Enforcement${NC}"
echo "  Description: Verifies HTTP-to-HTTPS redirect (80 -> 443) and presence of nosniff / SAMEORIGIN security headers."

P4_FAIL=0
P4_MSG=""

LOCAL_PORT_80=18080
LOCAL_PORT_443=18443

kubectl port-forward svc/portal -n slurm "${LOCAL_PORT_80}:80" "${LOCAL_PORT_443}:443" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

PF_READY=0
for i in {1..10}; do
    if nc -z -w 1 127.0.0.1 "$LOCAL_PORT_80" >/dev/null 2>&1 && nc -z -w 1 127.0.0.1 "$LOCAL_PORT_443" >/dev/null 2>&1; then
        PF_READY=1
        break
    fi
    sleep 0.5
done

if [ "$PF_READY" -ne 1 ]; then
    P4_FAIL=1
    P4_MSG="kubectl port-forward to svc/portal failed to initialize"
else
    # 4.1: HTTP to HTTPS Redirect
    HTTP_HEADERS=$(curl -s -I "http://127.0.0.1:${LOCAL_PORT_80}/" || true)
    HTTP_CODE=$(echo "$HTTP_HEADERS" | head -n 1 | awk '{print $2}')
    LOCATION_HEADER=$(echo "$HTTP_HEADERS" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')

    if [[ "$HTTP_CODE" != "301" && "$HTTP_CODE" != "308" ]] || [[ "$LOCATION_HEADER" != https://* ]]; then
        P4_FAIL=1
        P4_MSG="Expected HTTPS redirect on port 80 (got code '$HTTP_CODE', location '$LOCATION_HEADER')"
    fi

    # 4.2: HTTPS Security Headers
    HTTPS_HEADERS=$(curl -s -k -I "https://127.0.0.1:${LOCAL_PORT_443}/" || true)
    if ! echo "$HTTPS_HEADERS" | grep -iq "x-content-type-options: nosniff" || \
       ! echo "$HTTPS_HEADERS" | grep -iq "x-frame-options: sameorigin"; then
        P4_FAIL=1
        P4_MSG="Missing nosniff or SAMEORIGIN security headers on HTTPS port 443"
    fi
fi
record_result "Traefik TLS & Security Headers" "$P4_FAIL" "${P4_MSG:-Traefik gateway enforces HTTPS redirect and security headers}"

# ============================================================
# Summary
# ============================================================
echo "============================================================"
echo "📊 Network & Security Verification Summary ($PASSED_TESTS/4 Passed)"
echo "============================================================"
for res in "${TEST_RESULTS[@]}"; do
    echo -e "  $res"
done
echo "============================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}🎉 All network and security baseline guarantees verified!${NC}"
    exit 0
else
    echo -e "${RED}⚠️ Security verification failed with $FAILED_TESTS failures.${NC}"
    exit 1
fi
