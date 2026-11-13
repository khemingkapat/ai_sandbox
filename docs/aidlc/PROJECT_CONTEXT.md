# Project Context: AI Sandbox

Last updated: 2026-11-08

## Purpose
The **AI Sandbox** provides students with a turnkey, browser-accessible platform for hands-on AI engineering — offering pre-installed tools, managed compute, and a unified web portal — so learners can focus directly on experimentation rather than cluster infrastructure.

## Major capabilities
- **Interactive Workspaces:** Web-based JupyterLab, VS Code, and Bash sessions launched on-demand as Kubernetes Pods via Traefik Ingress with ForwardAuth (`workload` namespace) — **status: done**
- **Batch HPC Workloads:** Slurm job scheduling across CPU and GPU partitions using containerized Apptainer `.sif` execution over `/mnt/storage` — **status: done**
- **Central AI Services:** Shared LLM inference (vLLM serving Qwen 3.5 / 2.5 / Gemma 4), experiment tracking (MLflow + Postgres 16), in-cluster OCI registry (`services` namespace) — **status: done**
- **Vector Search & Starter Labs:** Central Qdrant vector database (`services` namespace) — **status: done (WP14-A)**; 5-part starter curriculum notebooks & pre-baked SDKs — **status: done (WP14-B)**
- **Monitoring & Telemetry:** Slurm incident telemetry epilog hook, Prometheus, Grafana, and portal observability — **status: planned**

## Architecture as it stands
- **Web Portal (`portal/`):** Go 1.26 Echo service managing authentication (HMAC Bearer tokens, ForwardAuth endpoint `/auth/verify`), dynamic K8s Pod/Service lifecycle, and Slurm batch job dispatch (`sbatch`). See [ADR 0001](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0001-two-path-workload-execution.md).
- **Cluster Orchestration (`k8s/`, `helm/`):** Multi-node K3s cluster on Proxmox hypervisors (with local Kind support) running SchedMD Slinky (`slurm-operator`, `slurmctld`, worker NodeSets, `slurmdbd` + MariaDB) and Traefik ingress controller.
- **Central AI Services (`k8s/`, `services` namespace):** Dedicated namespace hosting vLLM (`k8s/vllm-deployment.yaml`), MLflow tracking server + Postgres 16 (`k8s/mlflow-deployment.yaml`), and local OCI registry (`k8s/registry-deployment.yaml`). See [ADR 0004](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md).
- **Storage Subsystem (`storage/` -> `/mnt/storage`):** Host storage mapped to nodes. Workspaces isolated using scoped Kubernetes `subPath` mounts (`projects/<project>`, `scratch`, read-only `datasets`, `models`, and `common/etc`). Zero LDAP/SSSD dependency via `libnss-extrausers` and non-root `PodSecurityContext` (UID 1001/GID 2001, `mode 2770`, `umask 0002`). See [ADR 0002](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md).

## Key constraints
- **GPU Hardware:** Single NVIDIA L40 (46GB) GPU on `ai-worker1`. Managed via K8s Device Plugin time-slicing (`replicas: 4`). vLLM is capped at `0.65` VRAM utilization (~28GB). Exclusive Slurm batch GPU jobs require temporal yield/scale-down of vLLM. See [ADR 0003](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md).
- **Network Boundaries:** Untrusted student pods run strictly in `workload` namespace. Strict CNI NetworkPolicies block access to host networks, MariaDB (3306), and Postgres (5432). All external traffic routes via Traefik.
- **Stateless Portal:** Web portal does not store persistent database state; it derives cluster state dynamically from Kubernetes APIs and Slurm CLI/REST.

## Conventions
- **Dual-Path Testing:**
  - Stage 1 (Fast / Cloud): `cd portal && go test -v ./...`, `go vet ./...`, `golangci-lint run`, `bash -n scripts/*.sh`.
  - Stage 2 (In-Cluster Hardware Verification): `bash scripts/test-student-golden-path.sh`, `bash scripts/verify-llm.sh`, `bash scripts/verify-mlflow.sh`, `bash scripts/verify-security.sh`. Concurrency strictly limited to 1.
- **File Linking:** Markdown docs use clickable `file://` links for configs and source symbols.

## Known problem areas
- **Batch Failure Visibility:** When a Slurm batch job fails (`OOM` or non-zero exit), students currently lack real-time incident surfacing in the Web Portal (`WP13` epilog webhook + ring buffer).
- **Single-GPU Contention Window:** Scaling down central vLLM for exclusive `batch-gpu` Slurm jobs temporarily pauses interactive chat inference until the batch job finishes.

## Open questions
- Sequencing between `WP13` (Monitoring & Slurm Incident Telemetry), `CI01` (Dual-Path GitHub Actions & In-Cluster Runner), and `WP00` (Interactive OpenAPI/K8s Documentation Tooling).
