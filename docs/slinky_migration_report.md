# Slinky Migration Report
**HPC Sandbox Platform — May 2026**

---

## Contents

1. [TL;DR](#1-tldr)
2. [Current Architecture](#2-current-architecture)
3. [What Slinky Is](#3-what-slinky-is)
4. [Current vs Slinky](#4-current-vs-slinky)
5. [Hardware & Software Requirements](#5-hardware--software-requirements)
6. [Job Flow Under Slinky](#6-job-flow-under-slinky)
7. [Re-architecture Plan](#7-re-architecture-plan)
8. [Risks](#8-risks)

---

## 1. TL;DR

The current stack runs Slurm inside Docker Compose on a single host. When the queue fills up, it falls back to SSH-ing into a separate container, running Apptainer manually, and returning fake job IDs. This works for local dev but cannot scale or run on real hardware without a full rewrite.

Slinky (SchedMD's official Slurm-on-Kubernetes project) replaces Docker Compose with Kubernetes as the infrastructure layer while keeping Slurm as the scheduler. Every job — CPU, GPU, or non-Slurm overflow — gets a real Slurm job ID and runs in a proper Kubernetes pod. The SSH hack, fake `ext_*` IDs, and Apptainer-inside-Docker nesting all go away.

**Portal code is largely unchanged.** The HTTP endpoints, JWT auth, and Traefik routing stay the same. The change is purely in how compute is provisioned.

**Estimated migration effort:** 4–6 weeks for two engineers, phased so the Docker Compose cluster can run in parallel until each phase is validated.

---

## 2. Current Architecture

### 2.1 Services

| Service | Image | Role |
|---|---|---|
| `mysql` | mariadb:12 | Slurm accounting DB |
| `slurmdbd` | giovtorres/slurm-docker-cluster | Slurm DB daemon |
| `slurmctld` | Dockerfile.controller (custom) | Controller, job scheduling |
| `slurmrestd` | giovtorres/slurm-docker-cluster | REST API, port 6820 |
| `cpu-worker` ×N | Dockerfile.worker (custom) | Compute nodes, runs slurmd + Apptainer |
| `external-worker` | Dockerfile.external (Rocky 9) | SSH overflow node |
| `portal` | Dockerfile.portal (Go/Echo) | Web UI, job submission, JWT sessions |
| `traefik` | traefik:v3.0 | Reverse proxy for JupyterLab |

### 2.2 Current job flow

```
User clicks Launch
  → Portal validates JWT, builds job script with #SBATCH + apptainer exec
  → POST /slurm/v0.0.42/job/submit to slurmrestd
  → slurmctld checks queue

  if node free:
    slurmd runs job script on cpu-worker
    Apptainer exec jupyterlab.sif ...

  if all nodes busy (CheckPendingQueue == true):
    SSH into external-worker (password: "password")
    nohup apptainer exec ... &
    return fake "ext_{timestamp}" job ID
    track via SQLite port lease table, NOT Slurm
```

### 2.3 Known problems

**SSH overflow is the biggest issue.** Concretely:

- Hardcoded SSH password in `slurm_service.go`
- `ext_*` job IDs are not in Slurm — `squeue` and `sacct` can't see them
- Cancel only releases a port lease; the `nohup` process on `external-worker` keeps running
- `IsExternalJobDone()` checks for a flag file over SSH — no real status signal

**Other structural limitations:**

- `CPU_WORKER_COUNT` is a static `.env` integer; scaling requires restarting the whole stack
- GPU support (`GPU_ENABLE`) can't coexist with CPU autoscaling
- cgroup is forced to v1 at runtime in the worker entrypoint, so resource limits aren't actually enforced
- Apptainer `.sif` runs inside a Docker container — container-in-container with no real benefit
- Entire cluster is one host; Docker Compose has no multi-machine model

---

## 3. What Slinky Is

Slinky is two independent components, both Apache 2.0, built by SchedMD. v1.0 released November 2025.

### `slurm-operator`

Runs Slurm's daemons (`slurmctld`, `slurmdbd`, `slurmd`, `slurmrestd`) as Kubernetes pods, managed via Helm charts and CRDs. This is a direct replacement for `docker-compose.yml`. Workers are defined as **NodeSets** — pools of `slurmd` pods that autoscale based on queue depth.

This is purely infrastructure. From the portal's perspective, slurmrestd is still an HTTP endpoint. Nothing in `portal/` changes.

### `slurm-bridge`

A Kubernetes scheduling plugin. When `slurmctld` allocates resources to a job, `slurm-bridge` intercepts the allocation and creates a Kubernetes pod instead of running on a bare `slurmd`. The pod uses whatever OCI image is declared in the job spec.

This is what replaces the SSH overflow. A job targeting the `non-slurm` partition gets a real Kubernetes pod and a real Slurm job ID. No SSH, no fake IDs, no flag files.

### How they relate to your current components

| Current | Replaced by |
|---|---|
| `docker-compose.yml` | Helm charts (`slurm-operator`, `slurm`, `portal`, `traefik`) |
| `Dockerfile.controller` + `Dockerfile.worker` | slurm-operator OCI images from `ghcr.io/slinkyproject/` |
| `Dockerfile.external` + `external-worker` service | `slurm-bridge` non-Slurm NodeSet |
| `SubmitExternalJob()` in `slurm_service.go` | Standard `POST /slurm/.../job/submit` — no special path |
| `IsExternalJobDone()` in `slurm_service.go` | Standard Slurm job state polling (already implemented) |
| `ext_*` branch in `job_handler.go` Status/Cancel/Log | Deleted — all job IDs are real Slurm integers |
| SSH + password auth in `slurm_service.go` | Deleted |
| `jupyterlab.sif` Apptainer images | OCI images in a container registry |
| `image_file` field in `manifest.yaml` | `image` field pointing to `registry/image:tag` |
| `CPU_WORKER_COUNT` / `GPU_ENABLE` in `.env` | NodeSet replica counts and resource requests in `values.yaml` |

### On Apptainer

Apptainer exists in the current stack because `slurmd` runs on plain Rocky Linux — there's no container runtime underneath, so `.sif` is the only way to give each job a reproducible software environment.

Under Slinky, each job runs in a Kubernetes pod, which already has a container runtime (`containerd`). The pod's container image *is* the software environment. Apptainer becomes redundant on any K8s-managed node.

The one remaining use case for Apptainer is bare-metal HPC nodes that join your cluster without a container runtime installed (e.g. older supercomputer nodes). On those nodes only, `slurmd` still runs natively and Apptainer handles job isolation. On any Kubernetes node, it's gone.

---

## 4. Current vs Slinky

| | Current | Slinky |
|---|---|---|
| **Infrastructure** | Single-host Docker Compose | Multi-host Kubernetes (any distribution) |
| **Worker scaling** | Static `CPU_WORKER_COUNT`, requires stack restart | NodeSet autoscaler driven by Slurm queue depth |
| **GPU support** | `GPU_ENABLE` flag, can't coexist with CPU autoscaling | Dedicated GPU NodeSet, full GRES support, `nvidia.com/gpu` resource requests |
| **Non-Slurm workloads** | SSH to `external-worker`, hardcoded password, fake `ext_*` IDs | `slurm-bridge` creates real K8s pods with real Slurm job IDs |
| **Job visibility** | `squeue`/`sacct` blind to `ext_*` jobs | All jobs visible in `squeue`, `sacct`, accounting |
| **Job cancellation** | `DELETE` works for Slurm jobs; `ext_*` cancel leaves process running | `DELETE` kills Kubernetes pod immediately for all job types |
| **Container runtime** | Apptainer `.sif` inside Docker (nested) | OCI image in Kubernetes pod (native) |
| **Image lifecycle** | Manual `apptainer build` + `cp` to `./storage/` | `docker build && docker push` to any OCI registry |
| **Shared storage** | Host bind-mounts (`./storage/`) — single host only | PersistentVolumeClaims backed by NFS, Lustre, or cloud storage |
| **Resource enforcement** | cgroup v1 forced at runtime, limits not enforced | K8s resource requests/limits enforced by containerd |
| **Multi-host** | Not possible | Native — any node joining K8s is schedulable |
| **Fault tolerance** | Stack goes down together | K8s restarts crashed pods; `slurmctld` HA available |
| **Observability** | `docker logs` per container | Prometheus via `slurm-exporter`, `kubectl logs`, Grafana |

---

## 5. Hardware & Software Requirements

### 5.1 Hardware

For local development, a single machine with k3s is enough:

| Node role | Minimum | Recommended |
|---|---|---|
| K8s control plane | 4 vCPU, 8 GB RAM | 8 vCPU, 16 GB RAM |
| CPU worker nodes | 2 vCPU, 4 GB RAM ×2 | 4 vCPU, 8 GB RAM ×4 |
| GPU worker (optional) | 1× NVIDIA GPU, 8 GB VRAM | A100 / RTX 4090 |
| Shared storage | 20 GB NFS or hostPath PV | 100 GB+ NFS or Lustre, 1 Gbps+ |
| Network | 1 Gbps between nodes | 10 Gbps for MPI / multi-node |

k3s control plane needs ~2 GB RAM and runs fine on a single developer machine alongside worker nodes via VMs or WSL2 instances.

For production HPC (>50 nodes), target kubeadm, EKS, or GKE rather than k3s.

### 5.2 Software

| Layer | Technology | Notes |
|---|---|---|
| K8s distribution | k3s (local), EKS/GKE (cloud), kubeadm (bare metal) | k3s preferred for dev |
| Container runtime | containerd 1.7+ | Included with k3s |
| GPU support | NVIDIA Container Toolkit + device plugin | Host install on GPU nodes only, no host CUDA needed |
| Slurm version | 25.11.x | Matches current `SLURM_VERSION`; Slinky v1.0 targets 25.11 |
| Slinky | v1.0.x | Released Nov 2025, Apache 2.0 |
| Helm | 3.x | Required for all Slinky charts |
| OCI registry | GHCR, ECR, or local `registry:2` | Replaces `.sif` file distribution |
| Shared storage | NFS CSI driver or Longhorn | PVCs replace `./storage/` bind-mounts |
| Ingress | Traefik (existing) | `traefik-dynamic/` config reused as-is |
| Portal | Go 1.22 + Echo (existing) | No code changes in `portal/` except deleting SSH/ext paths |
| Monitoring | Prometheus + slurm-exporter (optional) | Slinky ships the exporter; needed for autoscaling |

---

## 6. Job Flow Under Slinky

### 6.1 CPU job (e.g. JupyterLab)

```
User submits via portal
  → JWT validated, project extracted from claims
  → POST /slurm/v0.0.42/job/submit to slurmrestd pod
  → slurmctld evaluates partition policy, fair-share, QoS
  → assigns to cpu NodeSet node

slurm-bridge intercepts allocation
  → builds K8s pod spec from manifest.yaml image field
     (e.g. image: jupyter/scipy-notebook:latest)
  → mounts project PVC at $WORKSPACE
  → K8s schedules pod onto a cpu-labelled physical node
  → containerd pulls image if not cached

Job script runs inside pod
  → calls POST /api/internal/allocate-port (portal)
  → portal writes Traefik dynamic route
  → portal returns proxy URL to browser when state == RUNNING

On finish / cancel
  → DELETE /slurm/v0.0.42/job/{job_id}
  → slurmctld signals slurm-bridge
  → slurm-bridge deletes K8s pod immediately
  → portal releases port lease, removes Traefik route
```

### 6.2 GPU job

Same flow as CPU with three differences:

1. Manifest declares `gpu` partition and `--gres=gpu:1`
2. `slurm-bridge` adds `nvidia.com/gpu: 1` to the pod resource request
3. K8s schedules onto a node with the NVIDIA device plugin and a free GPU; pod sees `/dev/nvidia0`

No host CUDA installation needed on worker nodes.

### 6.3 Non-Slurm job (replaces `external-worker`)

```
Job submitted to non-slurm partition
  → slurmctld allocates resources normally
  → slurm-bridge creates K8s Job or Pod directly from image spec
     (no slurmd involved, just a container running the workload)
  → real Slurm job ID returned — visible in squeue, sacct

Cancel
  → DELETE /slurm/v0.0.42/job/{job_id}
  → slurm-bridge issues kubectl delete pod
  → process terminated immediately
```

No SSH, no `ext_*` IDs, no flag files, no port lease workarounds. The entire `ext_*` branch in `job_handler.go` is deleted.

---

## 7. Re-architecture Plan

### 7.1 Code deleted from portal

| File | What goes |
|---|---|
| `services/slurm_service.go` | `SubmitExternalJob()`, `IsExternalJobDone()`, SSH dial + password auth |
| `handlers/job_handler.go` | `ext_*` branch in `Status()`, `Cancel()`, `Log()` |
| `ports/port_manager.go` | SSH section in external job path; port allocation logic itself stays |

Net change: ~200 lines deleted, ~0 lines added.

### 7.2 Config changes

| Current | New |
|---|---|
| `.env` `CPU_WORKER_COUNT`, `GPU_ENABLE`, `GPU_COUNT`, `CUDA_VERSION` | NodeSet `replicas`, `resources.limits.nvidia.com/gpu` in `values.yaml` |
| `storage/common/software/*/manifest.yaml` `image_file: *.sif` | `image: registry/image:tag` |
| `docker-compose.yml` service definitions | Helm release per component |

### 7.3 Migration phases

| Phase | Scope | Est. time |
|---|---|---|
| **0 — Prerequisites** | Install k3s, configure kubectl, stand up local OCI registry (`registry:2`) | 3 days |
| **1 — Slurm on K8s** | Deploy `slurm-operator` + `slurm` Helm charts. Validate `sinfo`, `sbatch`, `squeue`. Run existing test jobs. Docker Compose stays running in parallel. | 1 week |
| **2 — Storage** | Replace `./storage/` bind-mounts with PVCs. Migrate project directories. Update portal env vars. Back up everything first. | 3 days |
| **3 — Images** | Build OCI images for all apps (JupyterLab etc.), push to registry, update `manifest.yaml` to remove `image_file`. | 3–5 days |
| **4 — slurm-bridge** | Deploy `slurm-bridge`, configure `non-slurm` NodeSet, validate non-Slurm job path end-to-end, delete SSH + `ext_*` code from portal. | 1 week |
| **5 — GPU NodeSet** | Label a GPU node, deploy GPU NodeSet, validate `--gres=gpu:1` job submission. | 3 days |
| **6 — Cleanup** | Remove Docker Compose files and SSH code, add Prometheus + slurm-exporter, write runbooks. | 1 week |

Phases 0–3 are fully reversible. Phase 4 is the cutover point. Docker Compose can be kept running through Phase 4 and decommissioned in Phase 6.

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Slinky v1.0 is recent (Nov 2025); edge cases still being documented | Medium | Pin Helm chart versions. Monitor [SlinkyProject/slurm-operator](https://github.com/SlinkyProject/slurm-operator) issues. Keep Docker Compose running in parallel through Phase 4. |
| `slurmd` reports host machine resources instead of pod limits (known upstream) | Low | Set CPU/memory explicitly in `slurm.conf` NodeName definitions. Don't rely on auto-detection. |
| cgroup enforcement disabled inside pods (known upstream) | Low | Use K8s resource requests/limits on pod spec as the enforcement layer. Slurm quotas still apply for scheduling policy. |
| OCI image pull latency on cold nodes | Low | Pre-pull images via a DaemonSet or `k3s ctr images import`. |
| Storage migration data loss | High | Full backup of `./storage/` before Phase 2. Run bind-mount and PVC in parallel until validated. |
| k3s not suitable for large-scale production (>100 nodes) | Medium | Fine for dev/staging. For production HPC target kubeadm, EKS, or GKE. |

---

## References

- [Slinky landing page](https://slinky.ai)
- [slurm-operator GitHub](https://github.com/SlinkyProject/slurm-operator)
- [slurm-bridge GitHub](https://github.com/SlinkyProject/slurm-bridge)
- [Slinky docs](https://slinky.schedmd.com/docs/)
- [Running Slurm on Amazon EKS with Slinky — AWS Blog](https://aws.amazon.com/blogs/containers/running-slurm-on-amazon-eks-with-slinky/)
- [SchedMD Slinky announcement](https://www.schedmd.com/introducing-slinky-slurm-kubernetes/)
