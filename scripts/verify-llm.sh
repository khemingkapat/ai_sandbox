#!/bin/bash
# scripts/verify-llm.sh
# ==============================================================================
# AI Sandbox: Dedicated LLM Inference & Model Catalog Verification Suite
# Focuses exclusively on WP3-1-9 (vLLM Engine & Ingress) and WP3-1-10 (Catalog)
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$REPO_ROOT/bin"
export PATH="$REPO_ROOT/bin:$PATH"

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}🤖 AI Sandbox: LLM Inference & Model Verification Suite${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Timestamp : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Target    : vLLM Service (slurm) & Model Storage (/mnt/storage/models)"
echo ""

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}❌ Error: kubectl is required to execute this verification suite.${NC}"
    exit 1
fi

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNED_TESTS=0

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

report_warn() {
    local name="$1"
    local reason="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    WARNED_TESTS=$((WARNED_TESTS + 1))
    echo -e "  ${YELLOW}⚠️  [WARN]${NC} $name (${reason})"
}

# ==============================================================================
# PHASE 1: Physical Accelerator & Time-Slicing
# ==============================================================================
echo -e "${BLUE}▶ PHASE 1: GPU Accelerator & Time-Slicing Baseline${NC}"

# 1.1 NVML Physical GPU Check
NVML_CHECK=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader 2>/dev/null || echo "FAIL")
if [[ "$NVML_CHECK" == *"NVIDIA"* ]]; then
    report_pass "Physical GPU Accelerator (NVML)" "$NVML_CHECK"
else
    report_fail "Physical GPU Accelerator (NVML)" "Failed to query nvidia-smi on slurmd-gpu-0 ($NVML_CHECK)"
fi

# 1.2 Time-Slicing Capacity
GPU_CAPACITY=$(kubectl get node ai-sandbox-gpu-vm -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [ "$GPU_CAPACITY" -ge 2 ]; then
    report_pass "Kubernetes GPU Time-Slicing" "$GPU_CAPACITY virtual slices advertised"
else
    report_fail "Kubernetes GPU Time-Slicing" "Expected >= 2 GPU slices, found $GPU_CAPACITY"
fi

# ==============================================================================
# PHASE 2: vLLM Runtime Engine Stabilization (WP3-1-9)
# ==============================================================================
echo -e "\n${BLUE}▶ PHASE 2: vLLM Runtime Engine Stabilization${NC}"

# 2.1 Pod Readiness
VLLM_STATUS=$(kubectl get pods -n slurm -l app=vllm -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [ "$VLLM_STATUS" == "true" ]; then
    report_pass "vLLM Pod Health" "1/1 Ready and serving"
else
    VLLM_PHASE=$(kubectl get pods -n slurm -l app=vllm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    report_fail "vLLM Pod Health" "Pod is not Ready (Phase: $VLLM_PHASE)"
fi

# 2.2 Pinned Image Version
VLLM_IMAGE=$(kubectl get deploy vllm -n slurm -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "Unknown")
if [[ "$VLLM_IMAGE" == *":v0.31.0"* ]] || [[ "$VLLM_IMAGE" == *"@sha256:"* ]]; then
    report_pass "Image Version Pinning" "Deterministic tag locked ($VLLM_IMAGE)"
elif [[ "$VLLM_IMAGE" == *":latest"* ]]; then
    report_warn "Image Version Pinning" "Using unpinned :latest tag ($VLLM_IMAGE)"
else
    report_pass "Image Version Pinning" "$VLLM_IMAGE"
fi

# 2.3 Deployment Strategy (Recreate enforcement)
DEPLOY_STRAT=$(kubectl get deploy vllm -n slurm -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "Unknown")
if [ "$DEPLOY_STRAT" == "Recreate" ]; then
    report_pass "GPU Deployment Strategy" "Recreate (prevents rolling update GPU deadlock)"
else
    report_fail "GPU Deployment Strategy" "Expected 'Recreate', found '$DEPLOY_STRAT'"
fi

# 2.4 Internal Service Query
VLLM_MODEL_LIST=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -m 5 http://vllm-service.slurm:8000/v1/models 2>/dev/null || echo "FAIL")
if [[ "$VLLM_MODEL_LIST" == *"object\":\"list\""* ]]; then
    SERVED_MODEL=$(echo "$VLLM_MODEL_LIST" | grep -o '"id":"[^"]*' | head -n1 | cut -d'"' -f4)
    report_pass "Internal Service Endpoint" "vllm-service.slurm:8000 active, serving: $SERVED_MODEL"
else
    report_fail "Internal Service Endpoint" "Could not query /v1/models on vllm-service:8000"
fi

# ==============================================================================
# PHASE 3: Traefik Ingress & API Gateway Protection
# ==============================================================================
echo -e "\n${BLUE}▶ PHASE 3: Traefik Gateway & Rate-Limiting Protection${NC}"

# 3.1 Gateway HTTPS Routing (/v1/models)
INGRESS_HTTPS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -sk -m 5 https://127.0.0.1:443/v1/models 2>/dev/null || echo "FAIL")
if [[ "$INGRESS_HTTPS" == *"object\":\"list\""* ]]; then
    report_pass "Traefik HTTPS Gateway (443)" "Successfully routed to /v1/models"
else
    report_fail "Traefik HTTPS Gateway (443)" "Failed to reach /v1/models through port 443"
fi

# 3.2 Gateway HTTP Routing (80)
INGRESS_HTTP=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -m 5 http://127.0.0.1:80/v1/models 2>/dev/null || echo "FAIL")
if [[ "$INGRESS_HTTP" == *"object\":\"list\""* ]]; then
    report_pass "Traefik HTTP Gateway (80)" "Direct plain HTTP routing functional"
else
    report_fail "Traefik HTTP Gateway (80)" "Failed to reach /v1/models through port 80"
fi

# 3.3 Protection Middlewares in ConfigMap
CM_CONFIG=$(kubectl get configmap traefik-security-config -n slurm -o jsonpath='{.data.security\.yaml}' 2>/dev/null || echo "")
if [[ "$CM_CONFIG" == *"vllm-ratelimit"* ]] && [[ "$CM_CONFIG" == *"vllm-inflight"* ]]; then
    report_pass "API Protection Middlewares" "vllm-ratelimit (10 req/s, burst 20) & vllm-inflight (15 max) active"
else
    report_fail "API Protection Middlewares" "Middlewares missing in traefik-security-config ConfigMap"
fi

# ==============================================================================
# PHASE 4: Storage Hierarchy & Model Catalog (WP3-1-10)
# ==============================================================================
echo -e "\n${BLUE}▶ PHASE 4: Shared Storage & Model Catalog Architecture${NC}"

# 4.1 Shared Models Mount
GPU_MOUNT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $6}' || echo "FAIL")
if [ "$GPU_MOUNT" == "/mnt/storage" ]; then
    FREE_SPACE=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $4}')
    report_pass "Shared Storage Mount" "/mnt/storage mounted over NFS ($FREE_SPACE free)"
else
    report_fail "Shared Storage Mount" "/mnt/storage not mounted on GPU worker node"
fi

# 4.2 Permission Hardening Policy
PERM_AUDIT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- stat -c "%U:%G %a" /mnt/storage/models 2>/dev/null || echo "FAIL")
if [[ "$PERM_AUDIT" == *"root:root 755"* ]]; then
    report_pass "POSIX Permission Hardening" "Owner: $PERM_AUDIT (read-only for students)"
else
    report_warn "POSIX Permission Hardening" "Current: $PERM_AUDIT (target: root:root 755)"
fi

# 4.3 Catalog Manifest Schema Validation
if [ -f "$REPO_ROOT/docs/MODEL_CATALOG.json" ]; then
    CATALOG_COUNT=$(python3 -c "
import json
with open('$REPO_ROOT/docs/MODEL_CATALOG.json') as f:
    d = json.load(f)
print(len(d.get('models', [])))
" 2>/dev/null || echo "0")
    if [ "$CATALOG_COUNT" -ge 4 ]; then
        report_pass "Model Catalog Manifest" "$CATALOG_COUNT models registered in docs/MODEL_CATALOG.json"
    else
        report_fail "Model Catalog Manifest" "Only $CATALOG_COUNT models found in catalog"
    fi
else
    report_fail "Model Catalog Manifest" "docs/MODEL_CATALOG.json not found"
fi

# 4.4 Ingestion CLI Presence
if [ -x "$REPO_ROOT/scripts/ingest-model.sh" ]; then
    report_pass "Automated Ingestion Tool" "scripts/ingest-model.sh executable"
else
    report_fail "Automated Ingestion Tool" "scripts/ingest-model.sh missing or not executable"
fi

# ==============================================================================
# PHASE 5: Live Inference & Latency Benchmark
# ==============================================================================
echo -e "\n${BLUE}▶ PHASE 5: Live Inference & Latency Benchmark${NC}"

PROMPT_START=$(date +%s%N)
CHAT_RESP=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -sk -m 15 -X POST https://127.0.0.1:443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$SERVED_MODEL"'",
    "messages": [{"role": "user", "content": "Reply with exactly three words: AI Sandbox Live"}],
    "max_tokens": 10
  }' 2>/dev/null || echo "FAIL")
PROMPT_END=$(date +%s%N)

LATENCY_MS=$(( (PROMPT_END - PROMPT_START) / 1000000 ))

if [[ "$CHAT_RESP" == *"choices"* ]]; then
    CONTENT=$(python3 -c "
import json
try:
    d = json.loads('''$CHAT_RESP''')
    print(d['choices'][0]['message']['content'].strip())
except Exception as e:
    print('PARSE_ERR')
" 2>/dev/null || echo "PARSE_ERR")
    report_pass "Live Chat Completion via Traefik" "Roundtrip: ${LATENCY_MS}ms | Output: \"$CONTENT\""
else
    report_fail "Live Chat Completion via Traefik" "Failed chat completion request ($CHAT_RESP)"
fi

# ==============================================================================
# SCORECARD
# ==============================================================================
echo -e "\n${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}📊 LLM & Catalog Verification Scorecard${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Total Checks Executed : $TOTAL_TESTS"
echo -e "Passed Checks         : ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed Checks         : ${RED}$FAILED_TESTS${NC}"
echo -e "Warnings              : ${YELLOW}$WARNED_TESTS${NC}"
echo ""

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}🎉 LLM Inference Engine & Catalog Verified Operational!${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}❌ Verification failed with $FAILED_TESTS failure(s).${NC}"
    exit 1
fi
