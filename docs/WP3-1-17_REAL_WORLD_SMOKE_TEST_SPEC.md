# Spec: Real-World Student Workflow Validation (Smoke Test)

**Work Package:** WP3-1-17 (Integration Testing & Validation)  
**Status:** 🟢 Audited & Approved for Execution  
**Target Environment:** Proxmox K3s Cluster (`ai-control`, `ai-worker1`, `ai-sandbox-gpu-vm`)  
**Hardware Profile:** 1x NVIDIA L40 (48GB VRAM), Resource-Constrained CPU/RAM Nodes  
**Authors:** Khem & Antigravity (Senior Systems Architect & Co-Architect)  
**Auditor Reconciled:** Principal Platform Architect (Audit Pass: 2026-11-01)

---

### Decision
Execute a sequential, end-to-end "Golden Path" smoke test simulating a single non-root student (`user1`, UID 1001) performing a realistic machine learning workflow across storage, interactive inference, experiment tracking, and batch GPU compute. To eliminate GPU VRAM deadlock on our single physical L40 GPU, inference and batch training will execute sequentially using an automated lifecycle state machine with guaranteed teardown/recovery traps.

---

### Scope
* **In Scope:**
  * **Role 1: Test Harness Orchestrator (Admin Context on Host):**
    * Manages cluster lifecycle state transitions (vLLM scaling, Slurm partition activation, pod provisioning, and emergency rollback traps).
  * **Role 2: Student Workload Probe (Tenant Context in `workload` Namespace, UID 1001):**
    1. Read sample dataset from `/mnt/storage/datasets/` and write user output to allocated project storage at `/mnt/storage/projects/project1/smoke_output.json`.
    2. Execute authenticated OpenAI chat completion against Traefik Ingress (`https://ai-control:443/v1/chat/completions`) using an HMAC-SHA256 Bearer token, passing through ForwardAuth and rate-limiting.
    3. Log experiment parameters, 3 loss metric steps, and an artifact file (`summary.txt`) to MLflow at `http://mlflow.services.svc.cluster.local:5000`.
  * **Role 3: Slurm Batch GPU Worker (`ai-sandbox-gpu-vm`):**
    * Execute a Slurm batch job (`#SBATCH --partition=batch-gpu --gres=gpu:1`) running `apptainer exec --nv` to verify CUDA driver binding and L40 hardware visibility under UID 1001.
  * Self-contained orchestrator runner script: `scripts/test-student-golden-path.sh`.
* **Explicitly Out of Scope:**
  * Stress testing, load testing, or multi-user QoS concurrency benchmarking.
  * Central Vector Database (Qdrant) deployment (deferred until core pipeline passes).
  * Remote telemetry scraping agents or Prometheus edge exporters (WP3-1-13).

---

### Tier 1 — Mental Model: Physical Data & Lifecycle Path

The smoke test validates whether bits physically flow across Linux kernel boundaries, network sockets, and hardware accelerators as a non-privileged student:

```
[ Phase 1: Student Interactive Session (workload namespace, UID 1001) ]
  ├── 1. Storage VFS: Read /mnt/storage/datasets/ -> Write /mnt/storage/projects/project1/
  ├── 2. Inference: TCP 443 -> Traefik Ingress -> ForwardAuth (:8080) -> vLLM (:8000 on L40)
  └── 3. Tracking: TCP 5000 -> MLflow WSGI -> PostgreSQL 16 (:5432) & /mnt/storage/mlflow/artifacts

[ Phase 2: Sequential GPU Transition State Machine (Admin Harness) ]
  ├── 1. Scale down vLLM: kubectl scale deploy/vllm -n services --replicas=0
  ├── 2. Wait for pod termination & flush /dev/nvidia* CUDA memory contexts (sleep 5)
  └── 3. Activate partition: scontrol update PartitionName=batch-gpu State=UP

[ Phase 3: Slurm Batch GPU Execution (ai-sandbox-gpu-vm) ]
  ├── sbatch --partition=batch-gpu --gres=gpu:1
  └── Apptainer exec --nv -> verifies L40 device access (nvidia-smi / CUDA runtime)

[ Phase 4: Cluster Recovery & Restoration (Guaranteed via bash trap) ]
  ├── 1. Deactivate partition: scontrol update PartitionName=batch-gpu State=INACTIVE
  ├── 2. Restore vLLM: kubectl scale deploy/vllm -n services --replicas=1
  └── 3. Wait for vLLM Readiness probe (timeout: 300s)
```

---

### Files to Create

| File | Purpose |
| :--- | :--- |
| `scripts/test-student-golden-path.sh` | Self-contained, automated test orchestrator with built-in payload heredocs, lifecycle state machine, and unconditional recovery traps. |
| `k8s/network-policies/allow-workload-traefik-egress.yaml` | CNI NetworkPolicy permitting `workload` interactive pods to reach Traefik on port 443 in `slurm` namespace for authenticated inference. |

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
| `portal/*` | Web portal backend code; test targets existing ForwardAuth and API endpoints directly. |
| `k8s/vllm-deployment.yaml` | Model configurations are verified; scaled temporarily via `kubectl scale` without editing source manifests. |

---

### Acceptance Criteria

Every criterion must be **objectively pass/fail**:

- [ ] **A1 (Storage Permissions):** Test probe executing as UID 1001 reads `/mnt/storage/datasets/` and creates `/mnt/storage/projects/project1/smoke_output.json` with exit code `0`.
- [ ] **A2 (Inference ForwardAuth & Completion):** Test probe successfully calls `https://ai-control:443/v1/chat/completions` with valid HMAC Bearer token, passes ForwardAuth, and receives valid token generation response.
- [ ] **A3 (MLflow Tracking & Artifact List):** MLflow run registers with `status: FINISHED`, 3 logged metric steps for `loss`, and artifact `summary.txt` verifiable via `GET http://mlflow.services.svc.cluster.local:5000/api/2.0/mlflow/artifacts/list?run_id=<RUN_ID>`.
- [ ] **A4 (Slurm Batch GPU Execution):** Slurm batch job submitted via `sbatch` completes with Slurm state `COMPLETED` (exit code `0:0`), with job output proving `CUDA/NVIDIA driver binding` on the physical L40 GPU.
- [ ] **A5 (Clean Teardown & Cluster Restoration):** Ephemeral probe pod deleted, Slurm `batch-gpu` returned to `State=INACTIVE`, and vLLM restored to `1/1 Ready` on `ai-sandbox-gpu-vm`.
- [ ] **A6 (No Manifest Degradation):** No changes made to files in "Files NOT to Touch".
- [ ] **A7 (Log Entry):** `docs/INCREMENT_LOG.md` updated with empirical test output and execution timestamps.

---

### Design Rationale: Architectural Hardening from Audit

1. **Elimination of ClusterIP Backdoor:** Accessing vLLM via ClusterIP on port 8000 bypasses Increment 35 ForwardAuth. Golden Path testing must traverse Traefik Ingress (:443) using student Bearer auth, enforced by `allow-workload-traefik-egress.yaml`.
2. **Correct POSIX Path:** Testing against `/mnt/storage/projects/project1` matches existing directory ownership (`1001:1001, chmod 700`), avoiding `EACCES` permission traps on `/mnt/storage/projects/user1`.
3. **Single L40 GPU Lifecycle State Machine:** Dynamic scaling of vLLM guarantees zero VRAM thrashing with batch jobs, while bash `EXIT` traps ensure vLLM is restored even if the batch test fails.
4. **Self-Cleaning Harness:** All test payloads are embedded into `scripts/test-student-golden-path.sh` as heredocs, preventing repository bloat in `templates/`.
