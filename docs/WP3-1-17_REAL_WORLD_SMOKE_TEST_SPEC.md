# Spec: Real-World Student Workflow Validation (Smoke Test)

**Work Package:** WP3-1-17 (Integration Testing & Validation)  
**Status:** 🟡 Staged for Execution (Scheduled for Tomorrow)  
**Target Environment:** Proxmox K3s Cluster (`ai-control`, `ai-worker1`, `ai-sandbox-gpu-vm`)  
**Hardware Profile:** 1x NVIDIA L40 (48GB VRAM), Resource-Constrained CPU/RAM Nodes  
**Authors:** Khem & Antigravity (Senior Systems Architect & Co-Architect)  

---

### Decision
Execute a sequential, end-to-end "Golden Path" smoke test simulating a single non-root student (`user1`, UID 1001) performing a realistic machine learning workflow across storage, interactive inference, experiment tracking, and batch GPU compute. To eliminate GPU VRAM deadlock on our single physical L40 GPU, inference and batch training will execute sequentially rather than concurrently.

---

### Scope
* **In Scope:**
  * Functional verification of the full student data path:
    1. Read dataset from `/mnt/storage/datasets/` and write user output to `/mnt/storage/projects/user1/` under UID 1001.
    2. Prompt completion request from inside a student container to central `vLLM` on `ai-sandbox-gpu-vm` over TCP port 8000.
    3. Experiment tracking run logging loss metrics and saving an artifact to central `MLflow` on `ai-worker1` over TCP port 5000.
    4. Minimal Slurm batch job dispatch (`sbatch`) requesting the physical L40 GPU via Apptainer/PyTorch to verify CUDA kernel execution (`torch.cuda.is_available() == True`).
  * Automated orchestrator runner script: `scripts/test-student-golden-path.sh`.
* **Explicitly Out of Scope:**
  * Stress testing, load testing, or high-throughput concurrency benchmarking.
  * Multi-user QoS preemption or edge-case failure injections.
  * Central Vector Database (Qdrant) deployment (deferred until core pipeline passes).
  * Central Portal telemetry exporters or remote scraping agents (WP3-1-13).

---

### Tier 1 — Mental Model: Physical Data & Execution Path

The smoke test validates whether bits physically flow across Linux kernel boundaries, network sockets, and hardware accelerators as a non-privileged student:

```
[ Step 1: Storage & POSIX UID ]
Student Process (UID 1001) ──(read)──► /mnt/storage/datasets/sample.csv (Kernel VFS check)
Student Process (UID 1001) ──(write)──► /mnt/storage/projects/user1/results.json (Writable check)

[ Step 2: Central Inference (vLLM on L40) ]
Student Container ──(TCP Socket :8000 / Traefik Ingress)──► vLLM Engine
   ├── Sends JSON prompt payload with student Bearer token
   └── Receives streamed token buffers from Qwen model on L40 GPU

[ Step 3: Experiment Tracking (MLflow on worker1) ]
Student Container ──(TCP Socket :5000)──► MLflow WSGI Server
   ├── Commits hyperparameter & loss rows into PostgreSQL 16
   └── Streams model artifact binary into /mnt/storage/mlflow/artifacts

[ Step 4: Batch GPU Execution (Slurm + Apptainer) ]
Student Session ──(sbatch)──► slurmctld ──(Dispatch)──► slurmd on ai-sandbox-gpu-vm
   ├── Launches Apptainer container with NVIDIA runtime
   └── Executes PyTorch: torch.cuda.is_available() & 1000x1000 matrix multiplication
```

---

### Files to Create

| File | Purpose |
| :--- | :--- |
| `scripts/test-student-golden-path.sh` | Automated bash runner orchestrating the 4-step student test on the cluster. |
| `templates/smoke_test_student_workload.py` | Python script executed inside the student container (handles storage read/write, vLLM API call, and MLflow logging). |
| `templates/smoke_test_gpu_batch.slurm` | Minimal Slurm batch script submitted via `sbatch` allocating 1 GPU and executing PyTorch CUDA check inside Apptainer. |

---

### Files to Modify

| File | Changes |
| :--- | :--- |
| `docs/WORK_PACKAGES.md` | Update WP3-1-17 status and document the Real-World Golden Path test milestone. |
| `docs/INCREMENT_LOG.md` | Append entry recording the transition from architecture design to functional validation. |

---

### Files NOT to Touch

| File | Reason |
| :--- | :--- |
| `k8s/values.yaml` | Production Slurm Helm configuration; must remain untouched during functional testing. |
| `k8s/kind-config.yaml` | Local prototype configuration (archived baseline). |
| `portal/*` | Web portal backend code; test targets backend services directly first. |
| `k8s/vllm-deployment.yaml` | Model configurations are verified; scaled temporarily via `kubectl scale` without editing source manifests. |

---

### Acceptance Criteria

Every criterion must be **objectively pass/fail**:

- [ ] **A1 (Storage Permissions):** `smoke_test_student_workload.py` running as UID 1001 reads `/mnt/storage/datasets/` and creates `/mnt/storage/projects/user1/smoke_output.json` with exit code `0`.
- [ ] **A2 (Inference Token Generation):** `smoke_test_student_workload.py` receives a valid JSON completion response containing generated text from `http://vllm-service.services.svc.cluster.local:8000` (or Ingress) using the configured model.
- [ ] **A3 (MLflow Tracking & Artifacts):** MLflow run registers with `status: FINISHED`, 3 logged metric steps for `loss`, and artifact `summary.txt` verifiable via `GET http://mlflow.services.svc.cluster.local:5000/api/2.0/mlflow/runs/get`.
- [ ] **A4 (Slurm Batch GPU Execution):** `smoke_test_gpu_batch.slurm` submitted via `sbatch` completes with Slurm state `COMPLETED` (exit code `0:0`), with job output proving `CUDA available: True` and printing the L40 GPU device name.
- [ ] **A5 (No Manifest Degradation):** No persistent edits made to files in "Files NOT to Touch".
- [ ] **A6 (Log Entry):** `docs/INCREMENT_LOG.md` updated with empirical test output and execution timestamps.

---

### Design Rationale: Managing Hardware Realities

1. **Why Ignore the Low-Spec CPU:**
   The Linux CFS scheduler and glibc runtime function identically whether a machine possesses 4 cores or 64 cores. CPU bottlenecks affect latency and concurrent throughput, not functional instruction execution.
2. **Why Sequential GPU Allocation:**
   The cluster currently possesses exactly **one physical NVIDIA L40 (48GB)**. vLLM by default claims 90% of VRAM (43.2 GB) for static model weights and KV-cache pools. Attempting to run a concurrent student PyTorch batch job will trigger an unrecoverable CUDA Out-Of-Memory panic. 
   Running Stage 2 (Inference API) and then safely scaling vLLM down to run Stage 4 (Batch GPU Slurm job) provides 100% test fidelity without destabilizing the node.

---

### Open Questions
* **Open Question 1:** For Stage 4 batch execution, does the student's Apptainer `.sif` image already exist on `/mnt/storage/` (e.g. `images/pytorch.sif`), or will the batch job execute PyTorch using the cached containerd OCI runtime on `ai-sandbox-gpu-vm`? *(To be resolved at start of testing tomorrow).*
