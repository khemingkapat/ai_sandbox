# Spec: Real-World Student Workflow & "De-Utopia" Production-Fidelity Validation

**Work Package:** WP3-1-17 (Integration Testing & Production-Fidelity Hardening)  
**Status:** 🟢 Audited & Reconciled (Part A Verified | Part B Ready for Approval)  
**Target Environment:** Proxmox K3s Cluster (`ai-control`, `ai-worker1`, `ai-sandbox-gpu-vm`)  
**Hardware Profile:** 1x NVIDIA L40 (48GB VRAM), Resource-Constrained CPU/RAM Nodes  
**Authors:** Khem & Antigravity (Senior Systems Architect & Co-Architect)  
**Auditor Reconciled:** Principal Platform Architect (Audit Pass 2: 2026-11-02)

---

### Decision
Validate and harden the end-to-end student workflow in two parts:
1. **Part A (Golden Path Functional Pipe — Verified):** Prove a non-root student (`user1`, UID 1001) can read datasets, write project files, call central `vLLM` through Traefik ForwardAuth (:443), log metrics/artifacts to `MLflow` (:5000), and dispatch a sequential Slurm batch GPU job on the single NVIDIA L40.
2. **Part B ("De-Utopia" Scaling & Boundary Hardening — Audited):** Eliminate the three textbook-vs-reality gaps found during inspection of the codebase and cluster:
   * **Gap 1 (Monolithic `/mnt/storage` Mount Leak):** Replace the root `/mnt/storage` PVC mount in `portal/session_manager.go` with 5 scoped Kubernetes `subPath` mounts (`projects/<project>` RW, `scratch` RW sticky `1777`, `datasets` RO, `models` RO, `common/etc` -> `/var/lib/extrausers` RO) so student pods never have `/mnt/storage/mlflow` or unauthorized project directories in their VFS namespace.
   * **Gap 2 (Enterprise NFS `root_squash` & Multi-User Group Collaboration):** Parse student `UID`, primary `GID`, and supplemental project `GID`s (`2001`, `2002`, `2003`) from `/mnt/storage/common/etc/{passwd,group}` in `portal/session_manager.go` and inject an explicit `PodSecurityContext` (`RunAsUser`, `RunAsGroup`, `SupplementalGroups`, `FSGroup`). Configure shared project directories (`/mnt/storage/projects/project1..3`) with setgid mode `2770` so multi-user project teams (`user1` + `user2` in `project1`) can collaborate without relying on root container entrypoints that fail under NFS `root_squash`.
   * **Gap 3 (Time-Sliced GPU Fault Isolation vs. MPS Fate-Sharing):** Reject NVIDIA MPS (`nvidia-cuda-mps-control`) for multi-tenant student workloads due to shared-context fate-sharing crashes (one student segfault or `SIGKILL` destroys the MPS server for all users). Instead, verify Kubernetes GPU Time-Slicing (`nvidia.com/gpu` `replicas: 2`) where two concurrent student containers create independent hardware CUDA contexts on the L40 and survive a peer container crash (`kill -9`) without fault propagation, and update `docs/SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` to accurately document time-slicing vs. temporal batch queueing.

---

### Scope
* **In Scope:**
  * **Part A:** Core Golden Path 4-stage student workflow (`scripts/test-student-golden-path.sh`) and zero-trust Traefik egress (`k8s/network-policies/allow-workload-traefik-egress.yaml`).
  * **Part B:**
    * Scoped `subPath` volume mounts and dynamic `UID`/`GID`/`SupplementalGroups` `PodSecurityContext` in `portal/session_manager.go`.
    * Unit test `portal/session_manager_test.go` using `client-go/kubernetes/fake` to verify generated Pod specs.
    * Setgid group collaboration permissions (`chmod 2770`, group `2001..2003`) on `/mnt/storage/projects/project1..3` in `scripts/init-storage.sh` and on the live cluster.
    * Empirical test in `scripts/test-student-golden-path.sh` verifying: (1) VFS `subPath` isolation & `EROFS` read-only enforcement, (2) non-root UID 1001 / GID 2001 group collaboration & `/var/lib/extrausers` lookup, and (3) concurrent time-sliced GPU fault isolation (killing Container A mid-CUDA-context does not crash Container B).
* **Explicitly Out of Scope:**
  * **NVIDIA MPS Daemon (`nvidia-cuda-mps-control`):** Explicitly rejected due to multi-tenant fate-sharing blast radius.
  * **Fine-Tuning Stack (`pytorch.sif` / QLoRA — WP3-1-14):** Deferred to WP3-1-14 Starter Labs & Training Image work package.
  * **Central Vector Database (Qdrant — WP3-1-14) & Telemetry (WP3-1-13):** Deferred to their respective work packages.

---

### Tier 1 — Mental Model: Physical Data & Isolation Path

```
[ 1. Student Interactive Pod (namespace: workload, SecurityContext: UID 1001, GID 2001) ]
  ├── VFS Mounts (Scoped via K8s subPath — NO root /mnt/storage access):
  │     ├── /mnt/storage/projects/project1 (subPath: projects/project1, RW, mode 2770, group 2001)
  │     ├── /mnt/storage/scratch           (subPath: scratch,           RW, mode 1777 sticky bit)
  │     ├── /mnt/storage/datasets          (subPath: datasets,          RO — Kernel EROFS on write)
  │     ├── /mnt/storage/models            (subPath: models,            RO — Kernel EROFS on write)
  │     └── /var/lib/extrausers            (subPath: common/etc,        RO — resolves UID 1001 -> user1)
  │     [Unmounted / Invisible in VFS: /mnt/storage/mlflow, /mnt/storage/projects/project2]
  │
  ├── Network Egress (Zero-Trust CNI):
  │     ├── TCP 443 ──► Traefik Ingress ──► ForwardAuth (:8080) ──► vLLM (:8000 on L40)
  │     └── TCP 5000 ──► MLflow WSGI ──► PostgreSQL 16 (:5432) & Proxied Artifacts
  │
[ 2. GPU Time-Slicing & Fault Isolation Boundary (ai-sandbox-gpu-vm — NVIDIA L40) ]
  ├── K8s Device Plugin (replicas: 2) ──► Independent Hardware CUDA Contexts
  ├── Pod A (UID 1001) allocates 1 GiB + receives SIGKILL (-9) mid-execution
  └── Pod B (UID 1002) allocates 1 GiB concurrently ──► Survives with 0 (CUDA_SUCCESS)
```

---

### Files to Create

| File | Purpose |
| :--- | :--- |
| `k8s/network-policies/allow-workload-traefik-egress.yaml` | CNI NetworkPolicy permitting `workload` pods to reach Traefik on port 443 in `slurm` namespace (Created in Part A). |
| `scripts/test-student-golden-path.sh` | Automated end-to-end runner executing both Part A (Golden Path) and Part B ("De-Utopia" VFS isolation, group collaboration, and GPU fault isolation gates). |
| `portal/session_manager_test.go` | Go unit test suite using `client-go/kubernetes/fake` to verify scoped `subPath` mounts, `ReadOnly` flags, and `PodSecurityContext` UID/GID mapping. |

---

### Files to Modify

| File | Changes |
| :--- | :--- |
| `portal/session_manager.go` | 1. Replace monolithic `/mnt/storage` mount with 5 scoped `subPath` mounts (`projects/<project>` RW, `scratch` RW, `datasets` RO, `models` RO, `common/etc` -> `/var/lib/extrausers` RO).<br>2. Resolve student `UID`, primary `GID`, and supplemental project `GID`s from `/mnt/storage/common/etc/{passwd,group}` and set `PodSecurityContext`. |
| `scripts/init-storage.sh` | Update project directory ownership and permissions to `1001:2001`, `1002:2002`, `1004:2003` with setgid mode `2770` so group collaboration works out of the box. |
| `docs/SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md` | Reconcile §3.2 & §4.8 to accurately state that K8s GPU Time-Slicing provides hardware context fault isolation while Slurm `batch-gpu` enforces temporal GPU exclusivity. |
| `k8s/network-policies/allow-vllm-egress.yaml` | **Delete** legacy policy that allowed unauthenticated port 8000 ClusterIP access to vLLM (Deleted in Part A). |
| `docs/WORK_PACKAGES.md` | Update WP3-1-17 with Part A & Part B validation gates. |
| `docs/INCREMENT_LOG.md` | Record architectural findings and empirical verification results. |

---

### Files NOT to Touch

| File | Reason |
| :--- | :--- |
| `k8s/values.yaml` | Production Slurm Helm configuration; must remain untouched. |
| `k8s/kind-config.yaml` | Archived local Kind configuration. |
| `k8s/vllm-deployment.yaml` | Central inference manifest; scaled dynamically during testing via `kubectl scale` only. |
| `images/jupyterlab/Dockerfile` | Base image rebuilds are out of scope; non-root `SecurityContext` bypasses the root branch in `start-jupyter.sh`. |

---

### Acceptance Criteria

Every criterion must be **objectively pass/fail**:

#### Part A: Core Golden Path (Verified ✅)
- [x] **A1 (Storage Read/Write):** Student probe (UID 1001) reads `/mnt/storage/datasets/nlp/imdb` and writes `/mnt/storage/projects/project1/smoke_output.json` with exit code `0`.
- [x] **A2 (Inference ForwardAuth):** Student probe calls `https://portal.slurm.svc.cluster.local:443/v1/chat/completions` with HMAC Bearer token, passes ForwardAuth, and receives generated tokens from vLLM.
- [x] **A3 (MLflow Tracking & Artifacts):** Student probe logs 3 `loss` metric steps and uploads `summary.txt`, verified via `GET /api/2.0/mlflow/artifacts/list?run_id=<RUN_ID>`.
- [x] **A4 (Slurm Batch GPU Execution):** `sbatch --partition=batch-gpu --gres=gpu:1` runs `apptainer exec --nv` and binds the physical `NVIDIA L40`.
- [x] **A5 (Clean Teardown & Recovery):** Ephemeral probe deleted, `batch-gpu` returned to `State=INACTIVE`, and `vllm` restored to `1/1 Ready`.

#### Part B: "De-Utopia" Production-Fidelity Hardening (To Execute)
- [ ] **A6 (Scoped `subPath` VFS Isolation & Read-Only Enforcement):**
  * Inside the student pod, `/mnt/storage/mlflow` and `/mnt/storage/projects/project2` do **not** exist (`FileNotFoundError`).
  * Attempting to write a file into `/mnt/storage/datasets/` or `/mnt/storage/models/` fails with kernel `EROFS (Read-only file system)`.
  * Writing temporary files to `/mnt/storage/scratch` (mode `1777`) succeeds as non-root UID 1001 without Kubelet `root:root 0755` `subPath` permission traps.
- [ ] **A7 (Root-Squash-Safe Non-Root Spawn, Group Collaboration & Portal Tests):**
  * Student pod boots directly as `UID 1001`, `GID 2001` (`project1`) via `PodSecurityContext`, and `pwd.getpwuid(1001).pw_name == "user1"` resolves via `/var/lib/extrausers` with zero MLflow UID warnings.
  * Files created in `/mnt/storage/projects/project1` inherit `GID 2001` (`chmod 2770`), allowing teammate `user2` (`UID 1002, GID 2001`) to read/write them while blocking non-member `user3` (`UID 1003, GID 2002`).
  * `cd portal && go test -v ./... && go vet ./...` exits `0`.
- [ ] **A8 (Concurrent GPU Time-Slicing & Fault Isolation):**
  * Two concurrent student pods (`nvidia.com/gpu: 1` each via K8s time-slicing `replicas: 2`) simultaneously initialize hardware CUDA contexts and allocate 1 GiB VRAM on the L40 (`cuMemAlloc_v2 == 0`).
  * Force-killing (`kill -9`) Pod A mid-allocation does **not** corrupt or terminate Pod B's CUDA context.
