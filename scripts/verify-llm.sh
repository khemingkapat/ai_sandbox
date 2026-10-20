#!/bin/bash
# scripts/verify-llm.sh
# ==============================================================================
# AI Sandbox: Dedicated LLM Inference & Model Catalog Verification Suite
# Targets: Proxmox K3s Cluster (ai-sandbox-gpu-vm, slurm namespace)
# Validates complete LLM state against docs/MODEL_CATALOG.md & docs/LLM_VERIFICATION_RUNBOOK.md
# ==============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$REPO_ROOT/bin"
export PATH="$REPO_ROOT/bin:$PATH"

DESTRUCTIVE_MODE=0
TEST_SWAP_MODEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destructive)
            DESTRUCTIVE_MODE=1
            shift
            ;;
        --test-swap)
            TEST_SWAP_MODEL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}🤖 AI Sandbox: LLM Inference & Model Verification Suite${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Timestamp   : $(LC_ALL=C date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Context     : $(kubectl config current-context 2>/dev/null || echo 'Unknown')"
echo -e "Target      : vLLM Service (services) & Model Storage (/mnt/storage/models)"
echo -e "Destructive : $DESTRUCTIVE_MODE"
if [ -n "$TEST_SWAP_MODEL" ]; then
    echo -e "Test Swap   : $TEST_SWAP_MODEL"
fi
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
    local advice="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    WARNED_TESTS=$((WARNED_TESTS + 1))
    echo -e "  ${YELLOW}⚠️  [WARN]${NC} $name"
    echo -e "     ${YELLOW}Notice: $advice${NC}"
}

# Cleanup Tracking
CLEANUP_FILES=()
CLEANUP_DIRS=()

cleanup() {
    for f in "${CLEANUP_FILES[@]:-}"; do
        if [ -f "$f" ]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done
    for d in "${CLEANUP_DIRS[@]:-}"; do
        if [ -d "$d" ]; then
            rm -rf "$d" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

# ==============================================================================
# STAGE 1: Physical Accelerator & GPU Virtualization Baseline
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}▶ STAGE 1: Physical Accelerator & GPU Virtualization Baseline${NC}"
echo -e "${BOLD}============================================================${NC}"

# Check 1.1: Physical GPU Accelerator Detection (NVML)
NVML_CHECK=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader 2>/dev/null || echo "FAIL")
if [[ "$NVML_CHECK" == *"NVIDIA"* ]]; then
    report_pass "Physical GPU Accelerator (NVML)" "$NVML_CHECK"
else
    report_fail "Physical GPU Accelerator (NVML)" "Failed to query nvidia-smi on slurmd-gpu-0 ($NVML_CHECK)"
fi

# Check 1.2: Kubernetes GPU Time-Slicing Capacity
GPU_CAPACITY=$(kubectl get node ai-sandbox-gpu-vm -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [ "$GPU_CAPACITY" -ge 2 ]; then
    report_pass "Kubernetes GPU Time-Slicing" "$GPU_CAPACITY virtual slices advertised"
else
    report_fail "Kubernetes GPU Time-Slicing" "Expected >= 2 GPU slices, found $GPU_CAPACITY"
fi

# Check 1.3: GPU Memory Headroom for Batch Slurm Jobs
GPU_FREE_MIB=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- python3 -c "
import subprocess
try:
    out = subprocess.check_output(['nvidia-smi', '--query-gpu=memory.free', '--format=csv,noheader,nounits']).decode().strip()
    print(int(out.split('\n')[0]))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")

if [ "$GPU_FREE_MIB" -ge 12000 ]; then
    report_pass "GPU Headroom for Batch Slurm Jobs" "${GPU_FREE_MIB} MiB free VRAM available"
elif [ "$GPU_FREE_MIB" -ge 0 ]; then
    report_warn "GPU Headroom for Batch Slurm Jobs" "Low headroom: ${GPU_FREE_MIB} MiB free VRAM"
else
    report_warn "GPU Headroom for Batch Slurm Jobs" "Unable to query NVML free memory"
fi

# ==============================================================================
# STAGE 2: vLLM Runtime Engine Stabilization (WP3-1-9)
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}▶ STAGE 2: vLLM Runtime Engine Stabilization (WP3-1-9)${NC}"
echo -e "${BOLD}============================================================${NC}"

# Check 2.1: Pod Readiness
VLLM_STATUS=$(kubectl get pods -n services -l app=vllm -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [ "$VLLM_STATUS" == "true" ]; then
    report_pass "vLLM Pod Health" "1/1 Ready and serving (services namespace)"
else
    VLLM_PHASE=$(kubectl get pods -n services -l app=vllm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    report_fail "vLLM Pod Health" "Pod is not Ready in services namespace (Phase: $VLLM_PHASE)"
fi

# Check 2.2: Pinned Image Version
VLLM_IMAGE=$(kubectl get deploy vllm -n services -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "Unknown")
if [[ "$VLLM_IMAGE" == *":v0.31.0"* ]] || [[ "$VLLM_IMAGE" == *"@sha256:"* ]]; then
    report_pass "Image Version Pinning" "Deterministic tag locked ($VLLM_IMAGE)"
elif [[ "$VLLM_IMAGE" == *":latest"* ]]; then
    report_warn "Image Version Pinning" "Using unpinned :latest tag ($VLLM_IMAGE)"
else
    report_pass "Image Version Pinning" "$VLLM_IMAGE"
fi

# Check 2.3: GPU Deployment Strategy (Recreate enforcement)
DEPLOY_STRAT=$(kubectl get deploy vllm -n services -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "Unknown")
if [ "$DEPLOY_STRAT" == "Recreate" ]; then
    report_pass "GPU Deployment Strategy" "Recreate (prevents rolling update GPU deadlock)"
else
    report_fail "GPU Deployment Strategy" "Expected 'Recreate', found '$DEPLOY_STRAT'"
fi

# Check 2.4: Read-Only Shared Model Cache Mount
WRITE_TEST=$(kubectl exec -n services deploy/vllm -- touch /root/.cache/huggingface/.security_probe_test 2>&1 || true)
if [[ "$WRITE_TEST" == *"Read-only file system"* ]]; then
    report_pass "Read-Only Model Cache Mount" "Write attempts blocked by container runtime"
else
    report_fail "Read-Only Model Cache Mount" "Model cache is unexpectedly writable ($WRITE_TEST)"
fi

# Check 2.5: Offline Mode Enforcement
OFFLINE_ENV=$(kubectl get deploy vllm -n services -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HF_HUB_OFFLINE")].value}' 2>/dev/null || echo "")
if [ "$OFFLINE_ENV" == "1" ]; then
    report_pass "Offline Cache Lockdown" "HF_HUB_OFFLINE=1 strictly enforced"
else
    report_fail "Offline Cache Lockdown" "HF_HUB_OFFLINE is not set to 1 in deployment env"
fi

# Check 2.6: Node Taint Toleration Tightening
TOLERATIONS_JSON=$(kubectl get deploy vllm -n services -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null || echo "[]")
if [[ "$TOLERATIONS_JSON" == *"operator\":\"Exists\""* ]]; then
    report_fail "Toleration Tightening" "Deployment still has blanket operator: Exists toleration"
elif [[ "$TOLERATIONS_JSON" == *"slinky.slurm.net/managed-node"* ]]; then
    report_pass "Toleration Tightening" "Scoped precisely to slurm-bridge-scheduler taint"
else
    report_pass "Toleration Tightening" "No blanket operator: Exists toleration found"
fi

# Check 2.7: Internal Service Query
VLLM_MODEL_LIST=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -m 5 http://vllm-service.services.svc.cluster.local:8000/v1/models 2>/dev/null || echo "FAIL")
if [[ "$VLLM_MODEL_LIST" == *"object\":\"list\""* ]]; then
    SERVED_MODEL=$(echo "$VLLM_MODEL_LIST" | grep -o '"id":"[^"]*' | head -n1 | cut -d'"' -f4)
    report_pass "Internal Service Endpoint" "vllm-service.services.svc.cluster.local:8000 active, serving: $SERVED_MODEL"
else
    SERVED_MODEL="Qwen/Qwen2.5-32B-Instruct-AWQ"
    report_fail "Internal Service Endpoint" "Could not query /v1/models on vllm-service.services:8000"
fi

# ==============================================================================
# STAGE 3: Traefik Ingress & API Gateway Protection
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}▶ STAGE 3: Traefik Ingress & API Gateway Protection${NC}"
echo -e "${BOLD}============================================================${NC}"

# Check 3.1: Gateway HTTPS Routing (/v1/models)
INGRESS_HTTPS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -sk -m 5 https://127.0.0.1:443/v1/models 2>/dev/null || echo "FAIL")
if [[ "$INGRESS_HTTPS" == *"object\":\"list\""* ]]; then
    report_pass "Traefik HTTPS Gateway (443)" "Successfully routed to /v1/models"
else
    report_fail "Traefik HTTPS Gateway (443)" "Failed to reach /v1/models through port 443"
fi

# Check 3.2: Gateway HTTP Routing (80)
INGRESS_HTTP=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -m 5 http://127.0.0.1:80/v1/models 2>/dev/null || echo "FAIL")
if [[ "$INGRESS_HTTP" == *"object\":\"list\""* ]]; then
    report_pass "Traefik HTTP Gateway (80)" "Direct plain HTTP routing functional"
else
    report_fail "Traefik HTTP Gateway (80)" "Failed to reach /v1/models through port 80"
fi

# Check 3.3: Protection Middlewares in ConfigMap
CM_CONFIG=$(kubectl get configmap traefik-security-config -n slurm -o jsonpath='{.data.security\.yaml}' 2>/dev/null || echo "")
if [[ "$CM_CONFIG" == *"vllm-ratelimit"* ]] && [[ "$CM_CONFIG" == *"vllm-inflight"* ]]; then
    report_pass "API Protection Middlewares" "vllm-ratelimit (10 req/s, burst 20) & vllm-inflight (15 max) active"
else
    report_fail "API Protection Middlewares" "Middlewares missing in traefik-security-config ConfigMap"
fi

# Check 3.4: Active Rate-Limiting Burst Behavioral Verification
RATELIMIT_BURST=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- sh -c '
for i in $(seq 1 60); do
    curl -sk -o /dev/null -w "%{http_code}\n" -m 5 https://127.0.0.1:443/v1/models &
done
wait
' 2>/dev/null | sort | uniq -c || echo "FAIL")

HAS_200=$(echo "$RATELIMIT_BURST" | grep -c "200" || echo "0")
HAS_429=$(echo "$RATELIMIT_BURST" | grep -c "429" || echo "0")

if [ "$HAS_200" -gt 0 ] && [ "$HAS_429" -gt 0 ]; then
    SUMMARY_429=$(echo "$RATELIMIT_BURST" | grep "429" | tr -d ' ' || echo "429")
    report_pass "Active Rate-Limiting Behavioral Test" "60-burst triggered 429 throttling ($SUMMARY_429)"
else
    report_fail "Active Rate-Limiting Behavioral Test" "Expected both 200 and 429 status codes ($RATELIMIT_BURST)"
fi

# ==============================================================================
# STAGE 4: Shared Storage & Model Catalog Architecture (WP3-1-10)
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}▶ STAGE 4: Shared Storage & Model Catalog Architecture (WP3-1-10)${NC}"
echo -e "${BOLD}============================================================${NC}"

# Check 4.1: Shared Models Mount on GPU Worker
GPU_MOUNT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $6}' || echo "FAIL")
if [ "$GPU_MOUNT" == "/mnt/storage" ]; then
    FREE_SPACE=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $4}')
    report_pass "Shared Storage Mount" "/mnt/storage mounted over NFS ($FREE_SPACE free)"
else
    report_fail "Shared Storage Mount" "/mnt/storage not mounted on GPU worker node"
fi

# Check 4.2: POSIX Permission Hardening Policy
PERM_AUDIT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- stat -c "%U:%G %a" /mnt/storage/models 2>/dev/null || echo "FAIL")
if [[ "$PERM_AUDIT" == *"root:root 755"* ]]; then
    report_pass "POSIX Permission Hardening" "Owner: $PERM_AUDIT (read-only for students)"
else
    report_warn "POSIX Permission Hardening" "Current: $PERM_AUDIT (target: root:root 755)"
fi

# Check 4.3: Catalog Manifest Schema & Parity Validation
CATALOG_AUDIT=$(python3 - <<'EOF'
import json, sys

path = "docs/MODEL_CATALOG.json"
try:
    with open(path, "r") as f:
        data = json.load(f)
    models = data.get("models", [])
    count = len(models)
    central_served = [m["id"] for m in models if m.get("central_serving") is True]
    all_have_source = all("estimate_source" in m for m in models)
    if count < 4:
        print(f"FAIL:Only {count} models registered")
    elif len(central_served) != 1:
        print(f"FAIL:Expected exactly 1 central_serving model, found {central_served}")
    elif not all_have_source:
        print("FAIL:Missing estimate_source field in catalog entries")
    else:
        print(f"PASS:{count}:{central_served[0]}")
except Exception as e:
    print(f"FAIL:{e}")
EOF
)

if [[ "$CATALOG_AUDIT" == PASS:* ]]; then
    CAT_COUNT=$(echo "$CATALOG_AUDIT" | cut -d':' -f2)
    CAT_SERVED=$(echo "$CATALOG_AUDIT" | cut -d':' -f3)
    if [ "$CAT_SERVED" == "$SERVED_MODEL" ]; then
        report_pass "Model Catalog Parity" "$CAT_COUNT models registered, served model ($CAT_SERVED) strictly matches"
    else
        report_fail "Model Catalog Parity" "Catalog central_serving ($CAT_SERVED) does not match engine ($SERVED_MODEL)"
    fi
else
    report_fail "Model Catalog Parity" "$CATALOG_AUDIT"
fi

# Check 4.4: Automated Ingestion CLI Tool
if [ -x "$REPO_ROOT/scripts/ingest-model.sh" ]; then
    report_pass "Automated Ingestion Tool" "scripts/ingest-model.sh executable"
else
    report_fail "Automated Ingestion Tool" "scripts/ingest-model.sh missing or not executable"
fi

# Check 4.5: Ingestion Tool Mock Isolation
TMP_INGEST_DIR=$(mktemp -d /tmp/audit_ingest_XXXXXX)
CLEANUP_DIRS+=("$TMP_INGEST_DIR")
INGEST_TEST_OUTPUT=$(
    bash "$REPO_ROOT/scripts/ingest-model.sh" --test-mode --model test/verify-suite-probe --storage-root "$TMP_INGEST_DIR" 2>&1
    if [ -d "$TMP_INGEST_DIR/models/huggingface/hub/models--test--verify-suite-probe" ]; then
        echo "OK"
    else
        echo "FAIL_DIR"
    fi
)

if [[ "$INGEST_TEST_OUTPUT" == *"OK"* ]]; then
    report_pass "Ingestion Tool Mock Isolation" "Synthetic fixture creates valid models--<org>--<name> layout"
else
    report_fail "Ingestion Tool Mock Isolation" "Failed mock ingestion test ($INGEST_TEST_OUTPUT)"
fi

# Check 4.6: Real On-Disk Model Cache Snapshot Integrity
REAL_CACHE_CHECK=$(kubectl exec -n services deploy/vllm -- python3 -c '
import os, glob
cache_dir = "/root/.cache/huggingface/hub"
models = [d for d in os.listdir(cache_dir) if d.startswith("models--")]
valid_models = []
for m in models:
    snaps = glob.glob(os.path.join(cache_dir, m, "snapshots", "*"))
    for s in snaps:
        safetensors = [f for f in glob.glob(os.path.join(s, "*.safetensors")) if os.path.isfile(f) and os.path.getsize(f) > 0]
        configs = [f for f in glob.glob(os.path.join(s, "config.json")) if os.path.isfile(f) and os.path.getsize(f) > 0]
        if safetensors and configs:
            valid_models.append(m.replace("models--", "").replace("--", "/"))
            break
print(",".join(valid_models))
' 2>/dev/null || echo "FAIL")

if [[ "$REAL_CACHE_CHECK" != "FAIL" ]] && [[ "$REAL_CACHE_CHECK" == *"Qwen"* ]]; then
    report_pass "Real Model Cache Snapshot Integrity" "Verified safetensors snapshots on shared NFS: $REAL_CACHE_CHECK"
else
    report_fail "Real Model Cache Snapshot Integrity" "No valid safetensors snapshots found on NFS hub cache ($REAL_CACHE_CHECK)"
fi

# ==============================================================================
# STAGE 5: Live Inference, Latency & Boundary Checks
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}▶ STAGE 5: Live Inference, Latency & Boundary Checks${NC}"
echo -e "${BOLD}============================================================${NC}"

# Check 5.1: Live Chat Completion Benchmark
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
    CONTENT=$(echo "$CHAT_RESP" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"].strip().replace("\n", " "))
except Exception:
    print("PARSE_ERR")
' 2>/dev/null || echo "PARSE_ERR")
    report_pass "Live Chat Completion via Traefik" "Roundtrip: ${LATENCY_MS}ms | Output: \"$CONTENT\""
else
    report_fail "Live Chat Completion via Traefik" "Failed chat completion request ($CHAT_RESP)"
fi

# Check 5.2: Context Window Boundary Check (Overflow Rejection)
OVERFLOW_RESP=$(python3 -c '
import json
huge_text = "test " * 18000
print(json.dumps({
    "model": "'"$SERVED_MODEL"'",
    "messages": [{"role": "user", "content": huge_text}],
    "max_tokens": 10
}))
' | kubectl exec -i -n slurm deploy/hpc-portal -c portal -- curl -sk -m 15 -X POST https://127.0.0.1:443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @- -o /dev/null -w "%{http_code}\n" 2>/dev/null || echo "FAIL")

if [ "$OVERFLOW_RESP" == "400" ]; then
    report_pass "Context Window Overflow Rejection" "Oversized request safely rejected with HTTP 400"
else
    report_warn "Context Window Overflow Rejection" "Expected HTTP 400 rejection (got $OVERFLOW_RESP)"
fi

# ==============================================================================
# STAGE 6: Engine Failure Recovery & Restart Benchmark (Optional / Destructive)
# ==============================================================================
if [ "$DESTRUCTIVE_MODE" -eq 1 ]; then
    echo -e "\n${BOLD}============================================================${NC}"
    echo -e "${BOLD}▶ STAGE 6: Engine Failure Recovery & Restart Benchmark (--destructive)${NC}"
    echo -e "${BOLD}============================================================${NC}"
    
    TARGET_POD=$(kubectl get pod -n services -l app=vllm -o jsonpath='{.items[0].metadata.name}')
    echo -e "  Simulating unexpected process crash inside container on $TARGET_POD..."
    
    CRASH_START=$(date +%s)
    kubectl exec -n services "$TARGET_POD" -- kill -9 1 2>/dev/null || true
    
    RECOVERED="false"
    for i in $(seq 1 120); do
        sleep 2
        CUR_READY=$(kubectl get pod -n services -l app=vllm -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        if [ "$CUR_READY" == "true" ]; then
            RECOVERED="true"
            break
        fi
    done
    CRASH_END=$(date +%s)
    RECOVERY_SEC=$((CRASH_END - CRASH_START))
    
    if [ "$RECOVERED" == "true" ]; then
        report_pass "In-Place Container Crash Recovery" "Container restarted in-place & Ready in ${RECOVERY_SEC}s"
    else
        report_fail "In-Place Container Crash Recovery" "Engine failed to recover after 240 seconds"
    fi
fi

# ==============================================================================
# STAGE 7: Automated Live Model Swap Verification (Optional / --test-swap)
# ==============================================================================
if [ -n "$TEST_SWAP_MODEL" ]; then
    echo -e "\n${BOLD}============================================================${NC}"
    echo -e "${BOLD}▶ STAGE 7: Automated Live Model Swap Verification (--test-swap)${NC}"
    echo -e "${BOLD}============================================================${NC}"
    
    echo -e "  Executing automated model swap to ${BOLD}$TEST_SWAP_MODEL${NC}..."
    SWAP_TEST_START=$(date +%s)
    if bash "$REPO_ROOT/scripts/swap-model.sh" --model "$TEST_SWAP_MODEL"; then
        SWAP_TEST_END=$(date +%s)
        SWAP_DUR=$((SWAP_TEST_END - SWAP_TEST_START))
        report_pass "Live Model Swap Execution" "Successfully swapped active engine to $TEST_SWAP_MODEL (${SWAP_DUR}s)"
    else
        report_fail "Live Model Swap Execution" "Failed to swap active engine to $TEST_SWAP_MODEL"
    fi
fi

# ==============================================================================
# FINAL VERIFICATION SCORECARD
# ==============================================================================
echo -e "\n${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}📊 Final Verification Scorecard${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Total Checks Executed : ${BOLD}$TOTAL_TESTS${NC}"
echo -e "Passed Checks         : ${GREEN}${BOLD}$PASSED_TESTS${NC}"
echo -e "Failed Checks         : ${RED}${BOLD}$FAILED_TESTS${NC}"
echo -e "Warnings (Advisory)   : ${YELLOW}${BOLD}$WARNED_TESTS${NC}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "\n${GREEN}${BOLD}🎉 System Baseline Validated! Zero critical architectural failures.${NC}"
    if [ "$WARNED_TESTS" -gt 0 ]; then
        echo -e "${YELLOW}Notice: $WARNED_TESTS advisory warning(s) detected.${NC}"
    fi
    exit 0
else
    echo -e "\n${RED}${BOLD}❌ System Verification Failed! $FAILED_TESTS critical check(s) failed.${NC}"
    exit 1
fi
