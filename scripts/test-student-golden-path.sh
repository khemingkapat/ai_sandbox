#!/usr/bin/env bash
# scripts/test-student-golden-path.sh
# ==============================================================================
# AI Sandbox: WP3-1-17 Real-World Student Workflow Validation (Smoke Test)
# Validates the full non-root student (UID 1001) data path across:
#   1. Storage permissions & VFS (/mnt/storage/datasets -> /mnt/storage/projects/project1)
#   2. Authenticated Central Inference (vLLM via Traefik Ingress on port 443)
#   3. Experiment Tracking (MLflow metrics & run registration)
#   4. Batch GPU Execution (Slurm + Apptainer on physical NVIDIA L40)
# ==============================================================================
set -euo pipefail

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-proxmox}"
PROBE_POD="smoke-student-probe-$$"
OUTPUT_DIR="/mnt/storage/projects/project1"
SMOKE_JSON="${OUTPUT_DIR}/smoke_output.json"
GPU_LOG="${OUTPUT_DIR}/smoke_gpu_job.out"
VLLM_SCALED_DOWN=false
PARTITION_ACTIVATED=false

echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "${CYAN}${BOLD}🧪 AI Sandbox: WP3-1-17 Real-World Student Golden Path Smoke Test${NC}"
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "Timestamp : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo -e "Context   : $(kubectl config current-context 2>/dev/null || echo 'Unknown')"
echo ""

# ------------------------------------------------------------------------------
# Guaranteed Teardown and Rollback Trap
# ------------------------------------------------------------------------------
cleanup() {
    echo ""
    echo -e "${BLUE}🧹 [Teardown] Running recovery state machine...${NC}"
    
    # 1. Delete ephemeral probe pod if present
    if kubectl get pod "${PROBE_POD}" -n workload &>/dev/null; then
        echo -e "  Cleaning ephemeral probe pod ${PROBE_POD}..."
        kubectl delete pod "${PROBE_POD}" -n workload --grace-period=0 --force &>/dev/null || true
    fi

    # 2. Reset Slurm batch-gpu partition state to INACTIVE if it was activated
    if [ "${PARTITION_ACTIVATED}" = true ]; then
        echo -e "  Resetting Slurm partition batch-gpu to INACTIVE..."
        kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
            scontrol update PartitionName=batch-gpu State=INACTIVE &>/dev/null || true
    fi

    # 3. Restore vLLM deployment to 1 replica if it was scaled down
    if [ "${VLLM_SCALED_DOWN}" = true ]; then
        echo -e "  Restoring vLLM central inference deployment to 1 replica..."
        kubectl scale deploy/vllm -n services --replicas=1 &>/dev/null || true
        echo -e "  Waiting for vLLM rollout recovery (up to 300s)..."
        kubectl rollout status deploy/vllm -n services --timeout=300s || true
    fi

    # 4. Clean temporary test outputs
    kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- \
        rm -f "${SMOKE_JSON}" "${GPU_LOG}" &>/dev/null || true

    echo -e "${GREEN}✨ Teardown complete. Cluster state reconciled.${NC}"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Step 0: Pre-flight Verification & Token Generation
# ------------------------------------------------------------------------------
echo -e "${YELLOW}▶ Step 0: Pre-flight Checks & Student Token Minting${NC}"
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}❌ kubectl not found${NC}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo -e "${RED}❌ python3 not found${NC}"; exit 1; }

# Verify connectivity
kubectl get nodes >/dev/null 2>&1 || {
    echo -e "${RED}❌ Cannot connect to Kubernetes API. Check SSH tunnel (ptunnel).${NC}"
    exit 1
}

# Mint valid HMAC-SHA256 Bearer Token for user1
echo "  Generating HMAC-SHA256 Bearer token for student user1..."
STUDENT_TOKEN=$(python3 -c "
import base64, subprocess, json, time, hmac, hashlib
cmd = ['kubectl', 'get', 'secret', 'slurm-auth-jwt', '-n', 'slurm', '-o', r'jsonpath={.data.jwt\.key}']
secret = base64.b64decode(subprocess.run(cmd, capture_output=True, check=True).stdout.strip())
header = {'alg': 'HS256', 'typ': 'JWT'}
payload = {
    'sub': 'user1',
    'aud': 'vllm-api',
    'iss': 'ai-sandbox-portal',
    'iat': int(time.time()),
    'exp': int(time.time()) + 3600
}
def b64url(b): return base64.urlsafe_b64encode(b).decode().rstrip('=')
h = b64url(json.dumps(header, separators=(',', ':')).encode())
p = b64url(json.dumps(payload, separators=(',', ':')).encode())
sig = b64url(hmac.new(secret, f'{h}.{p}'.encode(), hashlib.sha256).digest())
print(f'{h}.{p}.{sig}')
")

if [ -z "${STUDENT_TOKEN}" ]; then
    echo -e "${RED}❌ Failed to mint student Bearer token from slurm-auth-jwt${NC}"
    exit 1
fi
echo -e "  ${GREEN}✅ Token generated successfully.${NC}"

# ------------------------------------------------------------------------------
# Step 1: Execute Student Interactive Probe (Storage + Inference + MLflow)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 1: Launching Student Interactive Session in 'workload' Namespace (UID 1001)${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${PROBE_POD}
  namespace: workload
  labels:
    app.kubernetes.io/name: student-smoke-probe
    app.kubernetes.io/component: interactive-session
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
  tolerations:
  - key: "slinky.slurm.net/managed-node"
    operator: "Exists"
    effect: "NoExecute"
  volumes:
  - name: storage-volume
    persistentVolumeClaim:
      claimName: slinky-storage-pvc
  containers:
  - name: student-probe
    image: interactive-jupyter:latest
    imagePullPolicy: IfNotPresent
    volumeMounts:
    - name: storage-volume
      mountPath: /mnt/storage
    env:
    - name: SANDBOX_INFERENCE_TOKEN
      value: "${STUDENT_TOKEN}"
    - name: MLFLOW_TRACKING_URI
      value: "http://mlflow.services.svc.cluster.local:5000"
    command:
    - python3
    - -c
    - |
      import os, sys, json, time, ssl, urllib.request

      print("=== 1. Testing Storage VFS & POSIX Permissions ===")
      dataset_path = "/mnt/storage/datasets/nlp/imdb"
      assert os.path.exists(dataset_path), f"Dataset path missing: {dataset_path}"
      print(f"  [PASS] Read datasets directory: {dataset_path}")

      out_file = "/mnt/storage/projects/project1/smoke_output.json"
      test_payload = {
          "status": "OK",
          "user": "user1",
          "uid": os.getuid(),
          "timestamp": time.time()
      }
      with open(out_file, "w") as f:
          json.dump(test_payload, f)
      assert os.path.exists(out_file), "Output file was not created"
      print(f"  [PASS] Wrote student output to: {out_file} (UID: {os.getuid()})")

      print("\n=== 2. Testing Authenticated LLM Inference (vLLM via Traefik :443) ===")
      vllm_url = "https://portal.slurm.svc.cluster.local:443/v1/chat/completions"
      token = os.environ["SANDBOX_INFERENCE_TOKEN"]
      req_data = json.dumps({
          "model": "Qwen/Qwen3.5-0.8B",
          "messages": [{"role": "user", "content": "What is 2+2? Answer only with the number."}],
          "max_tokens": 10,
          "temperature": 0.0
      }).encode("utf-8")

      req = urllib.request.Request(
          vllm_url,
          data=req_data,
          headers={
              "Authorization": f"Bearer {token}",
              "Content-Type": "application/json"
          }
      )
      ctx = ssl._create_unverified_context()
      with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
          assert resp.status == 200, f"vLLM responded with HTTP {resp.status}"
          resp_body = json.loads(resp.read().decode("utf-8"))
          answer = resp_body["choices"][0]["message"]["content"].strip()
          print(f"  [PASS] ForwardAuth verified Bearer token.")
          print(f"  [PASS] vLLM generated completion tokens: '{answer}'")

      print("\n=== 3. Testing Central Experiment Tracking (MLflow :5000) ===")
      mlflow_base = os.environ["MLFLOW_TRACKING_URI"]
      # Create Run
      create_req = urllib.request.Request(
          f"{mlflow_base}/api/2.0/mlflow/runs/create",
          data=json.dumps({"experiment_id": "0", "user_id": "user1"}).encode("utf-8"),
          headers={"Content-Type": "application/json"}
      )
      with urllib.request.urlopen(create_req, timeout=10) as r:
          run_data = json.loads(r.read().decode("utf-8"))
          run_id = run_data["run"]["info"]["run_id"]
          print(f"  [PASS] Registered MLflow run ID: {run_id}")

      # Log Metrics
      for step, loss_val in enumerate([0.5, 0.3, 0.1]):
          log_req = urllib.request.Request(
              f"{mlflow_base}/api/2.0/mlflow/runs/log-metric",
              data=json.dumps({
                  "run_id": run_id,
                  "key": "loss",
                  "value": loss_val,
                  "timestamp": int(time.time() * 1000),
                  "step": step
              }).encode("utf-8"),
              headers={"Content-Type": "application/json"}
          )
          urllib.request.urlopen(log_req, timeout=10)
      print("  [PASS] Logged 3 loss metric steps to MLflow backend.")

      # Finish Run
      end_req = urllib.request.Request(
          f"{mlflow_base}/api/2.0/mlflow/runs/update",
          data=json.dumps({"run_id": run_id, "status": "FINISHED", "end_time": int(time.time() * 1000)}).encode("utf-8"),
          headers={"Content-Type": "application/json"}
      )
      urllib.request.urlopen(end_req, timeout=10)
      print("  [PASS] Updated MLflow run status to FINISHED.")

      print("\n✨ Student Interactive Workflow completed successfully!")
EOF

echo "  Waiting for student probe pod to complete..."
kubectl wait --for=condition=Ready pod/"${PROBE_POD}" -n workload --timeout=30s >/dev/null 2>&1 || true

# Wait until pod is Succeeded or Failed
TIMEOUT=60
while [ $TIMEOUT -gt 0 ]; do
    PHASE=$(kubectl get pod "${PROBE_POD}" -n workload -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$PHASE" == "Succeeded" ]; then
        break
    elif [ "$PHASE" == "Failed" ]; then
        echo -e "${RED}❌ Probe pod failed.${NC}"
        kubectl logs "${PROBE_POD}" -n workload
        exit 1
    fi
    sleep 2
    TIMEOUT=$((TIMEOUT-2))
done

if [ "$PHASE" != "Succeeded" ]; then
    echo -e "${RED}❌ Probe pod timed out. Current phase: ${PHASE}${NC}"
    kubectl logs "${PROBE_POD}" -n workload 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}Probe Execution Output:${NC}"
kubectl logs "${PROBE_POD}" -n workload
kubectl delete pod "${PROBE_POD}" -n workload --grace-period=0 --force >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Step 2: Sequential GPU Transition State Machine
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 2: Transitioning Single L40 GPU from Inference to Batch Compute${NC}"

echo "  Scaling down vLLM deployment to 0 replicas to release 40GB VRAM..."
kubectl scale deploy/vllm -n services --replicas=0
VLLM_SCALED_DOWN=true

echo "  Waiting for vLLM pod termination..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=vllm -n services --timeout=60s

echo "  Flushing Linux kernel /dev/nvidia* CUDA memory contexts (sleeping 5s)..."
sleep 5

echo "  Activating Slurm 'batch-gpu' partition (State=UP)..."
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
    scontrol update PartitionName=batch-gpu State=UP
PARTITION_ACTIVATED=true
echo -e "  ${GREEN}✅ batch-gpu partition is now active.${NC}"

# ------------------------------------------------------------------------------
# Step 3: Execute Slurm Batch GPU Job as user1 (Apptainer + L40 Access)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 3: Submitting Slurm Batch GPU Job as user1${NC}"

JOB_OUTPUT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- su -s /bin/bash user1 -c "
    sbatch --partition=batch-gpu \
           --gres=gpu:1 \
           --job-name=smoke-gpu \
           -o ${GPU_LOG} \
           --wait \
           --wrap='apptainer exec --nv /mnt/storage/common/software/python.sif nvidia-smi'
")
echo "  ${JOB_OUTPUT}"

echo "  Verifying Slurm batch job output log..."
LOG_CONTENT=$(kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- cat "${GPU_LOG}")
echo "${LOG_CONTENT}"

if echo "${LOG_CONTENT}" | grep -q "NVIDIA L40"; then
    echo -e "  ${GREEN}✅ [PASS] Job successfully executed inside Apptainer with physical NVIDIA L40 binding!${NC}"
else
    echo -e "  ${RED}❌ [FAIL] Expected 'NVIDIA L40' in job log.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 4: Cluster Recovery & Restoration
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 4: Deactivating batch-gpu & Restoring Central vLLM Service${NC}"

echo "  Setting Slurm 'batch-gpu' partition back to INACTIVE..."
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
    scontrol update PartitionName=batch-gpu State=INACTIVE
PARTITION_ACTIVATED=false

echo "  Scaling up vLLM central inference deployment to 1 replica..."
kubectl scale deploy/vllm -n services --replicas=1
VLLM_SCALED_DOWN=false

echo "  Waiting for vLLM rollout to complete and weights to load (timeout: 300s)..."
kubectl rollout status deploy/vllm -n services --timeout=300s
echo -e "  ${GREEN}✅ Central vLLM inference service is restored and Ready!${NC}"

# ------------------------------------------------------------------------------
# Step 5: Acceptance Criteria Verification Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "${GREEN}${BOLD}🏆 WP3-1-17 Golden Path Student Smoke Test: ALL GATES PASSED!${NC}"
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "  ${GREEN}✅ A1 (Storage Permissions):${NC} Read /mnt/storage/datasets, wrote smoke_output.json as UID 1001"
echo -e "  ${GREEN}✅ A2 (Inference ForwardAuth):${NC} Authenticated via Traefik :443 with HMAC Bearer, generated tokens"
echo -e "  ${GREEN}✅ A3 (MLflow Tracking):${NC} Registered run, logged 3 metric loss steps, finished run"
echo -e "  ${GREEN}✅ A4 (Slurm Batch GPU):${NC} Dispatched sbatch with --gres=gpu:1, bound L40 GPU via Apptainer"
echo -e "  ${GREEN}✅ A5 (Clean Teardown):${NC} Ephemeral pods cleaned, batch-gpu set INACTIVE, vLLM restored"
echo ""
