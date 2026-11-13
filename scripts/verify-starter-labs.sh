#!/bin/bash
# scripts/verify-starter-labs.sh
# ==============================================================================
# AI Sandbox: Dedicated Starter Labs & Client SDK Verification Suite (Unit WP14-B)
# Validates:
#   1. Portal unit test asserting QDRANT_URL and MLFLOW_TRACKING_URI injection
#   2. Canonical starter notebooks existence under templates/ & /mnt/storage/projects/project1/starter_labs/
#   3. POSIX collaborative ownership (1001:2001, mode 2770) on starter_labs directory
#   4. Pre-baked SDK availability in interactive-jupyter:latest (polars, dask, qdrant, llama_index, torch, etc.)
#   5. Negative proof: EROFS on read-only /mnt/storage/datasets & /mnt/storage/models + dropped Postgres port 5432
#   6. Headless execution of 01_hello_sandbox.ipynb
#   7. Headless execution of 02_data_processing_polars.ipynb
#   8. Headless execution of 03_experiment_tracking_mlflow.ipynb against live MLflow
#   9. Headless execution of 04_llm_inference_and_rag.ipynb against live Qdrant
#  10. Headless execution of 05_gpu_lora_finetuning.ipynb against PyTorch PEFT & live MLflow
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
echo -e "${CYAN}${BOLD}🧪 AI Sandbox: WP14-B Starter Labs & SDK Verification${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "Timestamp : $(LC_ALL=C date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Target    : workload namespace (student session) & central services"
echo ""

# ------------------------------------------------------------------------------
# 1. Stage 1: Portal Unit Tests (QDRANT_URL & MLFLOW_TRACKING_URI)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [1/10] Checking Portal Session Manager Unit Tests...${NC}"
if (cd portal && go test -v -run TestCreateSession_ScopedSubPathsAndSecurityContext >/dev/null 2>&1); then
    report_pass "Portal Session Environment Injection" "Injected QDRANT_URL and MLFLOW_TRACKING_URI"
else
    report_fail "Portal Session Environment Injection" "go test -run TestCreateSession_ScopedSubPathsAndSecurityContext failed"
fi

# ------------------------------------------------------------------------------
# 2. Canonical Starter Notebooks in Git Templates
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [2/10] Checking Canonical Starter Notebooks in templates/...${NC}"
REQUIRED_NOTEBOOKS=(
    "01_hello_sandbox.ipynb"
    "02_data_processing_polars.ipynb"
    "03_experiment_tracking_mlflow.ipynb"
    "04_llm_inference_and_rag.ipynb"
    "05_gpu_lora_finetuning.ipynb"
)

MISSING_TEMPLATES=0
for nb in "${REQUIRED_NOTEBOOKS[@]}"; do
    if [ ! -f "templates/projects/project1/starter_labs/$nb" ]; then
        MISSING_TEMPLATES=$((MISSING_TEMPLATES + 1))
    fi
done

if [ "$MISSING_TEMPLATES" -eq 0 ]; then
    report_pass "Canonical Starter Notebooks Present" "All 5 notebooks exist in templates/projects/project1/starter_labs/"
else
    report_fail "Canonical Starter Notebooks Present" "Missing $MISSING_TEMPLATES notebook(s) in templates/"
fi

# ------------------------------------------------------------------------------
# 3. Seeded Notebooks & POSIX Permissions on Storage
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [3/10] Checking Seeded Notebooks in /mnt/storage/projects/project1/starter_labs/...${NC}"
STORAGE_CHECK=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- stat -c "%u:%g:%a" /mnt/storage/projects/project1/starter_labs 2>/dev/null || echo "")
SEEDED_COUNT=$(kubectl -n slurm exec deploy/hpc-portal -c portal -- find /mnt/storage/projects/project1/starter_labs -name "*.ipynb" 2>/dev/null | wc -l || echo "0")

if [ "$STORAGE_CHECK" == "1001:2001:2770" ] && [ "$SEEDED_COUNT" -ge 5 ]; then
    report_pass "Seeded Storage Layout & Permissions" "ownership=1001:2001, mode=2770, notebooks=$SEEDED_COUNT"
else
    report_fail "Seeded Storage Layout & Permissions" "stat=${STORAGE_CHECK:-none}, notebooks=${SEEDED_COUNT:-0} (expected 1001:2001:2770 and >= 5 notebooks)"
fi

# ------------------------------------------------------------------------------
# Launch Student Verification Pod in 'workload' Namespace
# ------------------------------------------------------------------------------
VERIFY_POD="verify-labs-$$"
CLEANUP_PODS+=("$VERIFY_POD")

echo -e "${BLUE}▶ Spawning Student Verification Pod in 'workload' (${VERIFY_POD})...${NC}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${VERIFY_POD}
  namespace: workload
  labels:
    app.kubernetes.io/name: starter-labs-probe
    app.kubernetes.io/component: interactive-session
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 1001
    runAsGroup: 2001
    supplementalGroups:
    - 1001
    fsGroup: 2001
  tolerations:
  - key: "slinky.slurm.net/managed-node"
    operator: "Exists"
    effect: "NoExecute"
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: slinky-storage-pvc
  containers:
  - name: probe
    image: interactive-jupyter:latest
    imagePullPolicy: IfNotPresent
    volumeMounts:
    - name: storage-volume
      mountPath: /mnt/storage/projects/project1
      subPath: projects/project1
      readOnly: false
    - name: storage-volume
      mountPath: /mnt/storage/scratch
      subPath: scratch
      readOnly: false
    - name: storage-volume
      mountPath: /mnt/storage/datasets
      subPath: datasets
      readOnly: true
    - name: storage-volume
      mountPath: /mnt/storage/models
      subPath: models
      readOnly: true
    - name: storage-volume
      mountPath: /var/lib/extrausers
      subPath: common/etc
      readOnly: true
    env:
    - name: HOME
      value: "/mnt/storage/projects/project1"
    - name: WORKSPACE
      value: "/mnt/storage/projects/project1"
    - name: TMPDIR
      value: "/mnt/storage/scratch"
    - name: MLFLOW_TRACKING_URI
      value: "http://mlflow.services.svc.cluster.local:5000"
    - name: QDRANT_URL
      value: "http://qdrant.services.svc.cluster.local:6333"
    command: ["sleep", "3600"]
EOF

# Wait for probe pod to be Running
for i in $(seq 1 45); do
    PHASE=$(kubectl -n workload get pod "$VERIFY_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$PHASE" == "Running" ]; then
        break
    fi
    sleep 1
done

if [ "$PHASE" != "Running" ]; then
    report_fail "Student Verification Pod" "Pod failed to reach Running state (status: $PHASE)"
    echo -e "${RED}Aborting remaining tests due to container startup failure.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Pre-Baked SDK Imports Check
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [4/10] Verifying Pre-Baked SDK Imports in interactive-jupyter:latest...${NC}"
SDK_OUTPUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- python3 -c "
import sys
packages = ['polars', 'dask', 'pyarrow', 'qdrant_client', 'llama_index', 'mlflow', 'torch', 'transformers', 'peft']
failed = []
for p in packages:
    try:
        __import__(p)
    except Exception as e:
        failed.append(f'{p}: {e}')
if failed:
    print('FAILED: ' + '; '.join(failed))
    sys.exit(1)
print('ALL_PACKAGES_OK')
" 2>&1 || true)

if echo "$SDK_OUTPUT" | grep -q "ALL_PACKAGES_OK"; then
    report_pass "Pre-Baked SDK Availability" "polars, dask, pyarrow, qdrant_client, llama_index, mlflow, torch, transformers, peft"
else
    report_fail "Pre-Baked SDK Availability" "Output: $SDK_OUTPUT"
fi

# ------------------------------------------------------------------------------
# 5. Negative Proof: Storage EROFS & Postgres Network Isolation
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [5/10] Checking Storage Read-Only Boundary & Network Isolation (Negative Proof)...${NC}"
BOUNDARY_OUTPUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- python3 -c "
import sys, socket

# 1. EROFS on /mnt/storage/datasets
try:
    with open('/mnt/storage/datasets/leak.txt', 'w') as f:
        f.write('fail')
    sys.exit('LEAK: /mnt/storage/datasets was writable!')
except OSError as e:
    if e.errno != 30:
        sys.exit(f'Unexpected error on datasets write: {e}')

# 2. EROFS on /mnt/storage/models
try:
    with open('/mnt/storage/models/leak.txt', 'w') as f:
        f.write('fail')
    sys.exit('LEAK: /mnt/storage/models was writable!')
except OSError as e:
    if e.errno != 30:
        sys.exit(f'Unexpected error on models write: {e}')

# 3. NetworkPolicy block on PostgreSQL port 5432
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2.0)
try:
    s.connect(('mlflow-postgres.services.svc.cluster.local', 5432))
    s.close()
    sys.exit('LEAK: Connected to PostgreSQL port 5432!')
except (socket.timeout, OSError):
    pass # Expected dropped connection

print('BOUNDARIES_HARDENED')
" 2>&1 || true)

if echo "$BOUNDARY_OUTPUT" | grep -q "BOUNDARIES_HARDENED"; then
    report_pass "Storage & Network Boundary Rejection" "EROFS enforced on datasets/models; TCP 5432 dropped"
else
    report_fail "Storage & Network Boundary Rejection" "Output: $BOUNDARY_OUTPUT"
fi

# ------------------------------------------------------------------------------
# 6. Headless Execution: Lab 01 (Hello Sandbox)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [6/10] Executing Lab 01 (01_hello_sandbox.ipynb)...${NC}"
LAB1_OUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- jupyter nbconvert \
    --to notebook --execute \
    --output-dir=/mnt/storage/scratch \
    --output=exec_01.ipynb \
    /mnt/storage/projects/project1/starter_labs/01_hello_sandbox.ipynb 2>&1 || true)

if echo "$LAB1_OUT" | grep -qi "Writing.*exec_01.ipynb"; then
    report_pass "Lab 01 Execution" "Sandbox orientation & Slurm job generation passed"
else
    report_fail "Lab 01 Execution" "Output: $LAB1_OUT"
fi

# ------------------------------------------------------------------------------
# 7. Headless Execution: Lab 02 (Polars & Dask ETL)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [7/10] Executing Lab 02 (02_data_processing_polars.ipynb)...${NC}"
LAB2_OUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- jupyter nbconvert \
    --to notebook --execute \
    --output-dir=/mnt/storage/scratch \
    --output=exec_02.ipynb \
    /mnt/storage/projects/project1/starter_labs/02_data_processing_polars.ipynb 2>&1 || true)

if echo "$LAB2_OUT" | grep -qi "Writing.*exec_02.ipynb"; then
    report_pass "Lab 02 Execution" "Polars & Dask ETL streamed from datasets and wrote Parquet to scratch"
else
    report_fail "Lab 02 Execution" "Output: $LAB2_OUT"
fi

# ------------------------------------------------------------------------------
# 8. Headless Execution: Lab 03 (MLflow Experiment Tracking)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [8/10] Executing Lab 03 (03_experiment_tracking_mlflow.ipynb)...${NC}"
LAB3_OUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- jupyter nbconvert \
    --to notebook --execute \
    --output-dir=/mnt/storage/scratch \
    --output=exec_03.ipynb \
    /mnt/storage/projects/project1/starter_labs/03_experiment_tracking_mlflow.ipynb 2>&1 || true)

if echo "$LAB3_OUT" | grep -qi "Writing.*exec_03.ipynb"; then
    report_pass "Lab 03 Execution" "Logged run, metrics, and model artifact to live MLflow"
else
    report_fail "Lab 03 Execution" "Output: $LAB3_OUT"
fi

# ------------------------------------------------------------------------------
# 9. Headless Execution: Lab 04 (LlamaIndex + Qdrant RAG)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [9/10] Executing Lab 04 (04_llm_inference_and_rag.ipynb)...${NC}"
LAB4_OUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- jupyter nbconvert \
    --to notebook --execute \
    --output-dir=/mnt/storage/scratch \
    --output=exec_04.ipynb \
    /mnt/storage/projects/project1/starter_labs/04_llm_inference_and_rag.ipynb 2>&1 || true)

if echo "$LAB4_OUT" | grep -qi "Writing.*exec_04.ipynb"; then
    report_pass "Lab 04 Execution" "Indexed and queried vectors in live central Qdrant"
else
    report_fail "Lab 04 Execution" "Output: $LAB4_OUT"
fi

# ------------------------------------------------------------------------------
# 10. Headless Execution: Lab 05 (PyTorch PEFT LoRA Fine-Tuning)
# ------------------------------------------------------------------------------
echo -e "${BLUE}▶ [10/10] Executing Lab 05 (05_gpu_lora_finetuning.ipynb)...${NC}"
LAB5_OUT=$(kubectl -n workload exec "$VERIFY_POD" -c probe -- jupyter nbconvert \
    --to notebook --execute \
    --output-dir=/mnt/storage/scratch \
    --output=exec_05.ipynb \
    /mnt/storage/projects/project1/starter_labs/05_gpu_lora_finetuning.ipynb 2>&1 || true)

if echo "$LAB5_OUT" | grep -qi "Writing.*exec_05.ipynb"; then
    report_pass "Lab 05 Execution" "LoRA adapter injected, trained, and logged to live MLflow"
else
    report_fail "Lab 05 Execution" "Output: $LAB5_OUT"
fi

# Clean up scratch temporary output notebooks
kubectl -n workload exec "$VERIFY_POD" -c probe -- rm -f /mnt/storage/scratch/exec_*.ipynb >/dev/null 2>&1 || true

echo ""
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}Verification Summary: ${GREEN}${PASSED_TESTS}/${TOTAL_TESTS} PASSED${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failures: $FAILED_TESTS${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 1
else
    echo -e "${GREEN}All Starter Labs & Client SDK checks PASSED!${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    exit 0
fi
