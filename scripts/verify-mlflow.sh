#!/bin/bash
# scripts/verify-mlflow.sh
# ==============================================================================
# AI Sandbox: Dedicated MLflow Central Service & Experiment Tracking Test Suite
# Validates complete MLflow stack against docs/WP3-1-11_EXPERIMENT_TRACKING_GUIDE.md
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
        kubectl delete pod "$p" -n workload --force --grace-period=0 2>/dev/null || true
    done
}
trap cleanup EXIT

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}🧪 AI Sandbox: WP3-1-11 MLflow Experiment Tracking Verification${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Timestamp : $(LC_ALL=C date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Target    : services namespace (ai-worker1) & Traefik gateway"
echo ""

# 1. PostgreSQL StatefulSet Ready on ai-worker1
echo -e "${BLUE}▶ Checking PostgreSQL Database Backend...${NC}"
PG_NODE=$(kubectl -n services get pod mlflow-postgres-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
PG_READY=$(kubectl -n services get pod mlflow-postgres-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")

if [ "$PG_NODE" == "ai-worker1" ] && [ "$PG_READY" == "true" ]; then
    report_pass "PostgreSQL 16 StatefulSet Ready" "node=ai-worker1"
else
    report_fail "PostgreSQL 16 StatefulSet Ready" "node=$PG_NODE, ready=$PG_READY"
fi

# 2. Database Isolation: workload namespace CANNOT reach port 5432
echo -e "${BLUE}▶ Checking Network Security & Failure Domain Isolation...${NC}"
DB_PROBE_FAIL=0
if kubectl run test-db-iso-$$ -n workload --rm -i --restart=Never --image=busybox:1.36 -- nc -z -w 3 mlflow-postgres.services.svc.cluster.local 5432 >/dev/null 2>&1; then
    DB_PROBE_FAIL=1
fi

if [ "$DB_PROBE_FAIL" -eq 0 ]; then
    report_pass "PostgreSQL Database Isolated" "TCP 5432 from workload dropped by NetworkPolicy"
else
    report_fail "PostgreSQL Database Isolated" "Workload unexpectedly connected to PostgreSQL port 5432"
fi

# 3. MLflow Tracking Server Ready on ai-worker1
echo -e "${BLUE}▶ Checking MLflow Tracking Server Deployment...${NC}"
ML_NODE=$(kubectl -n services get pods -l app.kubernetes.io/name=mlflow -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
ML_READY=$(kubectl -n services get pods -l app.kubernetes.io/name=mlflow -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "")

if [ "$ML_NODE" == "ai-worker1" ] && [ "$ML_READY" == "true" ]; then
    report_pass "MLflow Server Deployment Ready" "node=ai-worker1, gunicorn active"
else
    report_fail "MLflow Server Deployment Ready" "node=$ML_NODE, ready=$ML_READY"
fi

# 4. MLflow Health Endpoint (Internal DNS)
echo -e "${BLUE}▶ Checking Internal Cluster Health Endpoint...${NC}"
HEALTH_OUT=$(kubectl run test-hlth-$$ -n workload --rm -i --restart=Never --image=curlimages/curl -- curl -sS -m 5 http://mlflow.services.svc.cluster.local:5000/health 2>&1 || true)
if echo "$HEALTH_OUT" | grep -q "OK"; then
    report_pass "MLflow Internal REST /health" "http://mlflow.services:5000 -> OK"
else
    report_fail "MLflow Internal REST /health" "Output: $HEALTH_OUT"
fi

# 5. Traefik External Web UI
echo -e "${BLUE}▶ Checking Traefik Ingress Gateway Routing...${NC}"
UI_OUT=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- curl -sk https://127.0.0.1:443/mlflow/ 2>/dev/null || true)
if echo "$UI_OUT" | grep -q "<title>MLflow</title>"; then
    report_pass "Traefik Gateway /mlflow UI" "HTTP 200 with <title>MLflow</title>"
else
    report_fail "Traefik Gateway /mlflow UI" "Failed to retrieve MLflow HTML title"
fi

# 6. Traefik Static Assets
JS_STATUS=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- curl -s -k -o /dev/null -w "%{http_code}" https://127.0.0.1:443/mlflow/static-files/static/js/main.4dd28f2b.js 2>/dev/null || true)
if [ "$JS_STATUS" == "200" ]; then
    report_pass "Traefik Static Bundle Routing" "main.js HTTP 200"
else
    report_fail "Traefik Static Bundle Routing" "HTTP code: $JS_STATUS"
fi

# 7. Traefik REST API Routing
API_EXP=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- curl -s -k "https://127.0.0.1:443/api/2.0/mlflow/experiments/search?max_results=5" 2>/dev/null | jq -r '.experiments[0].name' 2>/dev/null || echo "")
if [ -n "$API_EXP" ] && [ "$API_EXP" != "null" ]; then
    report_pass "Traefik REST API /api/2.0" "Active experiment found: $API_EXP"
else
    report_fail "Traefik REST API /api/2.0" "Failed to query experiments search via Traefik"
fi

# 8. End-to-End Experiment & Proxied Artifact Logging from Workload (Interactive Jupyter Image)
echo -e "${BLUE}▶ Executing End-to-End Student Logging Probe from Workload...${NC}"
TEST_RUN_ID=$(LC_ALL=C date +%s)
E2E_OUT=$(kubectl run test-e2e-$$ -n workload --rm -i --restart=Never --image=interactive-jupyter:latest --image-pull-policy=IfNotPresent --overrides='{"spec":{"tolerations":[{"key":"slinky.slurm.net/managed-node","operator":"Exists","effect":"NoExecute"}]}}' --command -- python -c "
import os
import mlflow
# Verify MLFLOW_TRACKING_URI is pre-populated in the container environment or use fallback
if not os.environ.get('MLFLOW_TRACKING_URI'):
    mlflow.set_tracking_uri('http://mlflow.services.svc.cluster.local:5000')
mlflow.set_experiment('automated-test-suite')
with mlflow.start_run(run_name='verify-$TEST_RUN_ID') as run:
    mlflow.log_param('batch_size', 32)
    mlflow.log_metric('loss', 0.042, step=1)
    with open('output_metric.json', 'w') as f:
        f.write('{\"status\": \"verified\"}')
    mlflow.log_artifact('output_metric.json')
print('VERIFY_SUCCESS_RUN:' + run.info.run_id)
" 2>&1 || true)

if echo "$E2E_OUT" | grep -q "VERIFY_SUCCESS_RUN:"; then
    CAPTURED_RUN_ID=$(echo "$E2E_OUT" | grep "VERIFY_SUCCESS_RUN:" | cut -d':' -f2 | tr -d '[:space:]')
    report_pass "Python SDK Autologging & Artifact Upload" "run_id=$CAPTURED_RUN_ID"
else
    report_fail "Python SDK Autologging & Artifact Upload" "Output: $E2E_OUT"
    CAPTURED_RUN_ID=""
fi

# 9. Verify Artifact Storage on Persistent Volume
if [ -n "$CAPTURED_RUN_ID" ]; then
    ARTIFACT_FOUND=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- find /mnt/storage/mlflow/artifacts -name "output_metric.json" | grep "$CAPTURED_RUN_ID" || true)
    if [ -n "$ARTIFACT_FOUND" ]; then
        report_pass "Proxied Artifact Storage Verification" "File located on PVC at $ARTIFACT_FOUND"
    else
        report_fail "Proxied Artifact Storage Verification" "Artifact output_metric.json not found on PVC for run $CAPTURED_RUN_ID"
    fi
fi

echo ""
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}Verification Summary: ${GREEN}${PASSED_TESTS}/${TOTAL_TESTS} PASSED${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failures: $FAILED_TESTS${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 1
else
    echo -e "${GREEN}All MLflow Central Service and Experiment Tracking checks PASSED!${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 0
fi
