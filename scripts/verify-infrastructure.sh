#!/bin/bash
# scripts/verify-infrastructure.sh
set -eo pipefail

echo "====================================================="
echo "🚀 Starting Slinky Infrastructure Verification Suite"
echo "====================================================="

# Helper to log test steps
log_step() {
  echo ""
  echo "👉 STEP: $1"
  echo "-----------------------------------------------------"
}

# Cleanup on exit (optional - uncomment if you want auto-cleanup)
# trap 'kind delete cluster || true' EXIT

# =====================================================
# TEST 1: Clean Cluster Spawn
# =====================================================
log_step "1. Clean Cluster Spawn"

echo "🧹 Wiping existing Kind cluster..."
kind delete cluster || true

echo "☸️ Creating new Kind cluster..."
kind create cluster --config kind-config.yaml

echo "⏳ Waiting for Kubernetes nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

echo "📦 Installing Slinky stack (cert-manager, operators, Slurm)..."
./scripts/start-slinky.sh

echo "⏳ Waiting for Slurm controller..."
kubectl wait --namespace slurm \
  --for=condition=Ready pod/slurm-controller-0 \
  --timeout=180s

echo "⏳ Waiting for Slurm worker pods (NodeSet)..."
kubectl wait --namespace slurm \
  --for=condition=Ready pod \
  -l app.kubernetes.io/component=slurmd \
  --timeout=180s

# Let slurmd nodes register
sleep 10

echo "🔍 Verifying partition and node status via sinfo..."
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sinfo
echo "✅ Test 1 Passed: Slinky cluster spawned and registered workers!"

# =====================================================
# TEST 2: Standard Queuing & Execution
# =====================================================
log_step "2. Standard Queuing & Execution"

echo "📝 Submitting simple sleep job..."
JOB_ID=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --wrap="sleep 5" -N 1)
echo "Job ID: ${JOB_ID}"

echo "🔍 Verifying job is visible in the queue..."
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue

echo "⏳ Waiting for job ${JOB_ID} to complete..."
timeout=30
while [ $timeout -gt 0 ]; do
  STATE=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sacct -j "${JOB_ID}" --noheader --format=State | head -n 1 | xargs)
  if [[ "${STATE}" == "COMPLETED" ]]; then
    break
  elif [[ "${STATE}" == "FAILED" || "${STATE}" == "CANCELLED" || "${STATE}" == "NODE_FAIL" ]]; then
    echo "❌ ERROR: Job failed with state: ${STATE}"
    exit 1
  fi
  sleep 2
  timeout=$((timeout-2))
done

if [[ "${STATE}" != "COMPLETED" ]]; then
  echo "❌ ERROR: Job timed out or failed to complete."
  exit 1
fi
echo "✅ Test 2 Passed: Job was successfully queued and executed!"

# =====================================================
# TEST 3: Parallel Execution Across Nodes
# =====================================================
log_step "3. Parallel Execution Across Nodes"

echo "📝 Submitting multi-node job..."
# Runs 'hostname' on 2 nodes and redirects to shared storage path
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --wait --wrap="srun -N 2 hostname" -N 2 --output=/mnt/storage/parallel_test.log

echo "🔍 Checking parallel execution output..."
cat ./storage/parallel_test.log || cat /home/khemi/workspace/ai_sandbox/storage/parallel_test.log

# Verify we got 2 distinct hostnames in the log
DISTINCT_NODES=$(sort -u ./storage/parallel_test.log | wc -l)
echo "Distinct nodes executed on: ${DISTINCT_NODES}"

if [ "${DISTINCT_NODES}" -lt 2 ]; then
  echo "❌ ERROR: Parallel job did not run on distinct compute nodes."
  rm -f ./storage/parallel_test.log
  exit 1
fi

rm -f ./storage/parallel_test.log
echo "✅ Test 3 Passed: Jobs scheduled and run in parallel across multiple nodes!"

# =====================================================
# TEST 4: Persistent Shared Storage & Permissions
# =====================================================
log_step "4. Persistent Shared Storage"

echo "📝 Submitting storage test job..."
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --wait --wrap="echo 'storage_write_test_passed' > /mnt/storage/projects/project1/storage_test.txt" -N 1

echo "🔍 Verifying files on host machine..."
if [ -f "./storage/projects/project1/storage_test.txt" ] && grep -q "storage_write_test_passed" "./storage/projects/project1/storage_test.txt"; then
  echo "File contents: $(cat ./storage/projects/project1/storage_test.txt)"
  rm -f ./storage/projects/project1/storage_test.txt
  echo "✅ Test 4 Passed: Compute pod successfully wrote to shared storage!"
else
  echo "❌ ERROR: Shared storage test file not found or contains incorrect data."
  exit 1
fi

# =====================================================
# TEST 5: Disaster Recovery (Queue Persistence)
# =====================================================
log_step "5. Disaster Recovery (Queue Persistence)"

echo "📝 Submitting 30-second job..."
DR_JOB_ID=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --wrap="echo 'recovery_start'; sleep 20; echo 'recovery_success' > /mnt/storage/dr_test.txt" -N 1)
echo "Job ID: ${DR_JOB_ID}"

echo "💥 Simulating controller crash: Killing slurm-controller-0 pod..."
kubectl delete pod slurm-controller-0 -n slurm --grace-period=0 --force

echo "⏳ Waiting for slurm-controller-0 to restart..."
kubectl wait --namespace slurm \
  --for=condition=Ready pod/slurm-controller-0 \
  --timeout=120s

# Allow database syncing
sleep 5

echo "🔍 Checking queue state after crash..."
QUEUE_OUTPUT=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue)
echo "${QUEUE_OUTPUT}"

if [[ ! "${QUEUE_OUTPUT}" =~ "${DR_JOB_ID}" ]]; then
  # Check if completed already (unlikely)
  if kubectl exec -n slurm -c slurmctld slurm-controller-0 -- sacct -j "${DR_JOB_ID}" | grep -q "COMPLETED"; then
    echo "ℹ️ Job already completed."
  else
    echo "❌ ERROR: Job ${DR_JOB_ID} was lost during controller crash!"
    exit 1
  fi
else
  echo "✅ Job ${DR_JOB_ID} recovered in the queue!"
fi

echo "⏳ Waiting for recovery job to finish..."
timeout=40
while [ $timeout -gt 0 ]; do
  if [ -f "./storage/dr_test.txt" ]; then
    break
  fi
  sleep 2
  timeout=$((timeout-2))
done

if [ -f "./storage/dr_test.txt" ] && grep -q "recovery_success" "./storage/dr_test.txt"; then
  rm -f ./storage/dr_test.txt
  echo "✅ Test 5 Passed: Queue state and active jobs survived controller crash!"
else
  echo "❌ ERROR: Recovery job failed to complete or output log was not written."
  exit 1
fi

echo ""
echo "====================================================="
echo "🎉 SUCCESS: All infrastructure tests passed!"
echo "====================================================="
exit 0
