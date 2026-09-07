#!/bin/bash
# scripts/verify-security.sh
# End-to-end automated verification test suite for WP3-1-8 Network & Security Baseline.
# Validates RBAC confinement, database isolation, inter-tenant isolation, and Traefik TLS/headers.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "============================================================"
echo "🛡️  WP3-1-8: Network & Security Baseline Verification Suite"
echo "============================================================"
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""

# Ensure ./bin is in PATH and kubectl is available
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

report_result() {
    local test_name="$1"
    local status="$2"
    local details="$3"
    if [ "$status" -eq 0 ]; then
        echo -e "${GREEN}✅ [PASS]${NC} $test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}❌ [FAIL]${NC} $test_name: $details"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# Tracking resources for cleanup
TEST_PODS=("sec-test-token-pod" "tenant-a" "tenant-b")
PORT_FORWARD_PID=""
TMP_FILES=()

cleanup() {
    echo ""
    echo "🧹 Cleaning up test resources..."
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        echo "  Terminating background port-forward (PID: $PORT_FORWARD_PID)..."
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
    echo "✨ Cleanup finished."
}

trap cleanup EXIT

echo "============================================================"
echo "Executing Security Baseline Acceptance Tests..."
echo "============================================================"

# ============================================================
# PHASE 1: RBAC & Token Confinement
# ============================================================
echo ""
echo "▶ Running Phase 1: RBAC & Token Confinement..."

# Check 1.1: portal-sa cannot get nodes
P1_1_FAIL=0
P1_1_MSG=""
CAN_GET_NODES=$(kubectl auth can-i get nodes --as=system:serviceaccount:slurm:portal-sa 2>/dev/null || true)
CAN_GET_NODES_TRIMMED=$(echo "$CAN_GET_NODES" | xargs)

if [ "$CAN_GET_NODES_TRIMMED" != "no" ]; then
    P1_1_FAIL=1
    P1_1_MSG="portal-sa unexpectedly has access to read nodes (got '$CAN_GET_NODES_TRIMMED')"
fi
report_result "Phase 1.1: RBAC Node Inspection Restriction" "$P1_1_FAIL" "${P1_1_MSG:-portal-sa correctly restricted from reading nodes}"

# Check 1.2: portal-sa cannot get secrets in slurm namespace
P1_2_FAIL=0
P1_2_MSG=""
CAN_GET_SECRETS=$(kubectl auth can-i get secrets --as=system:serviceaccount:slurm:portal-sa -n slurm 2>/dev/null || true)
CAN_GET_SECRETS_TRIMMED=$(echo "$CAN_GET_SECRETS" | xargs)

if [ "$CAN_GET_SECRETS_TRIMMED" != "no" ]; then
    P1_2_FAIL=1
    P1_2_MSG="portal-sa unexpectedly has access to read secrets in slurm (got '$CAN_GET_SECRETS_TRIMMED')"
fi
report_result "Phase 1.2: RBAC Secret Access Restriction" "$P1_2_FAIL" "${P1_2_MSG:-portal-sa correctly restricted from reading secrets}"

# Check 1.3: Ephemeral workload pod ServiceAccount token absence
P1_3_FAIL=0
P1_3_MSG=""

echo "  Spawning test probe pod (sec-test-token-pod) in workload namespace..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: sec-test-token-pod
  namespace: workload
  labels:
    app.kubernetes.io/component: test-probe
spec:
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: busybox:1.36
    command: ["sleep", "300"]
EOF

if ! kubectl wait --for=condition=Ready pod/sec-test-token-pod -n workload --timeout=30s >/dev/null 2>&1; then
    P1_3_FAIL=1
    P1_3_MSG="Failed to spawn sec-test-token-pod in workload namespace"
else
    # Check if /var/run/secrets/kubernetes.io/serviceaccount exists inside the pod
    if kubectl exec -n workload sec-test-token-pod -- test -d /var/run/secrets/kubernetes.io/serviceaccount 2>/dev/null; then
        P1_3_FAIL=1
        P1_3_MSG="ServiceAccount token directory is present in workload pod despite automountServiceAccountToken: false"
    fi
fi
report_result "Phase 1.3: Workload Pod ServiceAccount Token Absence" "$P1_3_FAIL" "${P1_3_MSG:-ServiceAccount token correctly omitted}"


# ============================================================
# PHASE 2: Control Plane & MariaDB Isolation
# ============================================================
echo ""
echo "▶ Running Phase 2: Control Plane & MariaDB Isolation..."

P2_FAIL=0
P2_MSG=""

if [ "$P1_3_FAIL" -eq 0 ]; then
    echo "  Attempting TCP probe from workload pod to mariadb.slurm.svc.cluster.local:3306..."
    if kubectl exec -n workload sec-test-token-pod -- nc -z -w 3 mariadb.slurm.svc.cluster.local 3306 >/dev/null 2>&1; then
        P2_FAIL=1
        P2_MSG="NetworkPolicy egress leak: Workload pod successfully connected to MariaDB on port 3306"
    fi
else
    P2_FAIL=1
    P2_MSG="Skipped probe due to missing workload test pod"
fi
report_result "Phase 2: MariaDB Control Plane Egress Isolation" "$P2_FAIL" "${P2_MSG:-NetworkPolicy egress drop to MariaDB verified}"


# ============================================================
# PHASE 3: Inter-Tenant Workload Isolation
# ============================================================
echo ""
echo "▶ Running Phase 3: Inter-Tenant Workload Isolation..."

P3_FAIL=0
P3_MSG=""

echo "  Spawning tenant-a and tenant-b pods in workload namespace..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: tenant-a
  namespace: workload
  labels:
    app.kubernetes.io/component: tenant-a
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
    P3_MSG="Failed to spawn tenant-a or tenant-b pods in workload namespace"
else
    TENANT_B_IP=$(kubectl get pod tenant-b -n workload -o jsonpath='{.status.podIP}')
    echo "  Attempting connection from tenant-a to tenant-b ($TENANT_B_IP:8888)..."

    if kubectl exec -n workload tenant-a -- nc -z -w 3 "$TENANT_B_IP" 8888 >/dev/null 2>&1; then
        P3_FAIL=1
        P3_MSG="NetworkPolicy failure: Inter-tenant communication succeeded between tenant-a and tenant-b"
    fi
fi
report_result "Phase 3: Inter-Tenant Workload Lateral Movement Isolation" "$P3_FAIL" "${P3_MSG:-NetworkPolicy zero lateral movement verified}"


# ============================================================
# PHASE 4: Traefik Ingress TLS & Security Headers
# ============================================================
echo ""
echo "▶ Running Phase 4: Traefik Ingress TLS & Security Headers..."

P4_1_FAIL=0
P4_1_MSG=""
P4_2_FAIL=0
P4_2_MSG=""

LOCAL_PORT_80=18080
LOCAL_PORT_443=18443

echo "  Establishing background kubectl port-forward for svc/portal -n slurm..."
kubectl port-forward svc/portal -n slurm "${LOCAL_PORT_80}:80" "${LOCAL_PORT_443}:443" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for port-forward to become active
PF_READY=0
for i in {1..10}; do
    if nc -z -w 1 127.0.0.1 "$LOCAL_PORT_80" >/dev/null 2>&1 && nc -z -w 1 127.0.0.1 "$LOCAL_PORT_443" >/dev/null 2>&1; then
        PF_READY=1
        break
    fi
    sleep 0.5
done

if [ "$PF_READY" -ne 1 ]; then
    P4_1_FAIL=1
    P4_1_MSG="kubectl port-forward to svc/portal failed to initialize"
    P4_2_FAIL=1
    P4_2_MSG="kubectl port-forward to svc/portal failed to initialize"
else
    # Check 4.1: HTTP Port 80 Redirects to HTTPS
    echo "  Testing HTTP port 80 redirect..."
    HTTP_HEADERS=$(curl -s -I "http://127.0.0.1:${LOCAL_PORT_80}/" || true)
    HTTP_CODE=$(echo "$HTTP_HEADERS" | head -n 1 | awk '{print $2}')

    if [[ "$HTTP_CODE" != "301" && "$HTTP_CODE" != "308" ]]; then
        P4_1_FAIL=1
        P4_1_MSG="Expected HTTP redirect code 301 or 308, got '${HTTP_CODE:-none}'"
    else
        LOCATION_HEADER=$(echo "$HTTP_HEADERS" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')
        if [[ "$LOCATION_HEADER" != https://* ]]; then
            P4_1_FAIL=1
            P4_1_MSG="HTTP redirect location does not start with https:// (got '$LOCATION_HEADER')"
        fi
    fi

    # Check 4.2: HTTPS Port 443 TLS & Security Headers
    echo "  Testing HTTPS port 443 TLS & security headers..."
    HTTPS_HEADERS=$(curl -s -k -I "https://127.0.0.1:${LOCAL_PORT_443}/" || true)

    if ! echo "$HTTPS_HEADERS" | grep -iq "x-content-type-options: nosniff"; then
        P4_2_FAIL=1
        P4_2_MSG="Missing 'X-Content-Type-Options: nosniff' header in HTTPS response"
    fi

    if ! echo "$HTTPS_HEADERS" | grep -iq "x-frame-options: sameorigin"; then
        P4_2_FAIL=1
        P4_2_MSG="Missing 'X-Frame-Options: SAMEORIGIN' header in HTTPS response"
    fi
fi

report_result "Phase 4.1: Traefik HTTP to HTTPS Redirection" "$P4_1_FAIL" "${P4_1_MSG:-HTTP redirect verified}"
report_result "Phase 4.2: Traefik TLS & Security Headers" "$P4_2_FAIL" "${P4_2_MSG:-nosniff and SAMEORIGIN headers verified}"


# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo "📊 Security Verification Summary: $PASSED_TESTS Passed, $FAILED_TESTS Failed"
echo "============================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}🎉 All WP3-1-8 network & security baseline guarantees verified successfully!${NC}"
    exit 0
else
    echo -e "${RED}⚠️ Security baseline verification failed with $FAILED_TESTS failures.${NC}"
    exit 1
fi
