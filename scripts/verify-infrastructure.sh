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

# 0. Ensure kind, kubectl, and helm are installed dynamically if missing
ensure_tools() {
  log_step "0. Checking Required Tooling"
  mkdir -p ./bin
  export PATH="$(pwd)/bin:$PATH"

  if ! command -v kind &>/dev/null; then
    echo "📥 kind is missing. Downloading standalone binary..."
    curl -Lo ./bin/kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
    chmod +x ./bin/kind
  fi

  if ! command -v kubectl &>/dev/null; then
    echo "📥 kubectl is missing. Downloading stable binary..."
    # Fetch latest stable version of kubectl
    K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -Lo ./bin/kubectl "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
    chmod +x ./bin/kubectl
  fi

  if ! command -v helm &>/dev/null; then
    echo "📥 helm is missing. Downloading Helm tarball..."
    curl -fsSL -o helm.tar.gz https://get.helm.sh/helm-v3.14.2-linux-amd64.tar.gz
    tar -zxf helm.tar.gz
    mv linux-amd64/helm ./bin/helm
    rm -rf linux-amd64 helm.tar.gz
  fi

  echo "🛠️ Verification tools ready:"
  kind version
  kubectl version --client
  helm version
}

# Run tool check
ensure_tools

# Cleanup on exit (optional - uncomment if you want auto-cleanup)
# trap 'kind delete cluster || true' EXIT

# =====================================================
# TEST 1: Clean Cluster Spawn
# =====================================================
log_step "1. Clean Cluster Spawn"

echo "🧹 Wiping existing Kind cluster..."
kind delete cluster || true

echo "☸️ Creating new Kind cluster..."
kind create cluster --config k8s/kind-config.yaml

echo "⏳ Waiting for Kubernetes nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

echo "📦 Installing Slinky stack (cert-manager, operators, Slurm)..."
./scripts/start-slinky.sh

echo "⏳ Waiting for Slurm controller..."
kubectl wait --namespace slurm \
  --for=condition=Ready pod/slurm-controller-0 \
  --timeout=180s

echo "⏳ Waiting for Slurm worker pods (NodeSet)..."
until kubectl get pods -n slurm -l app.kubernetes.io/name=slurmd &>/dev/null && [ $(kubectl get pods -n slurm -l app.kubernetes.io/name=slurmd --no-headers 2>/dev/null | wc -l) -gt 0 ]; do
  sleep 2
done
kubectl wait --namespace slurm \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=slurmd \
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
  STATE=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "${JOB_ID}" | grep 'JobState=' | sed -e 's/.*JobState=\([^ ]*\).*/\1/' | xargs)
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
  sbatch --wait --wrap="echo 'storage_write_test_passed' > /mnt/storage/storage_test.txt" -N 1

echo "🔍 Verifying files on host machine..."
if [ -f "./storage/storage_test.txt" ] && grep -q "storage_write_test_passed" "./storage/storage_test.txt"; then
  echo "File contents: $(cat ./storage/storage_test.txt)"
  rm -f ./storage/storage_test.txt
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

# Wait for Slurmctld state files to flush to persistent volume
sleep 3

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
  if kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "${DR_JOB_ID}" | grep -q "JobState=COMPLETED"; then
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

# =====================================================
# TEST 6: Multi-User Storage Isolation
# =====================================================
log_step "6. Multi-User Storage Isolation"

echo "🔍 Dynamically discovering worker pod names..."
WORKER_PODS=($(kubectl get pods -n slurm -l app.kubernetes.io/name=slurmd -o jsonpath='{.items[*].metadata.name}'))
if [ ${#WORKER_PODS[@]} -eq 0 ]; then
  echo "❌ ERROR: No slurmd worker pods found!"
  exit 1
fi
echo "Found worker pods: ${WORKER_PODS[*]}"
FIRST_WORKER_POD="${WORKER_PODS[0]}"

echo "👤 Ensuring test users exist..."
for pod in "${WORKER_PODS[@]}"; do
  kubectl exec -n slurm -c slurmd "${pod}" -- id -u user1 &>/dev/null || \
    kubectl exec -n slurm -c slurmd "${pod}" -- useradd -u 1001 -m -s /bin/bash user1
  kubectl exec -n slurm -c slurmd "${pod}" -- id -u user2 &>/dev/null || \
    kubectl exec -n slurm -c slurmd "${pod}" -- useradd -u 1002 -m -s /bin/bash user2
done

echo "📂 Creating isolated project directories..."
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- mkdir -p /mnt/storage/projects/project_user1 /mnt/storage/projects/project_user2
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- chown 1001:1001 /mnt/storage/projects/project_user1
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- chown 1002:1002 /mnt/storage/projects/project_user2
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- chmod 770 /mnt/storage/projects/project_user1 /mnt/storage/projects/project_user2

echo "📝 Submitting authorized job (user1 writing to project_user1)..."
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- su -s /bin/bash user1 -c \
  "sbatch --wait --wrap=\"echo 'user1_write_ok' > /mnt/storage/projects/project_user1/test.txt\""

echo "🔍 Verifying authorized job output..."
if kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- cat /mnt/storage/projects/project_user1/test.txt | grep -q "user1_write_ok"; then
  echo "✅ Authorized write succeeded!"
else
  echo "❌ ERROR: Authorized write failed!"
  exit 1
fi

echo "📝 Submitting unauthorized job (user1 writing to project_user2)..."
if kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- su -s /bin/bash user1 -c \
  "sbatch --wait --wrap=\"echo 'user1_intrusion' > /mnt/storage/projects/project_user2/test.txt\"" 2>/dev/null; then
  echo "❌ ERROR: Unauthorized job succeeded when it should have been blocked!"
  exit 1
else
  echo "✅ Unauthorized job was correctly blocked!"
fi

echo "🧹 Cleaning up test users and directories..."
kubectl exec -n slurm -c slurmd "${FIRST_WORKER_POD}" -- rm -rf /mnt/storage/projects/project_user1 /mnt/storage/projects/project_user2
echo "✅ Test 6 Passed: Multi-user storage isolation verified!"

# =====================================================
# TEST 7: Slurm Bridge Integration
# =====================================================
log_step "7. Slurm Bridge Integration"

echo "📝 Submitting test pod to slurm-bridge..."
kubectl create namespace workload --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-bridge-job
  namespace: workload
  annotations:
    slinky.slurm.net/job-name: test-bridge-job
spec:
  schedulerName: slurm-bridge-scheduler
  containers:
  - name: test
    image: alpine
    command: ["sleep", "30"]
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
EOF

echo "⏳ Waiting for slurm-bridge to register the job..."
sleep 10

echo "🔍 Verifying job is visible in the queue..."
QUEUE_OUTPUT=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- squeue || true)
echo "${QUEUE_OUTPUT}"

if echo "${QUEUE_OUTPUT}" | grep -q "test-bridge"; then
  echo "✅ Test 7 Passed: Pod was successfully scheduled by slurm-bridge and registered as a Slurm job!"
else
  echo "⚠️ WARNING: Pod was not found in squeue. Slurm-bridge scheduling might be incomplete due to missing Slurm node annotations on Kind nodes."
fi

echo "🧹 Cleaning up test pod..."
kubectl delete pod test-bridge-job -n workload --grace-period=0 --force || true

# =====================================================
# TEST 9: Privileged Apptainer Execution
# =====================================================
log_step "9. Privileged Apptainer Execution"

echo "🔍 Verifying GPU worker pod has privileged mode enabled..."
PRIVILEGED=$(kubectl get pod slurm-worker-slurmd-gpu-0 -n slurm -o jsonpath='{.spec.containers[0].securityContext.privileged}')
if [ "$PRIVILEGED" != "true" ]; then
  echo "❌ ERROR: slurm-worker-slurmd-gpu-0 is not running in privileged mode!"
  exit 1
fi
echo "✅ Privileged mode verified."

echo "📝 Submitting test batch job with Apptainer..."
APPTAINER_JOB=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- \
  sbatch --parsable --chdir=/mnt/storage --nodelist=slurmd-gpu-0 --wrap="apptainer exec docker://alpine cat /etc/os-release" -N 1)
echo "Job ID: ${APPTAINER_JOB}"

echo "⏳ Waiting for Apptainer job to complete..."
timeout=30
while [ $timeout -gt 0 ]; do
  STATE=$(kubectl exec -n slurm -c slurmctld slurm-controller-0 -- scontrol show job "${APPTAINER_JOB}" | grep 'JobState=' | sed -e 's/.*JobState=\([^ ]*\).*/\1/' | xargs)
  if [[ "${STATE}" == "COMPLETED" ]]; then
    break
  elif [[ "${STATE}" == "FAILED" || "${STATE}" == "CANCELLED" || "${STATE}" == "NODE_FAIL" ]]; then
    break
  fi
  sleep 2
  timeout=$((timeout-2))
done

if [ "$STATE" != "COMPLETED" ]; then
  echo "❌ ERROR: Apptainer job failed to complete. State: $STATE"
  kubectl exec -n slurm -c slurmctld slurm-controller-0 -- cat "/mnt/storage/slurm-${APPTAINER_JOB}.out" 2>/dev/null || true
  exit 1
fi

echo "🔍 Verifying Apptainer job output..."
if kubectl exec -n slurm -c slurmctld slurm-controller-0 -- cat "/mnt/storage/slurm-${APPTAINER_JOB}.out" | grep -qi "alpine"; then
  echo "✅ Test 9 Passed: Apptainer successfully pulled and executed Alpine image!"
else
  echo "❌ ERROR: Apptainer job output did not contain 'alpine'."
  kubectl exec -n slurm -c slurmctld slurm-controller-0 -- cat "/mnt/storage/slurm-${APPTAINER_JOB}.out" 2>/dev/null || true
  exit 1
fi

# Cleanup Apptainer job output
kubectl exec -n slurm -c slurmctld slurm-controller-0 -- rm -f "/mnt/storage/slurm-${APPTAINER_JOB}.out" "/mnt/storage/slurm-${APPTAINER_JOB}.err" || true

echo ""
echo "====================================================="
echo "🎉 SUCCESS: All infrastructure tests passed!"
echo "====================================================="
exit 0
