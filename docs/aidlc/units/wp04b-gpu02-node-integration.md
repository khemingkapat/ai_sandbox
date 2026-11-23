# Unit: WP04-B — Secondary GPU Compute Node Integration (`ai-sandbox-gpu02`)

Status: tests-locked (Gate C)
Parent GitHub WP: #4 (Slinky Cluster Deployment) / #5 (Slurm Policy Configuration)
Exploratory? no

## Intent
Integrate the new GPU VM `ai-sandbox-gpu02` (`10.35.123.41`, NVIDIA GeForce RTX 3060 Ti 8 GB, 8 vCPU, 15 GiB RAM) into the Proxmox K3s + Slinky Slurm cluster as a dedicated compute GPU node (`slurmd-gpu`), permanently separating student/batch GPU workloads from the central LLM inference node (`ai-sandbox-gpu-vm`, L40 48 GB) and unblocking Slurm GPU execution while the L40 is offline for maintenance.

## Scope & Non-goals
- **In scope:**
  - OS & GPU bootstrap on `ai-sandbox-gpu02` (`10.35.123.41`): NVIDIA driver (compatible with Ubuntu 24.04 kernel `7.0.0-43-generic`), `nvidia-container-toolkit`, `nfs-common`, UFW rules, and `/mnt/storage` NFSv4 mount.
  - Perimeter updates on `ai-control` (`10.35.123.50`): UFW rules (`6443/tcp`, `10250/tcp`, `8472/udp`, `2049/tcp`) and NFSv4 `/etc/exports` entry for `10.35.123.41`.
  - K3s agent join (`v1.36.4+k3s1`) with explicit node labels (`accelerator=nvidia-gpu`, `gpu-model=rtx3060ti`, `gpu-role=compute`, `node-role.kubernetes.io/worker=worker`) and `nvidia` containerd runtime verification. *(Do NOT attach `scheduler.slinky.slurm.net/external-node=true` or static `NodeName=ai-sandbox-gpu02 Gres=gpu:1` in this unit to prevent Slurm from double-counting the single physical GPU alongside `slurmd-gpu-0`.)*
  - Per-node NVIDIA Device Plugin configuration (`k8s/nvidia-device-plugin.yaml`) using disjoint `gpu-model` selectors: L40 (`gpu-model=l40`) keeps existing config; RTX 3060 Ti (`gpu-model=rtx3060ti`) runs exclusive **`replicas: 1`** (zero time-slicing OOM risk on 8 GB VRAM).
  - Slinky Slurm GPU NodeSet migration (`k8s/values.yaml`): pin `slurmd-gpu` to `ai-sandbox-gpu02` (`gpu-model=rtx3060ti`) with explicit memory ceiling (~12 GiB) so Slurm jobs cannot OOM-kill `k3s-agent` on the 15 GiB VM; keep `inference` partition isolated on `ai-sandbox-gpu-vm`.
  - Side-load `slurmd-custom:latest` **only** (not `interactive-jupyter:latest`, saving root disk space) into `ai-sandbox-gpu02` K3s containerd (`scripts/transfer-images-proxmox.sh`).
  - Locked Gate C verification probe (`scripts/verify-gpu02.sh`) verifying node readiness, `nvidia.com/gpu: 1` capacity, `slurmd-gpu-0` Running on `ai-sandbox-gpu02`, live `sbatch --partition=batch-gpu --gres=gpu:1` job executing `nvidia-smi`, vLLM isolation check, and ephemeral SSH key revocation.
  - Documentation updates at Gate D (`docs/aidlc/PROJECT_CONTEXT.md`, `docs/aidlc/UNITS.md`, and `docs/aidlc/decisions/0008-heterogeneous-dual-gpu-node-separation.md`).
- **Non-goals:**
  - Moving central `vllm` (`k8s/vllm-deployment.yaml`) onto `ai-sandbox-gpu02` (vLLM stays strictly pinned to `ai-sandbox-gpu-vm`).
  - Modifying the Go Web Portal (`portal/`) to add interactive GPU pod selection UI (deferred to a follow-up unit).
  - Modifying `ai-sandbox-gpu-vm` (`.40`) hardware/drivers while it is in scheduled maintenance.
  - Pre-pulling the 15 GB+ NGC PyTorch image onto `ai-sandbox-gpu02`'s 79 GB root disk.

## Constraints and decisions to respect
- [ADR 0002](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md): `/mnt/storage` NFSv4 mount + `extrausers` UID/GID isolation must match `ai-worker1`.
- [ADR 0003](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md): Trigger for revisiting met — adding a second physical GPU node lets us decouple Slurm `batch-gpu` from L40 inference.
- [ADR 0004](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md): `services` namespace (`vllm`, `mlflow`, `qdrant`) remains isolated from compute workloads.
- **Hardware limits on `ai-sandbox-gpu02`:** RTX 3060 Ti has **8 GB VRAM** (Ampere CC `8.6`), **15 GiB RAM**, and **63 GB free disk**. No multi-replica time-slicing (`replicas: 1` only); no heavy model weights stored on local `/`.
- **Security / Bootstrap Hygiene:** Ephemeral SSH key (`ai-sandbox-temp-bootstrap-20261123`) must be removed from `~/.ssh/authorized_keys` on both `ai-control` and `ai-sandbox-gpu02` and deleted locally before Gate D closure.

## Implementation Plan (Bundled for Gate A+B)
- **Approach:**
  1. **Host & Perimeter Bootstrap (audited `sudo` blocks):** Install NVIDIA open kernel driver + `nvidia-container-toolkit` + `nfs-common` on `.41`, reboot and verify `nvidia-smi`; open UFW + `/etc/exports` on `.50`; mount `/mnt/storage` via `/etc/fstab` on `.41`.
  2. **K3s Agent Join & Disjoint Device Plugin:** Join `.41` to `https://10.35.123.50:6443` with explicit `gpu-model=rtx3060ti,gpu-role=compute` labels; update `k8s/nvidia-device-plugin.yaml` to run two disjoint DaemonSets (`gpu-model: l40` vs `gpu-model: rtx3060ti` with `replicas: 1`).
  3. **Image Side-Load & Slurm Migration:** Side-load `slurmd-custom:latest` onto `.41` containerd; update `k8s/values.yaml` to schedule `slurmd-gpu` on `ai-sandbox-gpu02` and update Helm release (`helm upgrade slurm ...`).
  4. **Verification & Key Revocation:** Run locked `scripts/verify-gpu02.sh` (live `sbatch --gres=gpu:1` GPU job + negative placement proofs), then revoke ephemeral SSH key from `.50` and `.41` and verify `Permission denied`.
- **Files Allowed to Touch:**
  - `docs/aidlc/units/wp04b-gpu02-node-integration.md` (this unit spec & bolt log)
  - `docs/aidlc/decisions/0008-heterogeneous-dual-gpu-node-separation.md` (new ADR for 2-GPU tier separation)
  - `docs/aidlc/PROJECT_CONTEXT.md` (update hardware topology at Gate D)
  - `docs/aidlc/UNITS.md` (register & update unit status)
  - `k8s/nvidia-device-plugin.yaml` (disjoint per-GPU-model DaemonSets: L40 vs RTX 3060 Ti `replicas: 1`)
  - `k8s/values.yaml` (pin `slurmd-gpu` NodeSet to `ai-sandbox-gpu02` + update Slurm partition/node config)
  - `scripts/transfer-images-proxmox.sh` (add `slurmd-custom:latest` side-load target for `ai-sandbox-gpu02`)
  - `scripts/verify-gpu02.sh` (locked Gate C empirical verification probe)
- **Risks / Edge cases:**
  - **Kernel `7.0.0-43-generic` DKMS compatibility:** Older proprietary NVIDIA drivers (e.g., 535) fail to compile on Linux 7.0; must use the Ubuntu 24.04 open kernel module package matching `ai-sandbox-gpu-vm` (`7.0.0-42-generic`).
  - **Containerd `nvidia` RuntimeClass registration:** K3s auto-detects `nvidia-container-runtime` at agent startup only if `nvidia-container-toolkit` is installed *before* `k3s-agent` starts (or `k3s-agent` is restarted after `nvidia-ctk runtime configure`).
  - **NFS stale/missing mount or export mismatch:** Must mirror the exact existing `/etc/exports` flags from `ai-control` for `10.35.123.41/32` (no subnet wildcard) and persist `/mnt/storage` in `/etc/fstab` with `_netdev,nfsvers=4` so `slurmd-gpu-0` UID/GID drops (`1001+`) write cleanly to student directories.
  - **15 GiB VM RAM OOM trap:** With `DefMemPerCPU=2048` in `slurm.conf`, an 8-core job requests 16 GiB RAM (> 15 GiB host RAM). Enforce a ~12 GiB memory ceiling on `slurmd-gpu` so Slurm jobs cannot starve `k3s-agent`.
  - **Stage 2 CI maintenance flag invariant:** Keep GitHub variable `CLUSTER_GPU_MAINTENANCE="true"` until `ai-sandbox-gpu-vm` (L40) returns; `ai-sandbox-gpu02` advertising `nvidia.com/gpu: 1` does NOT satisfy `verify-llm.sh` (which targets L40 `vllm`).
  - **Helm upgrade blast radius:** Upgrading the `slurm` Helm release must not disrupt running `slurm-worker-slurmd-cpu-[0-1]`, `mariadb-0`, or `hpc-portal`.

## Acceptance criteria
1. **Happy Path — Node & GPU Ready:** Given `ai-sandbox-gpu02` (`10.35.123.41`) has joined K3s, when querying `kubectl get node ai-sandbox-gpu02`, then status is `Ready`, labels include `accelerator=nvidia-gpu`, `gpu-model=rtx3060ti`, and `gpu-role=compute`, and `status.capacity['nvidia.com/gpu']` is strictly `"1"` (exclusive, not `4`).
2. **Happy Path — Slurm GPU Worker & Live Job:** Given `slurm-worker-slurmd-gpu-0` is `Running` (`2/2`) on `ai-sandbox-gpu02` with `/mnt/storage` mounted, when submitting a Slurm batch job (`sbatch --partition=batch-gpu --gres=gpu:1 --wrap="nvidia-smi --query-gpu=name,memory.total --format=csv,noheader"`), then the job completes with exit code `0` and its output in `/mnt/storage` reports `NVIDIA GeForce RTX 3060 Ti`.
3. **Failure / Boundary Rejection — vLLM Isolation:** Given `k8s/vllm-deployment.yaml` is deployed in `services` namespace while `ai-sandbox-gpu-vm` is offline, when inspecting `vllm` pod scheduling, then `vllm` MUST NOT schedule onto `ai-sandbox-gpu02` (remains pinned to `ai-sandbox-gpu-vm`).
4. **Failure / Boundary Rejection — Device Plugin Mutual Exclusion:** Given both `gpu-model=l40` and `gpu-model=rtx3060ti` DaemonSets exist in `kube-system`, when listing `nvidia-device-plugin` pods on `ai-sandbox-gpu02`, then exactly **1** device-plugin pod runs on `ai-sandbox-gpu02` (no duplicate plugin collision).
5. **Integration Contract — Cluster Invariants:** Given the `slurm` Helm upgrade and NFS export update complete, when checking existing cluster services, then `ai-control`, `ai-worker1`, `slurm-worker-slurmd-cpu-[0-1]`, `mariadb-0`, `hpc-portal`, and `qdrant` remain `Running`/`Ready` with zero regressions.
6. **Security Closure — Ephemeral SSH Key Revocation:** Given integration and verification are complete, when attempting `ssh -i ~/.ssh/tmp_ai_sandbox_bootstrap_ed25519` to both `10.35.123.50` and `10.35.123.41` (and checking local `~/.ssh/`), then both hosts reject access (`Permission denied`) and the local temporary keypair is deleted.

## Open questions
- **Resolved (2026-11-23):** Role = Option 1A (dedicated compute/`slurmd-gpu`, vLLM stays on L40); Time-slicing = Option 2A (`replicas: 1` exclusive); Scope = Option 3A (Infra + Slurm GPU first, Portal UI GPU toggle deferred).

## Test / Verification plan (Locked at Gate C)
- **Locked Probe SHA-256:** `7d3d5521f01ae70d38aaf335f92dd86866b5889178b68acab4765231dd9d3699  scripts/verify-gpu02.sh`
- **Negative Proof (2026-11-23):** Ran `bash scripts/verify-gpu02.sh` pre-implementation → `2 passed, 5 failed` (failed cleanly on AC #1, #2, #4; AC #3 and #5 baseline healthy).
- **Stage 1 (Static / Cloud fast checks):**
  - `bash -n scripts/verify-gpu02.sh scripts/transfer-images-proxmox.sh`
  - YAML validation of `k8s/nvidia-device-plugin.yaml` and `k8s/values.yaml`
- **Stage 2 (In-Cluster hardware checks):**
  - `bash scripts/verify-gpu02.sh` (verifies AC #1–#5 live on cluster)
  - Manual/scripted SSH revocation check verifying AC #6 on `.50` and `.41`

## Bolt log (Updated at Gate D)
- *(Pending Gate A+B approval)*
