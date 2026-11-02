#!/usr/bin/env bash
# scripts/test-student-golden-path.sh
# ==============================================================================
# AI Sandbox: WP3-1-17 Real-World Student Workflow Validation (Smoke Test)
# Validates both:
#   Part A (Core Golden Path):
#     1. Storage permissions & VFS
#     2. Authenticated Central Inference (vLLM via Traefik Ingress on port 443)
#     3. Experiment Tracking (MLflow metrics & artifact upload)
#     4. Batch GPU Execution (Slurm + Apptainer on physical NVIDIA L40)
#   Part B ("De-Utopia" Production Hardening):
#     5. Scoped subPath VFS isolation (no /mnt/storage/mlflow leak, EROFS on datasets)
#     6. Non-root UID 1001 / GID 2001 spawn & collaborative team permissions (2770)
#     7. Concurrent GPU time-slicing context fault isolation
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
GPU_POD_A="smoke-gpu-probe-a-$$"
GPU_POD_B="smoke-gpu-probe-b-$$"
OUTPUT_DIR="/mnt/storage/projects/project1"
SMOKE_JSON="${OUTPUT_DIR}/smoke_output.json"
COLLAB_TXT="${OUTPUT_DIR}/team_collab.txt"
GPU_LOG="${OUTPUT_DIR}/smoke_gpu_job.out"
VLLM_SCALED_DOWN=false
PARTITION_ACTIVATED=false

echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "${CYAN}${BOLD}🧪 AI Sandbox: WP3-1-17 Real-World Student Golden Path & De-Utopia Test${NC}"
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
    
    # 1. Delete ephemeral probe pods if present
    if kubectl get pod "${PROBE_POD}" -n workload &>/dev/null; then
        echo -e "  Cleaning ephemeral pod ${PROBE_POD}..."
        kubectl delete pod "${PROBE_POD}" -n workload --grace-period=0 --force &>/dev/null || true
    fi
    for p in "${GPU_POD_A}" "${GPU_POD_B}"; do
        if kubectl get pod "$p" -n default &>/dev/null; then
            echo -e "  Cleaning ephemeral GPU pod $p..."
            kubectl delete pod "$p" -n default --grace-period=0 --force &>/dev/null || true
        fi
    done

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
        rm -f "${SMOKE_JSON}" "${COLLAB_TXT}" "${GPU_LOG}" &>/dev/null || true

    echo -e "${GREEN}✨ Teardown complete. Cluster state reconciled.${NC}"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Step 0: Pre-flight Checks & Student Token Minting
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
# Step 1: Execute Student Interactive Probe (Scoped subPath, VFS, Auth, MLflow)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 1: Launching Student Interactive Session in 'workload' Namespace${NC}"
echo "  Enforcing Scoped subPath VolumeMounts & non-root PodSecurityContext (UID: 1001, GID: 2001)..."

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
  - name: student-probe
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
    - name: SANDBOX_INFERENCE_TOKEN
      value: "${STUDENT_TOKEN}"
    - name: MLFLOW_TRACKING_URI
      value: "http://mlflow.services.svc.cluster.local:5000"
    - name: TMPDIR
      value: "/mnt/storage/scratch"
    command:
    - python3
    - -c
    - |
      import os, sys, json, time, ssl, pwd, urllib.request

      # Enforce collaborative group-writable umask (0002 -> 0664 for files, 0775 for dirs)
      os.umask(0o002)

      print("=== 1. Testing Root-Squash-Safe Non-Root Identity ===")
      uid = os.getuid()
      gid = os.getgid()
      assert uid == 1001, f"Expected UID 1001, got {uid}"
      assert gid == 2001, f"Expected GID 2001, got {gid}"
      pw_name = pwd.getpwuid(uid).pw_name
      assert pw_name == "user1", f"Expected user1, got {pw_name}"
      print(f"  [PASS] Pod booted as {pw_name} (UID: {uid}, GID: {gid}) via SecurityContext")

      print("\n=== 2. Testing Scoped subPath VFS Isolation (Trap 2) ===")
      # 2.1 Verify raw service paths and other projects DO NOT exist in VFS
      assert not os.path.exists("/mnt/storage/mlflow"), "LEAK: /mnt/storage/mlflow is visible!"
      assert not os.path.exists("/mnt/storage/projects/project2"), "LEAK: project2 is visible!"
      print("  [PASS] Central service storage (/mnt/storage/mlflow) and other projects are invisible in VFS.")

      # 2.2 Verify Read-Only enforcement on datasets
      dataset_test = "/mnt/storage/datasets/nlp/imdb"
      assert os.path.exists(dataset_test), f"Dataset path missing: {dataset_test}"
      try:
          with open("/mnt/storage/datasets/leak_test.txt", "w") as f:
              f.write("should fail")
          sys.exit("LEAK: Datasets directory was writable!")
      except OSError as e:
          assert e.errno == 30, f"Expected EROFS (errno 30), got {e}"
          print("  [PASS] Kernel enforced EROFS (Read-only file system) on /mnt/storage/datasets.")

      # 2.3 Verify scratch write (mode 1777, non-root)
      scratch_test = "/mnt/storage/scratch/smoke_scratch_test.txt"
      with open(scratch_test, "w") as f:
          f.write("scratch ok")
      os.remove(scratch_test)
      print("  [PASS] Non-root process successfully wrote to shared /mnt/storage/scratch.")

      # 2.4 Verify private project write & collaborative team file creation
      out_file = "/mnt/storage/projects/project1/smoke_output.json"
      with open(out_file, "w") as f:
          json.dump({"status": "OK", "user": "user1", "uid": uid, "gid": gid}, f)
      assert os.path.exists(out_file), "Output file was not created"
      
      collab_file = "/mnt/storage/projects/project1/team_collab.txt"
      with open(collab_file, "w") as f:
          f.write("initial write by user1\n")
      print(f"  [PASS] Wrote student output to: {out_file}")
      print(f"  [PASS] Created collaborative file for project1: {collab_file}")

      print("\n=== 3. Testing Authenticated LLM Inference (vLLM via Traefik :443) ===")
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

      print("\n=== 4. Testing Central Experiment Tracking (MLflow :5000) ===")
      import mlflow
      mlflow_base = os.environ["MLFLOW_TRACKING_URI"]
      mlflow.set_tracking_uri(mlflow_base)
      mlflow.set_experiment("default")
      with mlflow.start_run(run_name="smoke-student-run") as run:
          run_id = run.info.run_id
          print(f"  [PASS] Registered MLflow run ID: {run_id}")
          mlflow.log_param("student_user", "user1")
          for step, loss_val in enumerate([0.5, 0.3, 0.1]):
              mlflow.log_metric("loss", loss_val, step=step)
          print("  [PASS] Logged 3 loss metric steps to MLflow backend.")
          
          summary_path = "/tmp/summary.txt"
          with open(summary_path, "w") as f:
              f.write("AI Sandbox: WP3-1-17 Student Golden Path Verification Artifact")
          mlflow.log_artifact(summary_path)
          print("  [PASS] Uploaded artifact summary.txt to MLflow proxied storage.")

      # Verify Artifact via MLflow REST API
      list_url = f"{mlflow_base}/api/2.0/mlflow/artifacts/list?run_id={run_id}"
      with urllib.request.urlopen(list_url, timeout=10) as r:
          artifacts = json.loads(r.read().decode("utf-8"))
          files = [item["path"] for item in artifacts.get("files", [])]
          assert "summary.txt" in files, f"summary.txt not found in artifacts: {files}"
          print(f"  [PASS] Verified artifact summary.txt listed in MLflow run: {files}")

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
# Step 1.5: Verify Multi-User Team Collaboration Permissions (mode 2770)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 1.5: Verifying Team Collaboration Permissions (user2 allowed, user3 blocked)${NC}"

# user2 (member of project1, GID 2001) appends to collab file
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- su -s /bin/bash user2 -c "
    echo 'user2 collaborator edit ok' >> ${COLLAB_TXT}
"
echo -e "  ${GREEN}✅ [PASS] Teammate user2 successfully appended to project1 collaborative file.${NC}"

# user3 (member of project2, GID 2002) is blocked
if kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- su -s /bin/bash user3 -c "
    cat ${COLLAB_TXT}
" 2>/dev/null; then
    echo -e "${RED}❌ [FAIL] Unauthorized user3 was able to read project1 collaborative file!${NC}"
    exit 1
else
    echo -e "  ${GREEN}✅ [PASS] Unauthorized user3 was correctly blocked from project1 (Permission denied).${NC}"
fi

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

# ------------------------------------------------------------------------------
# Step 2.5: Verify Concurrent GPU Time-Slicing Fault Isolation (Trap 1 Remediation)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 2.5: Verifying Concurrent GPU Time-Slicing & Fault Isolation${NC}"
echo "  Deploying two concurrent pods (nvidia.com/gpu: 1 each) on L40..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${GPU_POD_A}
  namespace: default
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  tolerations:
  - key: "slinky.slurm.net/managed-node"
    operator: "Exists"
    effect: "NoExecute"
  containers:
  - name: gpu-probe-a
    image: vllm/vllm-openai:v0.31.0
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        nvidia.com/gpu: "1"
    command:
    - python3
    - -c
    - |
      import ctypes, time
      cuda = ctypes.CDLL("libcuda.so.1")
      cuda.cuInit(0)
      dev = ctypes.c_int()
      cuda.cuDeviceGet(ctypes.byref(dev), 0)
      ctx = ctypes.c_void_p()
      cuda.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev)
      dptr = ctypes.c_size_t()
      cuda.cuMemAlloc_v2(ctypes.byref(dptr), 1 * (1024**3))
      print("POD_A_READY", flush=True)
      time.sleep(30)
---
apiVersion: v1
kind: Pod
metadata:
  name: ${GPU_POD_B}
  namespace: default
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  tolerations:
  - key: "slinky.slurm.net/managed-node"
    operator: "Exists"
    effect: "NoExecute"
  containers:
  - name: gpu-probe-b
    image: vllm/vllm-openai:v0.31.0
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        nvidia.com/gpu: "1"
    command:
    - python3
    - -c
    - |
      import ctypes, time
      cuda = ctypes.CDLL("libcuda.so.1")
      cuda.cuInit(0)
      dev = ctypes.c_int()
      cuda.cuDeviceGet(ctypes.byref(dev), 0)
      ctx = ctypes.c_void_p()
      cuda.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev)
      dptr = ctypes.c_size_t()
      cuda.cuMemAlloc_v2(ctypes.byref(dptr), 1 * (1024**3))
      print("POD_B_ACTIVE_ALLOC_OK", flush=True)
      # Wait for Pod A to be force-killed, then verify context is intact
      time.sleep(8)
      free, total = ctypes.c_size_t(), ctypes.c_size_t()
      assert cuda.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total)) == 0
      print(f"POD_B_SURVIVED_PEER_CRASH! Free: {free.value / (1024**3):.2f} GiB", flush=True)
      cuda.cuCtxDestroy_v2(ctx)
EOF

echo "  Waiting for Pod A and Pod B to initialize CUDA contexts..."
kubectl wait --for=condition=Ready pod/"${GPU_POD_A}" -n default --timeout=60s
kubectl wait --for=condition=Ready pod/"${GPU_POD_B}" -n default --timeout=60s

# Confirm Pod A has initialized
sleep 3
echo "  Force-killing Pod A (SIGKILL) mid-execution..."
kubectl delete pod "${GPU_POD_A}" -n default --grace-period=0 --force >/dev/null 2>&1

echo "  Waiting for Pod B to complete isolation check..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"${GPU_POD_B}" -n default --timeout=60s
POD_B_LOG=$(kubectl logs "${GPU_POD_B}" -n default)
echo "  ${POD_B_LOG}"

if echo "${POD_B_LOG}" | grep -q "POD_B_SURVIVED_PEER_CRASH"; then
    echo -e "  ${GREEN}✅ [PASS] Independent hardware CUDA contexts verified! Killing Pod A did NOT crash Pod B.${NC}"
else
    echo -e "${RED}❌ [FAIL] Pod B failed or experienced context corruption.${NC}"
    exit 1
fi
kubectl delete pod "${GPU_POD_B}" -n default --grace-period=0 --force >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Step 3: Execute Slurm Batch GPU Job as user1 (Apptainer + L40 Access)
# ------------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}▶ Step 3: Activating 'batch-gpu' Partition & Submitting Slurm Batch Job${NC}"

kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
    scontrol update PartitionName=batch-gpu State=UP
PARTITION_ACTIVATED=true
echo -e "  ${GREEN}✅ batch-gpu partition is now active.${NC}"

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
echo -e "${GREEN}${BOLD}🏆 WP3-1-17 Golden Path & De-Utopia Hardening: ALL GATES PASSED!${NC}"
echo -e "${CYAN}${BOLD}========================================================================${NC}"
echo -e "  ${GREEN}✅ A1 (Storage Permissions):${NC} Read /mnt/storage/datasets, wrote smoke_output.json as UID 1001"
echo -e "  ${GREEN}✅ A2 (Inference ForwardAuth):${NC} Authenticated via Traefik :443 with HMAC Bearer, generated tokens"
echo -e "  ${GREEN}✅ A3 (MLflow Tracking):${NC} Registered run, logged 3 metric loss steps, verified artifact list"
echo -e "  ${GREEN}✅ A4 (Slurm Batch GPU):${NC} Dispatched sbatch with --gres=gpu:1, bound L40 GPU via Apptainer"
echo -e "  ${GREEN}✅ A5 (Clean Teardown):${NC} Ephemeral pods cleaned, batch-gpu set INACTIVE, vLLM restored"
echo -e "  ${GREEN}✅ A6 (Scoped subPath Isolation):${NC} Verified /mnt/storage/mlflow invisible, EROFS on datasets"
echo -e "  ${GREEN}✅ A7 (Root-Squash & Collaboration):${NC} Booted UID 1001 / GID 2001, mode 2770 team access verified"
echo -e "  ${GREEN}✅ A8 (GPU Fault Isolation):${NC} 2 concurrent GPU time-sliced pods; killing Pod A spared Pod B"
echo ""
