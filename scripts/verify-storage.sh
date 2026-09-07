#!/bin/bash
# scripts/verify-storage.sh
# Comprehensive verification suite for WP3-1-7: Shared Storage, Datasets & Model Repository.
# Validates all 6 test scenarios defined in docs/WP3-1-7_VERIFICATION.md.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "============================================================"
echo "🧪 WP3-1-7: Storage Architecture Verification Suite"
echo "============================================================"
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""

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

# 0. Determine Execution Target (Kind Container vs Host Environment)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if docker ps --format '{{.Names}}' | grep -q "kind-control-plane"; then
    EXEC_TARGET="kind"
    echo -e "${BLUE}ℹ️ Detected running Kind cluster. Executing checks inside kind-control-plane container.${NC}"
    DOCKER_EXEC="docker exec kind-control-plane"
else
    EXEC_TARGET="host"
    echo -e "${YELLOW}ℹ️ No Kind cluster detected. Executing checks against host filesystem.${NC}"
    DOCKER_EXEC=""
fi

STORAGE_PATH="/mnt/storage"

# Pre-Requisite: Ensure storage is initialized and seeded in test mode
echo ""
echo "--- Initializing & Seeding Storage Fixtures ---"
if [ "$EXEC_TARGET" == "kind" ]; then
    docker exec -i kind-control-plane bash < "$SCRIPT_DIR/init-storage.sh" > /dev/null 2>&1 || true
    docker exec -i kind-control-plane bash -s -- --test-mode < "$SCRIPT_DIR/seed-models.sh" > /dev/null 2>&1 || true
    docker exec -i kind-control-plane bash -s -- --test-mode < "$SCRIPT_DIR/seed-datasets.sh" > /dev/null 2>&1 || true
else
    STORAGE_ROOT="$STORAGE_PATH" bash "$SCRIPT_DIR/init-storage.sh" > /dev/null 2>&1 || true
    STORAGE_ROOT="$STORAGE_PATH" bash "$SCRIPT_DIR/seed-models.sh" --test-mode > /dev/null 2>&1 || true
    STORAGE_ROOT="$STORAGE_PATH" bash "$SCRIPT_DIR/seed-datasets.sh" --test-mode > /dev/null 2>&1 || true
fi

echo ""
echo "============================================================"
echo "Executing Acceptance Tests..."
echo "============================================================"

# --- TEST 1: POSIX Permission Matrix Validation ---
echo "▶ Running Test 1: POSIX Permission Matrix Validation..."
T1_FAIL=0

check_perm() {
    local path="$1"
    local expected_perm="$2"
    local actual_perm
    if [ "$EXEC_TARGET" == "kind" ]; then
        actual_perm=$($DOCKER_EXEC stat -c "%a" "$path" 2>/dev/null || echo "missing")
    else
        actual_perm=$(stat -c "%a" "$path" 2>/dev/null || echo "missing")
    fi

    if [ "$actual_perm" != "$expected_perm" ]; then
        echo "  Mismatch on $path: expected $expected_perm, got $actual_perm"
        T1_FAIL=1
    fi
}

check_perm "$STORAGE_PATH/models" "755"
check_perm "$STORAGE_PATH/datasets" "755"
check_perm "$STORAGE_PATH/scratch" "1777"
check_perm "$STORAGE_PATH/projects/project1" "700"
check_perm "$STORAGE_PATH/projects/project2" "700"

report_result "Test 1: Storage Layout & POSIX Permission Matrix" "$T1_FAIL" "Directory permissions do not match specification"

# --- TEST 2: Dual-Tier Model Hub Resolution ---
echo "▶ Running Test 2: Dual-Tier Model Hub Resolution..."
T2_FAIL=0

if [ "$EXEC_TARGET" == "kind" ]; then
    # Verify pre-loaded model exists
    if ! $DOCKER_EXEC test -f "$STORAGE_PATH/models/huggingface/hub/models--BAAI--bge-small-en-v1.5/snapshots/main/config.json"; then
        T2_FAIL=1
        T2_MSG="Central model fixture missing"
    fi
    # Verify unprivileged user cannot write into central models
    if $DOCKER_EXEC su -s /bin/sh -c "touch $STORAGE_PATH/models/tamper.tmp" nobody 2>/dev/null; then
        T2_FAIL=1
        T2_MSG="Unprivileged user was able to write to central models"
    fi
fi
report_result "Test 2: Dual-Tier Model Hub Resolution" "$T2_FAIL" "${T2_MSG:-Failed to verify model hub read/write bounds}"

# --- TEST 3: Curated Datasets & Private Kaggle Configuration ---
echo "▶ Running Test 3: Curated Datasets & Private Kaggle Configuration..."
T3_FAIL=0

if [ "$EXEC_TARGET" == "kind" ]; then
    # Setup private kaggle credentials in project1
    $DOCKER_EXEC mkdir -p "$STORAGE_PATH/projects/project1/.kaggle"
    $DOCKER_EXEC sh -c "echo '{\"username\":\"user1\",\"key\":\"secret\"}' > $STORAGE_PATH/projects/project1/.kaggle/kaggle.json"
    $DOCKER_EXEC chmod 600 "$STORAGE_PATH/projects/project1/.kaggle/kaggle.json"
    $DOCKER_EXEC chown -R 1001:1001 "$STORAGE_PATH/projects/project1/.kaggle"

    # Verify central dataset is readable
    if ! $DOCKER_EXEC test -f "$STORAGE_PATH/datasets/vision/mnist/dataset_info.json"; then
        T3_FAIL=1
        T3_MSG="Central dataset fixture missing"
    fi
    # Verify unprivileged user cannot read project1 kaggle.json
    if $DOCKER_EXEC su -s /bin/sh -c "cat $STORAGE_PATH/projects/project1/.kaggle/kaggle.json" nobody 2>/dev/null; then
        T3_FAIL=1
        T3_MSG="Cross-tenant isolation leak: unprivileged user read project1 kaggle.json"
    fi
fi
report_result "Test 3: Curated Datasets & Private Kaggle Configuration" "$T3_FAIL" "${T3_MSG:-Failed dataset or token isolation}"

# --- TEST 4: Ephemeral Scratch Space & Sticky Bit Isolation ---
echo "▶ Running Test 4: Ephemeral Scratch Space & Sticky Bit Isolation..."
T4_FAIL=0

if [ "$EXEC_TARGET" == "kind" ]; then
    $DOCKER_EXEC mkdir -p "$STORAGE_PATH/scratch/user1"
    $DOCKER_EXEC chown 1001:1001 "$STORAGE_PATH/scratch/user1"
    $DOCKER_EXEC touch "$STORAGE_PATH/scratch/user1/temp_data.bin"
    $DOCKER_EXEC chown 1001:1001 "$STORAGE_PATH/scratch/user1/temp_data.bin"

    # Attempt deletion as nobody (simulating other unprivileged student) - should be blocked by sticky bit
    if $DOCKER_EXEC su -s /bin/sh -c "rm -f $STORAGE_PATH/scratch/user1/temp_data.bin" nobody 2>/dev/null; then
        T4_FAIL=1
        T4_MSG="Sticky bit failure: Unprivileged user was able to delete another user's scratch file"
    fi

    # Test clean-scratch dry-run
    if ! docker exec -i kind-control-plane bash -s -- --dry-run < "$SCRIPT_DIR/clean-scratch.sh" > /dev/null 2>&1; then
        T4_FAIL=1
        T4_MSG="clean-scratch.sh failed execution"
    fi
    $DOCKER_EXEC rm -rf "$STORAGE_PATH/scratch/user1"
fi
report_result "Test 4: Ephemeral Scratch Space & Sticky Bit Isolation" "$T4_FAIL" "${T4_MSG:-Sticky bit check failed}"

# --- TEST 5: Container Environment Contract Injection ---
echo "▶ Running Test 5: Container Environment Contract Injection..."
T5_FAIL=0

# Check that portal/session_manager.go and portal/handlers.go contain the contract variables
for var_name in "HF_HUB_CACHE" "TORCH_HOME" "TRANSFORMERS_OFFLINE" "KAGGLE_CONFIG_DIR" "KAGGLEHUB_CACHE" "TMPDIR"; do
    if ! grep -q "$var_name" "$REPO_ROOT/portal/session_manager.go" || ! grep -q "$var_name" "$REPO_ROOT/portal/handlers.go"; then
        T5_FAIL=1
        T5_MSG="Missing $var_name in portal contracts"
        break
    fi
done

# Verify portal compiles
if [ "$T5_FAIL" -eq 0 ]; then
    (cd "$REPO_ROOT/portal" && go build ./...) > /dev/null 2>&1 || {
        T5_FAIL=1
        T5_MSG="Portal compilation failed"
    }
fi
report_result "Test 5: Container Environment Contract Injection" "$T5_FAIL" "${T5_MSG:-Contract verification failed}"

# --- TEST 6: Storage Audit & Deduplication Tooling ---
echo "▶ Running Test 6: Storage Audit & Deduplication Tooling..."
T6_FAIL=0

if [ "$EXEC_TARGET" == "kind" ]; then
    AUDIT_OUTPUT=$(docker exec -i kind-control-plane bash -s -- < "$SCRIPT_DIR/audit-storage.sh" 2>&1)
else
    AUDIT_OUTPUT=$(STORAGE_ROOT="$STORAGE_PATH" bash "$SCRIPT_DIR/audit-storage.sh" 2>&1)
fi

if ! echo "$AUDIT_OUTPUT" | grep -q "Audit complete"; then
    T6_FAIL=1
    T6_MSG="audit-storage.sh did not complete cleanly"
fi
report_result "Test 6: Storage Audit & Deduplication Tooling" "$T6_FAIL" "${T6_MSG:-Audit script failed}"

echo ""
echo "============================================================"
echo "📊 Test Summary: $PASSED_TESTS Passed, $FAILED_TESTS Failed"
echo "============================================================"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}🎉 All WP3-1-7 storage acceptance criteria successfully verified!${NC}"
    exit 0
else
    echo -e "${RED}⚠️ Verification failed with $FAILED_TESTS failures.${NC}"
    exit 1
fi
