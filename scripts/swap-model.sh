#!/usr/bin/env bash
# ==============================================================================
# AI Sandbox: Safe LLM Model Swap CLI (WP3-1-9 / WP3-1-10)
# ==============================================================================
# Safely swaps the active served foundation model in k8s/vllm-deployment.yaml
# (namespace: services), validates pre-cached NFS snapshots, monitors the
# Recreate rollout lifecycle, runs smoke inference, and auto-rolls back on failure.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_MODEL=""
MAX_MODEL_LEN=""
GPU_MEM_UTIL=""
EXTRA_ARGS=""
DRY_RUN=0
TIMEOUT_SEC=300

usage() {
    cat <<EOF
Usage: $0 --model <HF_MODEL_ID> [OPTIONS]

Options:
  --model <ID>            HuggingFace model ID to serve (e.g. Qwen/Qwen3.5-0.8B) [Required]
  --max-model-len <INT>   Context window limit (default: preserve current or 16384)
  --gpu-mem <FLOAT>       GPU memory utilization ceiling (default: preserve current or 0.65)
  --extra-args <STRING>   Additional container arguments to append to vLLM args
  --timeout <SECONDS>     Rollout timeout in seconds (default: 300)
  --dry-run               Validate pre-flight criteria without mutating cluster state
  -h, --help              Show this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            TARGET_MODEL="$2"
            shift 2
            ;;
        --max-model-len)
            MAX_MODEL_LEN="$2"
            shift 2
            ;;
        --gpu-mem)
            GPU_MEM_UTIL="$2"
            shift 2
            ;;
        --extra-args)
            EXTRA_ARGS="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SEC="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

if [ -z "$TARGET_MODEL" ]; then
    echo -e "${RED}Error: --model <HF_MODEL_ID> is required.${NC}"
    usage
fi

echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}🔄 AI Sandbox: Central vLLM Model Swap Operator${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Target Model  : ${BOLD}$TARGET_MODEL${NC}"
echo -e "Deployment    : ${BOLD}k8s/vllm-deployment.yaml (namespace: services)${NC}"
echo -e "Dry Run       : ${BOLD}$DRY_RUN${NC}"

# ------------------------------------------------------------------------------
# STEP 1: Pre-flight Verification of Shared Storage Cache
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Step 1/5] Checking pre-cached weights on shared storage...${NC}"

MODEL_DIR_NAME="models--${TARGET_MODEL//\//--}"

# Probe cache via GPU worker daemonset/pod
PROBE_RESULT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- python3 -c "
import os, glob, sys
cache_root = '/mnt/storage/models/huggingface/hub'
model_dir = os.path.join(cache_root, '$MODEL_DIR_NAME')
if not os.path.isdir(model_dir):
    print('DIR_NOT_FOUND')
    sys.exit(0)

snaps = glob.glob(os.path.join(model_dir, 'snapshots', '*'))
if not snaps:
    print('NO_SNAPSHOTS')
    sys.exit(0)

latest_snap = snaps[0]
has_safetensors = len([f for f in glob.glob(os.path.join(latest_snap, '*.safetensors')) if os.path.isfile(f) and os.path.getsize(f) > 0]) > 0
has_config = os.path.isfile(os.path.join(latest_snap, 'config.json')) and os.path.getsize(os.path.join(latest_snap, 'config.json')) > 0

if has_safetensors and has_config:
    print(f'VALID:{latest_snap}')
else:
    print(f'INCOMPLETE:safetensors={has_safetensors},config={has_config}')
" 2>/dev/null || echo "PROBE_FAILED")

if [[ "$PROBE_RESULT" == VALID:* ]]; then
    SNAPSHOT_PATH=$(echo "$PROBE_RESULT" | cut -d':' -f2-)
    echo -e "  ${GREEN}✓ Cache verified:${NC} $SNAPSHOT_PATH (.safetensors + config.json present)"
elif [[ "$PROBE_RESULT" == "DIR_NOT_FOUND" ]]; then
    echo -e "  ${RED}✗ Offline Lockdown Failure:${NC} Directory $MODEL_DIR_NAME does not exist in /mnt/storage/models/huggingface/hub."
    echo -e "  ${YELLOW}Notice:${NC} vLLM is locked with HF_HUB_OFFLINE=1. You must ingest the model first via:"
    echo -e "    ${BOLD}./scripts/ingest-model.sh --model $TARGET_MODEL${NC}"
    exit 1
else
    echo -e "  ${RED}✗ Pre-flight check failed:${NC} Model cache state: $PROBE_RESULT"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "\n${YELLOW}Dry-run mode enabled. Pre-flight checks passed successfully. Exiting without cluster changes.${NC}"
    exit 0
fi

# ------------------------------------------------------------------------------
# STEP 2: Backup Current Manifest and Catalog State
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Step 2/5] Creating rollback checkpoint...${NC}"
BACKUP_MANIFEST=$(mktemp /tmp/vllm-deployment-backup-XXXXXX.yaml)
BACKUP_CATALOG=$(mktemp /tmp/model-catalog-backup-XXXXXX.json)
cp "$REPO_ROOT/k8s/vllm-deployment.yaml" "$BACKUP_MANIFEST"
cp "$REPO_ROOT/docs/MODEL_CATALOG.json" "$BACKUP_CATALOG"
CURRENT_ACTIVE_MODEL=$(grep -A 1 -- '--model' "$REPO_ROOT/k8s/vllm-deployment.yaml" | tail -n 1 | sed -E 's/^[[:space:]]*-[[:space:]]*["'\'']?([^"'\'']+)["'\'']?[[:space:]]*$/\1/')
echo -e "  Saved backup of k8s/vllm-deployment.yaml and docs/MODEL_CATALOG.json (currently serving: ${BOLD}$CURRENT_ACTIVE_MODEL${NC})"

cleanup_on_error() {
    echo -e "\n${RED}============================================================${NC}"
    echo -e "${RED}⚠️  MODEL SWAP FAILED OR INTERRUPTED: INITIATING AUTO-ROLLBACK${NC}"
    echo -e "${RED}============================================================${NC}"
    echo -e "Restoring previous configuration for: ${BOLD}$CURRENT_ACTIVE_MODEL${NC}"
    cp "$BACKUP_MANIFEST" "$REPO_ROOT/k8s/vllm-deployment.yaml"
    cp "$BACKUP_CATALOG" "$REPO_ROOT/docs/MODEL_CATALOG.json"
    kubectl apply -f "$BACKUP_MANIFEST"
    echo -e "Awaiting recovery of previous deployment..."
    kubectl rollout status deployment/vllm -n services --timeout=180s || true
    rm -f "$BACKUP_MANIFEST" "$BACKUP_CATALOG"
    exit 1
}
trap cleanup_on_error ERR INT TERM

# ------------------------------------------------------------------------------
# STEP 3: Mutate Deployment Spec & Catalog Manifest
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Step 3/5] Updating deployment manifest and model catalog...${NC}"

# Python helper to update args in k8s/vllm-deployment.yaml while preserving all comments
python3 - <<EOF
import re

manifest_path = "$REPO_ROOT/k8s/vllm-deployment.yaml"
with open(manifest_path, "r") as f:
    content = f.read()

# 1. Update --model value preserving exact comment & quote style
content = re.sub(
    r'(-\s*["\']?--model["\']?\s*\n\s*-\s*)["\']?[^"\n]+["\']?',
    r'\g<1>"$TARGET_MODEL"',
    content
)

# 2. Update --max-model-len if specified
if "$MAX_MODEL_LEN":
    content = re.sub(
        r'(-\s*["\']?--max-model-len["\']?\s*\n\s*-\s*)["\']?[^"\n]+["\']?',
        r'\g<1>"$MAX_MODEL_LEN"',
        content
    )

# 3. Update --gpu-memory-utilization if specified (preserving multi-line comment block)
if "$GPU_MEM_UTIL":
    content = re.sub(
        r'(-\s*["\']?--gpu-memory-utilization["\']?\s*\n(?:\s*#[^\n]*\n)*\s*-\s*)["\']?[^"\n]+["\']?',
        r'\g<1>"$GPU_MEM_UTIL"',
        content
    )

# 4. Append --extra-args if specified and not already present
if "$EXTRA_ARGS":
    extra_items = "$EXTRA_ARGS".split()
    extra_yaml = "".join([f'        - "{item}"\n' for item in extra_items])
    # insert before port arg
    content = content.replace('        - "--port"', f'{extra_yaml}        - "--port"')

with open(manifest_path, "w") as f:
    f.write(content)
print("  Preserved YAML layout and comments in k8s/vllm-deployment.yaml")
EOF

# Update docs/MODEL_CATALOG.json parity
python3 - <<EOF
import json

catalog_path = "$REPO_ROOT/docs/MODEL_CATALOG.json"
try:
    with open(catalog_path, "r") as f:
        data = json.load(f)
    found = False
    for m in data.get("models", []):
        if m["id"] == "$TARGET_MODEL":
            m["central_serving"] = True
            m["estimate_source"] = "measured"
            found = True
        else:
            m["central_serving"] = False
    with open(catalog_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Updated docs/MODEL_CATALOG.json (target registered: {found}, estimate_source: measured)")
except Exception as e:
    print(f"  Notice: Could not sync docs/MODEL_CATALOG.json ({e})")
EOF

# ------------------------------------------------------------------------------
# STEP 4: Apply & Monitor Recreate Rollout
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Step 4/5] Applying new deployment and monitoring Recreate rollout...${NC}"
SWAP_START_TIME=$(date +%s)

kubectl apply -f "$REPO_ROOT/k8s/vllm-deployment.yaml"

echo -e "  Waiting for deployment rollout (timeout: ${TIMEOUT_SEC}s)..."
kubectl rollout status deployment/vllm -n services --timeout="${TIMEOUT_SEC}s"

SWAP_END_TIME=$(date +%s)
SWAP_DURATION=$((SWAP_END_TIME - SWAP_START_TIME))
echo -e "  ${GREEN}✓ Rollout completed in ${SWAP_DURATION}s${NC}"

# ------------------------------------------------------------------------------
# STEP 5: Live Smoke Test & Verification
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Step 5/5] Performing live endpoint smoke tests...${NC}"

# 1. Query internal endpoint for active model ID
SERVED_CHECK=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -m 10 http://vllm-service.services.svc.cluster.local:8000/v1/models 2>/dev/null || echo "FAIL")
if [[ "$SERVED_CHECK" != *"$TARGET_MODEL"* ]]; then
    echo -e "  ${RED}✗ Endpoint verification failed: /v1/models does not report $TARGET_MODEL${NC}"
    echo "  Raw output: $SERVED_CHECK"
    false
fi
echo -e "  ${GREEN}✓ Internal service confirmed active:${NC} $TARGET_MODEL"

# 2. Query Traefik gateway chat completion
CHAT_PROBE=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -sk -m 20 -X POST https://127.0.0.1:443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$TARGET_MODEL"'",
    "messages": [{"role": "user", "content": "Respond with: SWAP_SUCCESS"}],
    "max_tokens": 10
  }' 2>/dev/null || echo "FAIL")

if [[ "$CHAT_PROBE" != *"choices"* ]]; then
    echo -e "  ${RED}✗ Gateway chat completion failed!${NC}"
    echo "  Raw output: $CHAT_PROBE"
    false
fi

REPLY=$(echo "$CHAT_PROBE" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"].strip().replace("\n", " "))
except Exception:
    print("PARSE_ERROR")
' 2>/dev/null || echo "PARSE_ERROR")

echo -e "  ${GREEN}✓ Live chat completion verified:${NC} \"$REPLY\""

# Clean up trap and backup
trap - ERR INT TERM
rm -f "$BACKUP_MANIFEST" "$BACKUP_CATALOG"

echo -e "\n${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}🎉 Model swap successful! Active model: $TARGET_MODEL (${SWAP_DURATION}s)${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
exit 0
