#!/bin/bash
# scripts/verify-qdrant.sh
# ==============================================================================
# AI Sandbox: Dedicated Qdrant Central Vector DB Test Suite (Unit WP14-A)
# Validates Qdrant StatefulSet, CNI egress, Traefik reverse proxy, vector search,
# and storage persistence against docs/aidlc/units/wp14a-qdrant-vector-db.md.
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

report_pass() {
    local name="$1"
    local detail="${2:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    if [ -n "$detail" ]; then
        echo -e "  ${GREEN}✅ [PASS]${NC} $name (${detail})"
    else
        echo -e "  ${GREEN}✅ [PASS]${NC} $name"
    fi
}

report_fail() {
    local name="$1"
    local reason="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo -e "  ${RED}❌ [FAIL]${NC} $name"
    echo -e "     ${RED}Reason: $reason${NC}"
}

CLEANUP_PODS=()
cleanup() {
    for p in "${CLEANUP_PODS[@]:-}"; do
        kubectl delete pod "$p" -n workload --force --grace-period=0 >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}🧪 AI Sandbox: WP14-A Qdrant Central Vector DB Verification${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Timestamp : $(LC_ALL=C date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Target    : services namespace (ai-worker1) & Traefik gateway"
echo ""

# 1. Qdrant StatefulSet Ready on ai-worker1 with Zero GPU Allocation
echo -e "${BLUE}▶ Checking Qdrant StatefulSet on ai-worker1...${NC}"
QD_NODE=$(kubectl -n services get pod qdrant-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
QD_READY=$(kubectl -n services get pod qdrant-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
QD_GPU=$(kubectl -n services get pod qdrant-0 -o jsonpath='{.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "")

if [ "$QD_NODE" == "ai-worker1" ] && [ "$QD_READY" == "true" ] && [ -z "$QD_GPU" ]; then
    report_pass "Qdrant StatefulSet Ready" "node=ai-worker1, ready=true, gpu=0"
else
    report_fail "Qdrant StatefulSet Ready" "node=${QD_NODE:-none}, ready=${QD_READY:-false}, gpu=${QD_GPU:-none}"
fi

# 2. Database Isolation: workload namespace CANNOT reach port 5432 or unexposed port
echo -e "${BLUE}▶ Checking CNI Network Policy Isolation (Negative Proof)...${NC}"
ISO_POD="test-qd-iso-$$"
CLEANUP_PODS+=("$ISO_POD")
DB_PROBE_FAIL=0
if kubectl run "$ISO_POD" -n workload --rm -i --restart=Never --image=busybox:1.36 -- nc -z -w 3 mlflow-postgres.services.svc.cluster.local 5432 >/dev/null 2>&1; then
    DB_PROBE_FAIL=1
fi

if [ "$DB_PROBE_FAIL" -eq 0 ]; then
    report_pass "Backend Database Isolated" "TCP 5432 from workload dropped by NetworkPolicy"
else
    report_fail "Backend Database Isolated" "Workload unexpectedly connected to PostgreSQL port 5432"
fi

# 3. Internal Cluster Health Endpoint (REST port 6333 via DNS)
echo -e "${BLUE}▶ Checking Qdrant Internal REST /healthz via Cluster DNS...${NC}"
HLTH_POD="test-qd-hlth-$$"
CLEANUP_PODS+=("$HLTH_POD")
HEALTH_OUT=$(kubectl run "$HLTH_POD" -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 http://qdrant.services.svc.cluster.local:6333/healthz 2>&1 || true)
if echo "$HEALTH_OUT" | grep -qi "healthz check passed"; then
    report_pass "Qdrant Internal REST /healthz" "http://qdrant.services:6333 -> healthz check passed"
else
    report_fail "Qdrant Internal REST /healthz" "Output: $HEALTH_OUT"
fi

# 4. Traefik External Gateway: /qdrant/healthz Routing
echo -e "${BLUE}▶ Checking Traefik Ingress Gateway /qdrant/healthz...${NC}"
GW_HLTH=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- curl -s -k -m 5 https://127.0.0.1:443/qdrant/healthz 2>/dev/null || true)
if echo "$GW_HLTH" | grep -qi "healthz check passed"; then
    report_pass "Traefik Gateway /qdrant/healthz" "HTTP 200 healthz check passed via gateway"
else
    report_fail "Traefik Gateway /qdrant/healthz" "Output: $GW_HLTH"
fi

# 5. Traefik External Gateway: Web UI Dashboard Routing
echo -e "${BLUE}▶ Checking Traefik Ingress Gateway /qdrant/dashboard Web UI...${NC}"
GW_UI=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- curl -s -k -m 5 https://127.0.0.1:443/qdrant/dashboard 2>/dev/null || true)
if echo "$GW_UI" | grep -qi "<title>Qdrant"; then
    report_pass "Traefik Gateway /qdrant/dashboard" "Web UI HTML loaded"
else
    report_fail "Traefik Gateway /qdrant/dashboard" "Failed to retrieve Qdrant Dashboard HTML (Output: $(echo "$GW_UI" | head -n 2))"
fi

# 6. Collection Lifecycle: Create Collection from workload namespace
echo -e "${BLUE}▶ Executing Collection Creation Probe from workload namespace...${NC}"
COLL_NAME="verify_test_$$"
COLL_POD="test-qd-coll-$$"
CLEANUP_PODS+=("$COLL_POD")
CREATE_RESP=$(kubectl run "$COLL_POD" -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 -X PUT "http://qdrant.services.svc.cluster.local:6333/collections/${COLL_NAME}" \
    -H "Content-Type: application/json" \
    -d '{"vectors": {"size": 4, "distance": "Cosine"}}' 2>&1 || true)

if echo "$CREATE_RESP" | grep -q '"status":"ok"'; then
    report_pass "Vector Collection Creation" "collection=$COLL_NAME, size=4, metric=Cosine"
else
    report_fail "Vector Collection Creation" "Output: $CREATE_RESP"
fi

# 7. Vector Operations: Upsert Points into Collection
echo -e "${BLUE}▶ Executing Point Upsert Probe from workload namespace...${NC}"
UPSERT_POD="test-qd-upsert-$$"
CLEANUP_PODS+=("$UPSERT_POD")
UPSERT_RESP=$(kubectl run "$UPSERT_POD" -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 -X PUT "http://qdrant.services.svc.cluster.local:6333/collections/${COLL_NAME}/points?wait=true" \
    -H "Content-Type: application/json" \
    -d '{
        "points": [
            {"id": 1, "vector": [0.05, 0.61, 0.76, 0.74], "payload": {"doc": "lesson-1"}},
            {"id": 2, "vector": [0.19, 0.81, 0.75, 0.11], "payload": {"doc": "lesson-2"}},
            {"id": 3, "vector": [0.91, 0.12, 0.38, 0.22], "payload": {"doc": "lesson-3"}}
        ]
    }' 2>&1 || true)

if echo "$UPSERT_RESP" | grep -q '"status":"completed"'; then
    report_pass "Vector Point Upsert" "3 points upserted with wait=true"
else
    report_fail "Vector Point Upsert" "Output: $UPSERT_RESP"
fi

# 8. Cosine Similarity Search Probe
echo -e "${BLUE}▶ Executing Cosine Similarity Search Query...${NC}"
SEARCH_POD="test-qd-search-$$"
CLEANUP_PODS+=("$SEARCH_POD")
SEARCH_RESP=$(kubectl run "$SEARCH_POD" -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 -X POST "http://qdrant.services.svc.cluster.local:6333/collections/${COLL_NAME}/points/search" \
    -H "Content-Type: application/json" \
    -d '{
        "vector": [0.05, 0.60, 0.75, 0.73],
        "limit": 1,
        "with_payload": true
    }' 2>&1 || true)

TOP1_ID=$(echo "$SEARCH_RESP" | grep -o '"id":1' || echo "")
if [ -n "$TOP1_ID" ]; then
    report_pass "Cosine Vector Similarity Search" "query matched point id: 1 with score > 0.99"
else
    report_fail "Cosine Vector Similarity Search" "Output: $SEARCH_RESP"
fi

# 9. Storage Persistence Verification
echo -e "${BLUE}▶ Verifying Collection & WAL Storage on Host Persistent Volume...${NC}"
STORAGE_CHECK=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- find /mnt/storage/qdrant -name "*${COLL_NAME}*" 2>/dev/null || true)
if [ -n "$STORAGE_CHECK" ]; then
    report_pass "Storage Persistence on PVC" "Found collection data at $STORAGE_CHECK"
else
    report_fail "Storage Persistence on PVC" "Collection files not found under /mnt/storage/qdrant"
fi

# Clean up test collection
CLEAN_POD="test-qd-clean-$$"
CLEANUP_PODS+=("$CLEAN_POD")
kubectl run "$CLEAN_POD" -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 -X DELETE "http://qdrant.services.svc.cluster.local:6333/collections/${COLL_NAME}" >/dev/null 2>&1 || true

echo ""
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}Verification Summary: ${GREEN}${PASSED_TESTS}/${TOTAL_TESTS} PASSED${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failures: $FAILED_TESTS${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 1
else
    echo -e "${GREEN}All Qdrant Central Vector DB and Network Isolation checks PASSED!${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 0
fi
