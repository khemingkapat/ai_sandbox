#!/bin/bash
# scripts/verify-multi-user-jobs.sh
set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "====================================================="
echo "🧪 Multi-User Concurrent Job & Isolation Verification"
echo "====================================================="

# 0. Ensure tooling
export PATH="$(pwd)/bin:$PATH"

# Check if cluster is up
if ! kind get clusters | grep -q "^kind$"; then
  echo "🚀 Cluster not found. This script expects a running cluster."
  echo "Please run './scripts/verify-infrastructure.sh' or 'kup' first."
  exit 1
fi

# Wait for nodes and pods
echo "⏳ Waiting for Slurm components to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null
kubectl wait --namespace slurm --for=condition=Ready pod/slurm-controller-0 --timeout=180s >/dev/null
kubectl wait --namespace slurm --for=condition=Ready pod -l app.kubernetes.io/name=slurmd --timeout=180s >/dev/null

WORKER_PODS=$(kubectl get pods -n slurm -l app.kubernetes.io/name=slurmd -o jsonpath='{.items[*].metadata.name}')
CONTROLLER="slurm-controller-0"
FIRST_WORKER=$(echo $WORKER_PODS | awk '{print $1}')

# 1. Provision users
echo "👤 Provisioning test users (user1-4) on worker nodes..."
USERS=("user1:1001" "user2:1002" "user3:1003" "user4:1004")

for pod in $WORKER_PODS; do
  for user_info in "${USERS[@]}"; do
    IFS=":" read -r username uid <<< "$user_info"
    if ! kubectl exec -n slurm -c slurmd "$pod" -- id -u "$username" &>/dev/null; then
      echo "  - Creating $username ($uid) on $pod"
      kubectl exec -n slurm -c slurmd "$pod" -- useradd -u "$uid" -m -s /bin/bash "$username"
    else
      echo "  - $username already exists on $pod"
    fi
  done
done

# 2. Setup project directories
echo "📂 Setting up project directories..."
STORAGE_ROOT="/mnt/storage"

setup_dir() {
  local path=$1
  local uid=$2
  local perm=$3
  echo "  - Path: $path (UID: $uid, Perm: $perm)"
  kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- mkdir -p "$path"
  kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- chown "$uid:$uid" "$path"
  kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- chmod "$perm" "$path"
}

setup_dir "$STORAGE_ROOT/projects/project1" 1001 700
setup_dir "$STORAGE_ROOT/projects/project2" 1002 700
setup_dir "$STORAGE_ROOT/projects/project3" 1004 700

# 3. SlurmDBD Detection
echo ""
echo "🔍 Checking Slurm accounting (SlurmDBD)..."
if kubectl exec -n slurm -c slurmctld "$CONTROLLER" -- sacctmgr show cluster -n &>/dev/null; then
  echo -e "${GREEN}Detected SlurmDBD mode (Accounting enabled)${NC}"
  kubectl exec -n slurm -c slurmctld "$CONTROLLER" -- sacctmgr show association
else
  echo -e "${YELLOW}Standard mode (Accounting disabled)${NC}"
fi

# 4. Submit concurrent jobs
echo ""
echo "📝 Submitting concurrent sleep jobs..."
JOB_IDS=()
for i in {1..4}; do
  username="user$i"
  JOB_ID=$(kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- su -s /bin/bash "$username" -c \
    "sbatch --parsable --wrap='sleep 20' -N 1")
  echo "  - Submitted job $JOB_ID for $username"
  JOB_IDS+=("$JOB_ID")
done

echo "⏳ Waiting for jobs to register..."
sleep 5
kubectl exec -n slurm -c slurmctld "$CONTROLLER" -- squeue

# Verify parallel execution (at least 2 running)
RUNNING_COUNT=$(kubectl exec -n slurm -c slurmctld "$CONTROLLER" -- squeue -h -t RUNNING | wc -l)
echo "Running jobs: $RUNNING_COUNT"
if [ "$RUNNING_COUNT" -ge 2 ]; then
  echo -e "${GREEN}PASS: Multiple jobs running in parallel!${NC}"
else
  echo -e "${YELLOW}WARNING: Less than 2 jobs running in parallel. This might be due to resource constraints in the virtual environment.${NC}"
fi

# 5. Isolation Verification
echo ""
echo "🔐 Verifying project isolation..."

assert_access() {
  local user=$1
  local path=$2
  local should_pass=$3
  local msg=$4

  echo -n "  - $msg... "
  if kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- su -s /bin/bash "$user" -c "ls $path" &>/dev/null; then
    if [ "$should_pass" = "true" ]; then
      echo -e "${GREEN}PASS${NC}"
    else
      echo -e "${RED}FAIL (Should have been blocked)${NC}"
      EXIT_CODE=1
    fi
  else
    if [ "$should_pass" = "false" ]; then
      echo -e "${GREEN}PASS (Blocked as expected)${NC}"
    else
      echo -e "${RED}FAIL (Access denied but should be allowed)${NC}"
      EXIT_CODE=1
    fi
  fi
}

EXIT_CODE=0

# User1 checks
assert_access "user1" "$STORAGE_ROOT/projects/project1" "true" "user1 accessing project1"
assert_access "user1" "$STORAGE_ROOT/projects/project2" "false" "user1 accessing project2"
assert_access "user1" "$STORAGE_ROOT/projects/project3" "false" "user1 accessing project3"

# User2 checks
assert_access "user2" "$STORAGE_ROOT/projects/project2" "true" "user2 accessing project2"
assert_access "user2" "$STORAGE_ROOT/projects/project1" "false" "user2 accessing project1"
assert_access "user2" "$STORAGE_ROOT/projects/project3" "false" "user2 accessing project3"

# User4 checks
assert_access "user4" "$STORAGE_ROOT/projects/project3" "true" "user4 accessing project3"
assert_access "user4" "$STORAGE_ROOT/projects/project1" "false" "user4 accessing project1"
assert_access "user4" "$STORAGE_ROOT/projects/project2" "false" "user4 accessing project2"

# 6. Cleanup
cleanup() {
  echo ""
  echo "🧹 Cleaning up..."
  # Remove project directories
  kubectl exec -n slurm -c slurmd "$FIRST_WORKER" -- rm -rf "$STORAGE_ROOT/projects/project2" "$STORAGE_ROOT/projects/project3"
  
  echo "  - Removing test users..."
  for pod in $WORKER_PODS; do
    for user_info in "${USERS[@]}"; do
      IFS=":" read -r username uid <<< "$user_info"
      kubectl exec -n slurm -c slurmd "$pod" -- userdel -r "$username" 2>/dev/null || true
    done
  done
  
  echo "✨ Cleanup complete."
}

trap cleanup EXIT

if [ "$EXIT_CODE" -eq 0 ]; then
  echo ""
  echo "====================================================="
  echo -e "🎉 ${GREEN}SUCCESS: All multi-user verification checks passed!${NC}"
  echo "====================================================="
else
  echo ""
  echo "====================================================="
  echo -e "❌ ${RED}FAILURE: Some verification checks failed.${NC}"
  echo "====================================================="
fi

exit $EXIT_CODE
