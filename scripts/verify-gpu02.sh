#!/bin/bash
# scripts/verify-gpu02.sh
# Locked Gate C Empirical Verification Probe for Unit WP04-B:
# Secondary GPU Compute Node Integration (ai-sandbox-gpu02 / RTX 3060 Ti 8GB)
#
# Verifies AC #1 - AC #5 on the live Proxmox K3s + Slinky Slurm cluster.
# (AC #6 SSH key revocation is verified separately at Gate D handoff.)

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-proxmox}"

PASS=0
FAIL=0
TARGET_NODE="ai-sandbox-gpu02"
L40_NODE="ai-sandbox-gpu-vm"

pass() { echo "✅ [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "❌ [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "============================================================"
echo "🔬 WP04-B Verification Probe: $TARGET_NODE (RTX 3060 Ti)"
echo "============================================================"

# ------------------------------------------------------------
# AC #1: Node Readiness, Labels, and Exclusive GPU Capacity (1)
# ------------------------------------------------------------
echo ""
echo "--- [AC #1] Node Readiness, Labels & Exclusive GPU Capacity ---"
NODE_READY=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Missing")
if [ "$NODE_READY" = "True" ]; then
    pass "Node $TARGET_NODE is Ready"
else
    fail "Node $TARGET_NODE is not Ready (got: '$NODE_READY')"
fi

ACCEL_LABEL=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.accelerator}' 2>/dev/null || echo "")
MODEL_LABEL=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.gpu-model}' 2>/dev/null || echo "")
ROLE_LABEL=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.gpu-role}' 2>/dev/null || echo "")
if [ "$ACCEL_LABEL" = "nvidia-gpu" ] && [ "$MODEL_LABEL" = "rtx3060ti" ] && [ "$ROLE_LABEL" = "compute" ]; then
    pass "Node labels verified (accelerator=$ACCEL_LABEL, gpu-model=$MODEL_LABEL, gpu-role=$ROLE_LABEL)"
else
    fail "Node labels mismatch (accelerator='$ACCEL_LABEL', gpu-model='$MODEL_LABEL', gpu-role='$ROLE_LABEL')"
fi

GPU_CAP=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [ "$GPU_CAP" = "1" ]; then
    pass "Exclusive GPU capacity verified (nvidia.com/gpu == 1, no time-slicing OOM risk)"
else
    fail "Expected exclusive nvidia.com/gpu == '1' on $TARGET_NODE, got '$GPU_CAP'"
fi

# ------------------------------------------------------------
# AC #4: Negative Proof — Device Plugin Mutual Exclusion
# ------------------------------------------------------------
echo ""
echo "--- [AC #4] Device Plugin Mutual Exclusion ---"
DP_COUNT=$(kubectl get pods -n kube-system --field-selector "spec.nodeName=$TARGET_NODE" --no-headers 2>/dev/null | grep -c "nvidia-device-plugin" || true)
DP_RUNNING=$(kubectl get pods -n kube-system --field-selector "spec.nodeName=$TARGET_NODE,status.phase=Running" --no-headers 2>/dev/null | grep -c "nvidia-device-plugin" || true)
if [ "$DP_COUNT" -eq 1 ] && [ "$DP_RUNNING" -eq 1 ]; then
    pass "Exactly 1 Running nvidia-device-plugin pod on $TARGET_NODE (no duplicate plugin collision)"
else
    fail "Expected 1 Running nvidia-device-plugin pod on $TARGET_NODE (found total=$DP_COUNT, running=$DP_RUNNING)"
fi

# ------------------------------------------------------------
# AC #3: Negative Proof — vLLM Isolation (Never Schedules on gpu02)
# ------------------------------------------------------------
echo ""
echo "--- [AC #3] vLLM Isolation (Pinned Strictly to $L40_NODE) ---"
VLLM_SELECTOR=$(kubectl get deploy vllm -n services -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}' 2>/dev/null || echo "")
VLLM_ON_GPU02=$(kubectl get pods -n services -l app=vllm --field-selector "spec.nodeName=$TARGET_NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$VLLM_SELECTOR" = "$L40_NODE" ] && [ "$VLLM_ON_GPU02" -eq 0 ]; then
    pass "vLLM remains strictly pinned to $L40_NODE (0 vLLM pods on $TARGET_NODE)"
else
    fail "vLLM isolation violated (nodeSelector='$VLLM_SELECTOR', pods on $TARGET_NODE=$VLLM_ON_GPU02)"
fi

# ------------------------------------------------------------
# AC #2: Slurm GPU Worker Running on gpu02 + Live sbatch GPU Job
# ------------------------------------------------------------
echo ""
echo "--- [AC #2] Slurm GPU Worker Placement & Live sbatch GPU Job ---"
SLURMD_NODE=$(kubectl get pod slurm-worker-slurmd-gpu-0 -n slurm -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
SLURMD_PHASE=$(kubectl get pod slurm-worker-slurmd-gpu-0 -n slurm -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
SLURMD_READY=$(kubectl get pod slurm-worker-slurmd-gpu-0 -n slurm -o jsonpath='{.status.containerStatuses[?(@.name=="slurmd")].ready}' 2>/dev/null || echo "false")

if [ "$SLURMD_NODE" = "$TARGET_NODE" ] && [ "$SLURMD_PHASE" = "Running" ] && [ "$SLURMD_READY" = "true" ]; then
    pass "slurm-worker-slurmd-gpu-0 is Running & Ready on $TARGET_NODE"

    # Submit live Slurm batch-gpu job and verify RTX 3060 Ti output on /mnt/storage
    JOB_OUT="/mnt/storage/scratch/verify-gpu02-$$.out"
    JOB_ID=$(kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
        sbatch --parsable --partition=batch-gpu --gres=gpu:1 --time=00:02:00 \
        --output="$JOB_OUT" \
        --wrap="nvidia-smi --query-gpu=name,memory.total --format=csv,noheader" 2>/dev/null || echo "")

    if [ -n "$JOB_ID" ]; then
        echo "   Submitted Slurm job $JOB_ID; waiting up to 45s for completion..."
        for _ in $(seq 1 15); do
            STATE=$(kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
                sacct -j "$JOB_ID" --format=State --noheader -P 2>/dev/null | head -n 1 | tr -d '[:space:]' || echo "")
            if [ "$STATE" = "COMPLETED" ] || [ "$STATE" = "FAILED" ] || [ "$STATE" = "CANCELLED" ]; then
                break
            fi
            sleep 3
        done

        GPU_OUTPUT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- cat "$JOB_OUT" 2>/dev/null || echo "")
        kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- rm -f "$JOB_OUT" 2>/dev/null || true

        if [ "$STATE" = "COMPLETED" ] && echo "$GPU_OUTPUT" | grep -qi "3060 Ti"; then
            pass "Live sbatch GPU job $JOB_ID COMPLETED on RTX 3060 Ti: $GPU_OUTPUT"
        else
            fail "Slurm GPU job $JOB_ID failed or unexpected output (state='$STATE', output='$GPU_OUTPUT')"
        fi
    else
        fail "Failed to submit sbatch --partition=batch-gpu --gres=gpu:1 job"
    fi
else
    fail "slurm-worker-slurmd-gpu-0 not Running/Ready on $TARGET_NODE (node='$SLURMD_NODE', phase='$SLURMD_PHASE', ready='$SLURMD_READY')"
fi

# ------------------------------------------------------------
# AC #5: Cluster Invariants (Zero Regressions)
# ------------------------------------------------------------
echo ""
echo "--- [AC #5] Cluster Invariants (Existing Services Healthy) ---"
INVARIANT_OK=true
for node in ai-control ai-worker1; do
    ST=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [ "$ST" != "True" ]; then
        echo "   Invariant breach: node $node Ready=$ST"
        INVARIANT_OK=false
    fi
done

for pod_spec in "slurm/slurm-worker-slurmd-cpu-0" "slurm/slurm-worker-slurmd-cpu-1" "slurm/mariadb-0"; do
    NS="${pod_spec%%/*}"
    POD="${pod_spec##*/}"
    PH=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
    if [ "$PH" != "Running" ]; then
        echo "   Invariant breach: pod $pod_spec phase=$PH"
        INVARIANT_OK=false
    fi
done

PORTAL_READY=$(kubectl get deploy hpc-portal -n slurm -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
QDRANT_READY=$(kubectl get statefulset qdrant -n services -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${PORTAL_READY:-0}" -lt 1 ] || [ "${QDRANT_READY:-0}" -lt 1 ]; then
    echo "   Invariant breach: hpc-portal ready=${PORTAL_READY:-0}, qdrant ready=${QDRANT_READY:-0}"
    INVARIANT_OK=false
fi

if [ "$INVARIANT_OK" = "true" ]; then
    pass "All baseline cluster invariants healthy (ai-control, ai-worker1, slurmd-cpu-[0-1], mariadb-0, hpc-portal, qdrant)"
else
    fail "One or more baseline cluster invariants degraded"
fi

echo ""
echo "============================================================"
echo "Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ]
