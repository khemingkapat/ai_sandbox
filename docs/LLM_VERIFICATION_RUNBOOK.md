# AI Sandbox: LLM Inference & Model Catalog Verification Runbook

> **Target Audience:** System Architects, Reviewers, and Infrastructure Engineers  
> **Environment:** Proxmox K3s Cluster (`ai-sandbox-gpu-vm` @ L40 GPU, `slurm` namespace)  
> **Companion Documents:** [MODEL_CATALOG.md](file:///home/khemi/workspace/ai_sandbox/docs/MODEL_CATALOG.md) & [SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md](file:///home/khemi/workspace/ai_sandbox/docs/SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md)  
> **Automated Suite:** [`scripts/verify-llm.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/verify-llm.sh)

---

## 📖 How to Use This Runbook

This document provides **exact, copy-pasteable terminal commands** to manually inspect, benchmark, and verify each claim made for **Milestone 3 (WP3-1-9 & WP3-1-10)** regarding the central vLLM inference engine, Traefik API gateway protection, and the shared model catalog.

Execute these commands from:
1. Your **local workstation** with `kubectl` configured (`KUBECONFIG=~/.kube/config-proxmox` or via the SSH tunnel).
2. The control plane node (`ai-control` via Proxmox web console or SSH).

---

## 📋 Module 1: Physical Accelerator & GPU Virtualization Baseline

### 1.1 Verify Physical GPU Accelerator Health (NVML)
Queries the physical NVIDIA L40 accelerator directly from the Slurm GPU worker container using NVML.

```bash
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- \
  nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader
```

**Expected Output:**
```text
NVIDIA L40, 595.91.07, 46068 MiB, ~28660 MiB
```

---

### 1.2 Verify Kubernetes GPU Virtual Time-Slicing
Confirms that the Kubernetes node advertises 2 virtual GPU slices partitioned across the physical L40.

```bash
kubectl get node ai-sandbox-gpu-vm -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'
```

**Expected Output:**
```text
2
```

---

### 1.3 Verify GPU Memory Headroom for Slurm Batch Jobs
Calculates the remaining free VRAM available for student batch and fine-tuning jobs (ensures vLLM's `0.65` utilization does not starve Slurm).

```bash
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- \
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits
```

**Expected Output:**
* Value $\ge 12,000$ MiB (typically ~16,800 MiB free VRAM).

---

## 📋 Module 2: vLLM Runtime Engine Stabilization (WP3-1-9)

### 2.1 Verify vLLM Pod Status & Readiness
Checks that the inference engine is `1/1 Ready` and running on the dedicated GPU node.

```bash
kubectl get pods -n slurm -l app=vllm -o wide
```

**Expected Output:**
* Status: `Running`, Ready: `1/1`, Node: `ai-sandbox-gpu-vm`.

---

### 2.2 Verify Deterministic Image Pinning
Confirms that the production deployment locks a deterministic vLLM release tag rather than mutable `:latest`.

```bash
kubectl get deploy vllm -n slurm -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected Output:**
```text
vllm/vllm-openai:v0.31.0
```

---

### 2.3 Verify `Recreate` Strategy (GPU Deadlock Prevention)
Ensures Kubernetes terminates the old pod and releases GPU resources before scheduling a replacement.

```bash
kubectl get deploy vllm -n slurm -o jsonpath='{.spec.strategy.type}{"\n"}'
```

**Expected Output:**
```text
Recreate
```

---

### 2.4 Verify Read-Only Shared Model Storage Mount
Attempts to touch a file in the shared model cache inside the vLLM container to prove write-protection.

```bash
kubectl exec -n slurm deploy/vllm -- touch /root/.cache/huggingface/.security_test.tmp
```

**Expected Output:**
```text
touch: cannot touch '/root/.cache/huggingface/.security_test.tmp': Read-only file system
```

---

### 2.5 Verify Air-Gapped Offline Mode
Confirms `HF_HUB_OFFLINE=1` is injected into the container environment to block runtime external Hugging Face downloads.

```bash
kubectl get deploy vllm -n slurm -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HF_HUB_OFFLINE")].value}{"\n"}'
```

**Expected Output:**
```text
1
```

---

### 2.6 Verify Scoped Node Taint Toleration
Confirms the pod only tolerates the specific scheduler taint rather than possessing a cluster-wide `operator: Exists`.

```bash
kubectl get deploy vllm -n slurm -o jsonpath='{.spec.template.spec.tolerations}' | jq .
```

**Expected Output:**
```json
[
  {
    "effect": "NoExecute",
    "key": "slinky.slurm.net/managed-node",
    "operator": "Equal",
    "value": "slurm-bridge-scheduler"
  }
]
```

---

### 2.7 Verify Internal Cluster Service Query
Queries the cluster-internal service endpoint directly from the portal container.

```bash
kubectl exec -n slurm deploy/hpc-portal -c portal -- \
  curl -s http://vllm-service.slurm:8000/v1/models | jq .
```

**Expected Output:**
* JSON object listing `"id": "Qwen/Qwen2.5-32B-Instruct-AWQ"`.

---

## 📋 Module 3: Traefik Ingress & API Gateway Protection

### 3.1 Verify Traefik HTTPS Routing (443)
Validates TLS termination and routing to `/v1/models` via port 443.

```bash
kubectl exec -n slurm deploy/hpc-portal -c portal -- \
  curl -sk https://127.0.0.1:443/v1/models | jq -r '.data[0].id'
```

**Expected Output:**
```text
Qwen/Qwen2.5-32B-Instruct-AWQ
```

---

### 3.2 Verify Traefik HTTP Routing (80)
Validates plain HTTP routing to `/v1/models` via port 80.

```bash
kubectl exec -n slurm deploy/hpc-portal -c portal -- \
  curl -s http://127.0.0.1:80/v1/models | jq -r '.data[0].id'
```

**Expected Output:**
```text
Qwen/Qwen2.5-32B-Instruct-AWQ
```

---

### 3.3 Verify Traefik Middleware Configuration
Inspects the ConfigMap for active rate-limiting and in-flight request protection policies.

```bash
kubectl get configmap traefik-security-config -n slurm -o jsonpath='{.data.security\.yaml}'
```

**Expected Output:**
* Contains `vllm-ratelimit` (`average: 10, burst: 20, period: 1s`).
* Contains `vllm-inflight` (`amount: 15`).

---

### 3.4 Active Behavioral Rate-Limiting Burst Test
Fires 60 concurrent requests in parallel to confirm that excess traffic is throttled with `429 Too Many Requests`.

```bash
kubectl exec -n slurm deploy/hpc-portal -c portal -- sh -c '
for i in $(seq 1 60); do
    curl -sk -o /dev/null -w "%{http_code}\n" -m 5 https://127.0.0.1:443/v1/models &
done
wait
' | sort | uniq -c
```

**Expected Output:**
```text
23-26 200
34-37 429
```

---

## 📋 Module 4: Shared Storage & Model Catalog Architecture (WP3-1-10)

### 4.1 Verify NFS Storage Mount & Capacity
Checks the NFS mount on the GPU worker node.

```bash
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage
```

**Expected Output:**
* Mounted on `/mnt/storage` with $\ge 150$ GB free space.

---

### 4.2 Verify Model Directory POSIX Permissions
Confirms that the shared models directory is hardened against student tampering.

```bash
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- stat -c "%U:%G %a" /mnt/storage/models
```

**Expected Output:**
```text
root:root 755
```

---

### 4.3 Verify Model Catalog Parity
Validates that the currently served model matches the registered `central_serving: true` model in `docs/MODEL_CATALOG.json`.

```bash
python3 -c "
import json
with open('docs/MODEL_CATALOG.json') as f:
    d = json.load(f)
served = [m['id'] for m in d['models'] if m.get('central_serving')]
print('Served model in catalog:', served)
assert len(served) == 1 and served[0] == 'Qwen/Qwen2.5-32B-Instruct-AWQ'
print('Catalog Parity: OK')
"
```

**Expected Output:**
```text
Served model in catalog: ['Qwen/Qwen2.5-32B-Instruct-AWQ']
Catalog Parity: OK
```

---

### 4.4 Verify Model Ingestion CLI Mock Isolation
Runs `ingest-model.sh` in `--test-mode` against an ephemeral directory to confirm proper caching layout (`models--<org>--<name>`) and catalog safety.

```bash
TMP_TEST=$(mktemp -d /tmp/manual_runbook_test_XXXXXX)
bash scripts/ingest-model.sh --test-mode --model test/probe-model --storage-root "$TMP_TEST"
ls -la "$TMP_TEST/models/huggingface/hub"
rm -rf "$TMP_TEST"
```

**Expected Output:**
* Directory `models--test--probe-model` created.
* Production catalog (`docs/MODEL_CATALOG.json`) remains completely untouched.

---

### 4.5 Verify Offline Tokenizer Load
Confirms that downloaded catalog weights can be loaded completely offline without Hugging Face network access.

```bash
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- python3 -c "
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained('Qwen/Qwen3.5-0.8B', cache_dir='/mnt/storage/models/huggingface/hub', local_files_only=True)
print('Loaded offline! Vocab size:', tok.vocab_size)
"
```

**Expected Output:**
```text
Loaded offline! Vocab size: 248044
```

---

## 📋 Module 5: Live Inference, Latency & Boundary Checks

### 5.1 Execute Live Chat Completion Benchmark
Sends an end-to-end chat completion request through Traefik and measures roundtrip latency.

```bash
kubectl exec -n slurm deploy/hpc-portal -c portal -- \
  curl -sk -X POST https://127.0.0.1:443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "Reply with exactly three words: AI Sandbox Live"}],
    "max_tokens": 10
  }' | jq .
```

**Expected Output:**
* Returns HTTP 200 with content: `"AI Sandbox Live"`.
* Typical roundtrip latency: 500ms – 900ms.

---

### 5.2 Context Window Boundary Overflow Check
Sends an oversized prompt (>18,000 tokens) exceeding `--max-model-len 16384` to verify clean rejection without engine crash.

```bash
python3 -c '
import json
print(json.dumps({
    "model": "Qwen/Qwen2.5-32B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "test " * 18000}],
    "max_tokens": 10
}))
' | kubectl exec -i -n slurm deploy/hpc-portal -c portal -- \
  curl -sk -X POST https://127.0.0.1:443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @- -o /dev/null -w "%{http_code}\n"
```

**Expected Output:**
```text
400
```

---

## 📋 Module 6: In-Place Crash Recovery Benchmark (Optional / Destructive)

### 6.1 Process Crash Simulation & Fast In-Place Recovery
Simulates an unexpected engine crash (`kill -9 1`) and observes kubelet in-place container recreation without losing GPU device allocation.

```bash
POD_NAME=$(kubectl get pod -n slurm -l app=vllm -o jsonpath='{.items[0].metadata.name}')

# 1. Kill container process
kubectl exec -n slurm "$POD_NAME" -- kill -9 1

# 2. Watch recovery in real time
kubectl get pods -n slurm -l app=vllm -w
```

**Expected Behavior:**
* Pod name does **not** change (no rescheduling across nodes).
* GPU device allocation remains intact.
* Container restarts and returns to `1/1 Ready` in ~2 to 10 seconds.

---

## 🎯 Verification Sign-Off Checklist

| Component | Test Method | Status | Verified By |
| :--- | :--- | :--- | :--- |
| **Physical L40 GPU (NVML)** | `nvidia-smi` in slurmd-gpu-0 | 🟢 Verified | Automated + Manual |
| **GPU Time-Slicing (`capacity: 2`)** | `kubectl get node ai-sandbox-gpu-vm` | 🟢 Verified | Automated + Manual |
| **Free VRAM Headroom ($\ge 12$ GiB)**| `nvidia-smi --query-gpu=memory.free` | 🟢 Verified | Automated + Manual |
| **vLLM Pod Health (1/1 Ready)** | `kubectl get pods -l app=vllm` | 🟢 Verified | Automated + Manual |
| **Image Tag Pinning (`v0.31.0`)** | `spec.containers[0].image` | 🟢 Verified | Automated + Manual |
| **Strategy: Recreate** | `spec.strategy.type` | 🟢 Verified | Automated + Manual |
| **Read-Only Model Mount** | `touch /root/.cache/huggingface/` | 🟢 Verified | Automated + Manual |
| **Offline Mode (`HF_HUB_OFFLINE=1`)**| `env[HF_HUB_OFFLINE]` | 🟢 Verified | Automated + Manual |
| **Node Taint Tolerations** | Scoped to `slurm-bridge-scheduler` | 🟢 Verified | Automated + Manual |
| **Internal Service Endpoint** | `curl vllm-service.slurm:8000/v1/models` | 🟢 Verified | Automated + Manual |
| **Traefik HTTPS Routing (443)** | `curl https://127.0.0.1:443/v1/models` | 🟢 Verified | Automated + Manual |
| **Traefik HTTP Routing (80)** | `curl http://127.0.0.1:80/v1/models` | 🟢 Verified | Automated + Manual |
| **API Middlewares (ConfigMap)** | `traefik-security-config` | 🟢 Verified | Automated + Manual |
| **Active 429 Throttling Burst** | 60-burst parallel requests | 🟢 Verified | Automated + Manual |
| **NFS Shared Mount on Worker** | `df -h /mnt/storage` | 🟢 Verified | Automated + Manual |
| **POSIX Hardening (`root:root 755`)**| `stat -c "%U:%G %a" /mnt/storage/models`| 🟢 Verified | Automated + Manual |
| **Model Catalog Parity** | `central_serving == Qwen2.5-32B` | 🟢 Verified | Automated + Manual |
| **Ingestion CLI Tool Executable** | `test -x scripts/ingest-model.sh` | 🟢 Verified | Automated + Manual |
| **Ingestion Mock Isolation** | `--test-mode` temp directory | 🟢 Verified | Automated + Manual |
| **Live Chat Completion via Traefik** | `curl POST /v1/chat/completions` | 🟢 Verified | Automated + Manual |
| **Context Window Overflow Rejection**| `HTTP 400` on 18k token prompt | 🟢 Verified | Automated + Manual |
| **In-Place Crash Recovery** | `kill -9 1` container restart in $\le 10$s | 🟢 Verified | Automated + Manual (`--destructive`) |
