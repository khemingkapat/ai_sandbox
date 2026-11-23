#!/usr/bin/env bash
# ==============================================================================
# verify-ci-hardware.sh
# In-Cluster Pre-Flight Hardware & Core Services Health Probe
# Designed to be modular so it can hook into WP13 Telemetry healthchecks later.
# ==============================================================================
set -euo pipefail

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo "⚠️  [CI-PROBE] Verification interrupted or failed (Exit code: $exit_code). Cleaning up..."
  fi
  exit $exit_code
}
trap cleanup EXIT INT TERM

echo "=============================================================================="
echo "🔍 [CI-PROBE] Stage 2 In-Cluster Hardware & Core Services Pre-Flight"
echo "=============================================================================="

# 1. Verify Kubernetes API connectivity & Node Fleet
echo "📡 [1/3] Checking Kubernetes cluster API & physical node fleet..."
if ! kubectl version --client >/dev/null 2>&1; then
  echo "❌ [FATAL] kubectl CLI not found."
  exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
  echo "❌ [FATAL] Cannot connect to Kubernetes API. Check cluster status and KUBECONFIG."
  exit 1
fi

TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -cw "Ready" || true)
echo "  ✅ Node Fleet: $READY_NODES / $TOTAL_NODES nodes Ready."

if [ "$READY_NODES" -lt "$TOTAL_NODES" ]; then
  echo "❌ [ERROR] One or more nodes are not Ready:"
  kubectl get nodes
  exit 1
fi

# 2. Fast Core Services & Database Health Matrix (Modular: WP13 Telemetry hook point)
echo "🏥 [2/3] Checking Core Control-Plane & Database readiness..."
check_pod_ready() {
  local ns="$1"
  local name="$2"
  local status
  status=$(kubectl get pod -n "$ns" -l "app.kubernetes.io/name=$name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  if [ -z "$status" ]; then
    # Try direct pod name
    status=$(kubectl get pod -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  fi

  if [ "$status" = "Running" ]; then
    echo "  ✅ [$ns] $name is Running"
    return 0
  else
    echo "  ❌ [$ns] $name is NOT Ready (Status: ${status:-NotFound})"
    return 1
  fi
}

CORE_FAILURES=0
# Slurm Accounting DB & Scheduler
check_pod_ready "slurm" "mariadb-0" || CORE_FAILURES=$((CORE_FAILURES + 1))
check_pod_ready "slurm" "slurm-controller-0" || CORE_FAILURES=$((CORE_FAILURES + 1))

# MLflow Postgres DB (if services namespace is active)
if kubectl get ns services >/dev/null 2>&1; then
  check_pod_ready "services" "mlflow-postgres-0" || true
fi

if [ "$CORE_FAILURES" -gt 0 ]; then
  echo "❌ [FATAL] Critical cluster infrastructure is down. Halting CI to isolate infrastructure failures from code regressions."
  exit 1
fi

# 3. Inspect physical GPU status (role-aware per ADR 0008)
echo "🎯 [3/3] Inspecting accelerator (GPU) hardware allocation..."
GPU_MAINTENANCE="${CLUSTER_GPU_MAINTENANCE:-false}"
INFERENCE_GPUS=$(kubectl get nodes -l gpu-role=inference -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END {print s+0}')
COMPUTE_GPUS=$(kubectl get nodes -l gpu-role=compute -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END {print s+0}')
TOTAL_GPUS=$((INFERENCE_GPUS + COMPUTE_GPUS))

echo "  Allocatable Inference GPUs (gpu-role=inference): $INFERENCE_GPUS"
echo "  Allocatable Compute GPUs   (gpu-role=compute)  : $COMPUTE_GPUS"
echo "  Total Allocatable GPUs                         : $TOTAL_GPUS"
echo "  L40 Maintenance mode flag                      : $GPU_MAINTENANCE"

echo "▶️  Verifying shared storage and permissions..."
bash scripts/verify-storage.sh

echo "▶️  Verifying network and security baseline..."
bash scripts/verify-security.sh

if [ "$COMPUTE_GPUS" -ge 1 ]; then
  echo "▶️  Compute GPU detected ($COMPUTE_GPUS allocatable). Running Slurm GPU compute probe..."
  KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}" bash scripts/verify-gpu02.sh
fi

if [ "$INFERENCE_GPUS" -eq 0 ]; then
  if [ "$GPU_MAINTENANCE" = "true" ]; then
    echo "⚠️  ========================================================================"
    echo "⚠️  NOTICE: CLUSTER_GPU_MAINTENANCE=true. Inference GPU (L40) is offline."
    echo "⚠️  Skipping L40-dependent suites (verify-llm.sh, golden-path GPU)."
    echo "⚠️  CPU, storage, security, and available compute GPU suites passed."
    echo "⚠️  ========================================================================"
    echo "✅ [SUCCESS] In-cluster verification passed (L40 inference suites skipped in maintenance mode)."
    exit 0
  else
    echo "❌ ========================================================================"
    echo "❌ FATAL: Cluster regression detected! Inference GPU (gpu-role=inference) is 0,"
    echo "❌ but CLUSTER_GPU_MAINTENANCE is 'false'."
    echo "❌ Expected NVIDIA L40 online. Possible driver, container-toolkit, or plugin failure."
    echo "❌ ========================================================================"
    exit 1
  fi
else
  echo "🚀 Inference GPU detected ($INFERENCE_GPUS allocatable). Running full LLM & golden-path suites..."
  bash scripts/verify-llm.sh
  bash scripts/test-student-golden-path.sh
  echo "=============================================================================="
  echo "✅ [SUCCESS] Full cluster and dual-GPU hardware verification passed."
  echo "=============================================================================="
  exit 0
fi
