# WP3-1 AI Sandbox

## Project Goal
> **AI Sandbox** provides students a turnkey platform for hands-on AI engineering — pre-installed tools, powerful compute, and an easy-to-use portal — so they can focus on learning, not infrastructure.
>
> **Scope:** Low-level orchestration (Slurm/Slinky on K8s) → central AI services (LLM inference, datasets, experiment tracking) → user interface (Go portal, monitoring) → documentation and validation.

---

## Work Package Overview

| WP | Name | Phase | Status |
|---|---|---|---|
| 1 | Environment Assessment & Requirements | 🏗️ Foundation | 🟢 Done |
| 2 | Capacity Planning & Workload Profiling | 🏗️ Foundation | 🟢 Done |
| 3 | Tech Stack Selection & Architecture Decision | 🏗️ Foundation | 🟢 Done |
| 4 | Slinky Deployment & Orchestrator Integration | 🏗️ Foundation | 🟡 Partial |
| 5 | Slurm Policy & Resource Configuration | 🧩 Services | 🟢 Done |
| 6 | Container Environment & Image Pipeline | 🧩 Services | 🟢 Done |
| 7 | Shared Storage, Datasets & Model Repository | 🧩 Services | 🟢 Done |
| 8 | Network & Security Baseline | 🧩 Services | 🟡 Partial |
| 9 | LLM Inference Server Deployment | 🧩 Services | 🟢 Done |
| 10 | Open-Source Model Curation & Evaluation | 🧩 Services | 🟢 Done |
| 11 | Experiment Tracking Tools Setup | 🧩 Services | 🟢 Done |
| 12 | Web Portal Enhancements | 🎨 UX | 🟡 Partial |
| 13 | Monitoring & Observability | 🎨 UX | 🔴 Not started |
| 14 | Starter Lab Notebook Development | 🎨 UX | 🔴 Not started |
| 15 | Student Documentation & Onboarding Guide | 🎨 UX | 🔴 Not started |
| 16 | Sysadmin Runbook & Operations Guide | 🎨 UX | 🟡 Partial |
| 17 | Integration Testing | ✅ Validation | 🟡 Partial |
| 18 | Pilot with Early Adopters | ✅ Validation | 🔴 Not started |

---

## Phase 1: Foundation 🏗️

### WP3-1-1: Environment Assessment & Requirements ✅
Document the target environments — local Kind cluster (now) and physical HPC cluster with GPUs (later). Define hardware requirements.
- ✅ Target environment specification (local dev vs. production HPC)
- ✅ Hardware requirements matrix (CPU, GPU, memory, storage per role)
- ✅ Network topology diagram
- ✅ Gap analysis: Kind prototype → production cluster

### WP3-1-2: Capacity Planning & Workload Profiling ✅
Define expected student workloads and size partitions and quotas for fair multi-user access.
- ✅ Workload profile catalog (job types, resource needs, durations)
- ✅ Partition design (interactive, batch-cpu, batch-gpu, inference)
- ✅ Resource quotas per student/project
- ✅ Autoscaling policy (NodeSet min/max replicas)

### WP3-1-3: Tech Stack Selection & Architecture Decision ✅
Record all technology choices made (Slinky, Kind, Nix, Go portal) and remaining open decisions.
- Architecture Decision Records (ADRs)
- Reference architecture diagram
- Tech comparison matrices for open decisions
- **Decision finalized:** Two-path dispatcher (interactive=k8s OCI pod, batch=Apptainer SIF), slurm-bridge for unified queue, slurm-client for API

### WP3-1-4: Slinky Deployment & Orchestrator Integration
Deploy the full Slinky stack — slurm-operator, slurm-bridge, controller, worker NodeSets.
- ✅ Working slurm-operator + CRDs
- ✅ CPU NodeSet configurations
- ✅ Finalized Helm values.yaml
- ✅ Infrastructure verification suite passing
- 🟢 **slurm-bridge deployment** — deploy the bridge that intercepts k8s pod requests and registers them as Slurm jobs for fairshare/accounting
- 🔴 GPU NodeSet configuration

---

## Phase 2: Central Services 🧩

### WP3-1-5: Slurm Policy & Resource Configuration 🟢
Configure scheduling policies — partitions, QoS, fair-share, preemption.
- **Spec / Reference:** See [Capacity Planning](./CAPACITY_PLANNING.md) and [Increment Log](./INCREMENT_LOG.md) for WP3-1-5.
- ✅ Partition definitions (interactive, batch-cpu, batch-gpu, inference) configured via `values.yaml` and `slurm.conf` with `PreemptMode=OFF` and capacity planning limits.
- ✅ Native Fair-Share scheduling enabled (`PriorityType=priority/multifactor` and `PriorityWeightFairshare=10000`).
- ✅ Dropped explicit QoS tiers (power-user, admin) in favor of resource fencing limits (`MaxTRESPerJob`).
- ✅ MariaDB StatefulSet and `slurmdbd` deployment manifests integrated into Helm.

### WP3-1-6: Container Environment & Image Pipeline 🟢
Build curated OCI images for interactive workloads, validate Apptainer for batch, and migrate manifest schema.
- **Spec / Reference:** See [Image Pipelining Strategy](./IMAGE_PIPELINING_STRATEGY.md) and [Verification Guide](./WP3-1-6_VERIFICATION.md).
- ✅ **Manifest schema migration** — added `type` (interactive|batch) and `image` (OCI ref) fields; kept `image_file` (SIF) for batch only.
- ✅ **OCI images for interactive workloads** — Dockerfiles for JupyterLab, VS Code Server, and Bash TTYD with `libnss-extrausers`.
- ✅ **In-Cluster OCI registry deployment** — `registry:2` deployed in `slurm` namespace backed by `registry-pvc` with host and node containerd mirroring.
- ✅ **On-demand pulling** — validated fast layer-cached on-demand pull without pre-pull DaemonSet complexity.
- ✅ **Apptainer batch validation & Direct NFS Streaming** — built `python.sif` from `python.def` and verified batch execution via Slurm over `/mnt/storage`.
- ✅ **Shared storage security** — enforced `root:root` `755`/`644` permissions on `/mnt/storage/common/software/` with verified write protection against student UIDs.

### WP3-1-7: Shared Storage, Datasets & Model Repository 🟢
Shared storage for workspaces, pre-downloaded datasets, and model weights.
- **Spec / Reference:** See [Central Storage Architecture](./CENTRAL_STORAGE.md) and [Verification Guide](./WP3-1-7_VERIFICATION.md).
- ✅ **Storage layout & permissions** — initialized `/mnt/storage/{models,datasets,scratch,projects,common,registry}` via `scripts/init-storage.sh` with strict POSIX permissions.
- ✅ **Curated dataset collection** — created `scripts/seed-datasets.sh` and `scripts/seed-kaggle.sh` to populate vision, nlp, and Kaggle competition starter datasets.
- ✅ **Model weight cache & dual-tier fallback** — created `scripts/seed-models.sh` for central models with student private `$HF_HOME` fallback.
- ✅ **Container environment contract injection** — updated `portal/session_manager.go` and `portal/handlers.go` to inject `HF_HUB_CACHE`, `TORCH_HOME`, `KAGGLE_CONFIG_DIR`, `KAGGLEHUB_CACHE`, and `TMPDIR`.
- ✅ **Storage audit & scratch cleanup** — created `scripts/clean-scratch.sh` for sticky-bit scratch garbage collection and `scripts/audit-storage.sh` for disk reporting and duplicate dataset detection.

### WP3-1-8: Network & Security Baseline
Network isolation, Traefik ingress, TLS, and authentication.
- ✅ **WP3-1-8-1: Namespace Isolation & RBAC Hardening** ([#70](https://github.com/khemingkapat/ai_sandbox/issues/70)) — Merged via PR #74.
- ✅ **WP3-1-8-2: Kubernetes NetworkPolicies for Workload Isolation** ([#71](https://github.com/khemingkapat/ai_sandbox/issues/71)) — Completed & verified.
- ✅ **WP3-1-8-3: Traefik Ingress TLS & Security Headers** ([#72](https://github.com/khemingkapat/ai_sandbox/issues/72)) — Completed & verified.
- ✅ **WP3-1-8-4: Network & Security Verification Test Suite** ([#73](https://github.com/khemingkapat/ai_sandbox/issues/73)) — Completed & verified.

### WP3-1-9: LLM Inference Server Deployment
Central LLM service (vLLM) with Traefik API protection and hardware time-slicing.
- ✅ **Inference server stabilization** — Pinned `vllm/vllm-openai:v0.31.0` with `Recreate` deployment strategy, read-only NFS model cache mount, and exact node taint tolerations in [`k8s/vllm-deployment.yaml`](file:///home/khemi/workspace/ai_sandbox/k8s/vllm-deployment.yaml).
- ✅ **API gateway protection & rate limiting** — Traefik `/v1` ingress router with `vllm-ratelimit` (10 req/s, burst 20) and `vllm-inflight` (max 15 concurrent) middlewares in [`k8s/traefik-security-configmap.yaml`](file:///home/khemi/workspace/ai_sandbox/k8s/traefik-security-configmap.yaml).
- ✅ **Dual-tenancy GPU allocation** — NVIDIA L40 (46GB) virtual time-slicing verified with vLLM (`0.65` utilization, 16.8GB free for Slurm GRES GPU dispatch).
- ✅ **Runtime hardening & verification** — 22-test automated verification suite in [`scripts/verify-llm.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/verify-llm.sh) validating in-place crash recovery, 429 throttling, and context window rejection.
- 🟡 **Student API Token Authentication** — Staged for WP3-1-12 (Central Services API Authorization).

### WP3-1-10: Open-Source Model Curation & Evaluation
Curated model catalog, candidate backlog, and ingestion pipeline focusing on Qwen 3.5, Qwen 2.5, and Gemma 4.
- ✅ **Curated model matrix & catalog manifest** — Created [`docs/MODEL_CATALOG.json`](file:///home/khemi/workspace/ai_sandbox/docs/MODEL_CATALOG.json) and [`docs/MODEL_CATALOG.md`](file:///home/khemi/workspace/ai_sandbox/docs/MODEL_CATALOG.md) specifying served `Qwen/Qwen3.5-0.8B` (measured), `Qwen/Qwen2.5-32B-Instruct-AWQ` (measured), Qwen 3.5 (MoE 35B-A3B & Dense 9B), Gemma 4 (E4B & 12B), EmbeddingGemma 2, and BGE-M3.
- ✅ **Candidate models backlog** — Created [`docs/CANDIDATE_MODELS_BACKLOG.md`](file:///home/khemi/workspace/ai_sandbox/docs/CANDIDATE_MODELS_BACKLOG.md) covering Mistral, Phi, Gemma, Smol, and Qwen hardware sizing.
- ✅ **Deterministic model swap operator CLI** — Created [`scripts/swap-model.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/swap-model.sh) with offline pre-flight verification, comment-preserving manifest updates, and auto-rollback.
- ✅ **Hardware profiling & memory sizing guide** — Documented measured VRAM footprints (1.72 GiB weights, 25.08 GiB KV cache on L40) and token capacities.
- ✅ **Student offline developer runbook** — Provided copy-paste snippets for zero-download `local_files_only=True` loading and batch PEFT/LoRA fine-tuning.
- ✅ **Automated ingestion & evaluation pipeline** — Hardened [`scripts/ingest-model.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/ingest-model.sh) with safetensors enforcement gates, jinja template caching, and verified offline tokenizer execution.

### WP3-1-11: Experiment Tracking Tools Setup
- ✅ **Tracking server deployment** — Deployed Gunicorn WSGI MLflow server in dedicated `services` namespace on `ai-worker1` with Slinky tolerations.
- ✅ **Storage backend (Decoupled DB + Proxied Artifacts)** — Dedicated PostgreSQL 16 StatefulSet (`mlflow-postgres-pvc`, 10Gi) isolated from control plane MariaDB; proxied artifact streaming (`--serve-artifacts`) writing to `/mnt/storage/mlflow/artifacts` (50Gi PVC).
- ✅ **Traefik gateway integration** — Dynamically routed `/mlflow`, `/api/2.0`, `/ajax-api`, and static bundles (`--static-prefix /mlflow`) with security headers over HTTPS.
- ✅ **Per-student/project isolation** — Namespaced experiment support via `MLFLOW_EXPERIMENT_NAME` with NetworkPolicy restricting DB port 5432 and permitting workload port 5000 egress.
- ✅ **Passive client in container images** — `mlflow` pre-installed in [`images/jupyterlab/Dockerfile`](file:///home/khemi/workspace/ai_sandbox/images/jupyterlab/Dockerfile) with passive pointer `MLFLOW_TRACKING_URI=http://mlflow.services.svc.cluster.local:5000`.
- ✅ **Integration guide & automated test suite** — Established [`docs/WP3-1-11_EXPERIMENT_TRACKING_GUIDE.md`](file:///home/khemi/workspace/ai_sandbox/docs/WP3-1-11_EXPERIMENT_TRACKING_GUIDE.md) and [`scripts/verify-mlflow.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/verify-mlflow.sh) (9/9 checks PASSED).

---

## Phase 3: User Experience 🎨

### WP3-1-12: Web Portal Enhancements
The Go/Echo portal is the single entry point. Launch notebooks, submit jobs, call inference, view usage.
- ✅ Remove legacy SSH + ext_* code paths
- ✅ User dashboard (active jobs, usage, quota) — `apiUserJobs`, `apiClusterStatus`
- ✅ Resource availability view (free GPUs, queue depth)
- 🔴 **Adopt `slurm-client` library** — replace raw `net/http` REST calls with `github.com/SlinkyProject/slurm-client`. Removes hardcoded `v0.0.42` API version. Adds client-side caching.
- 🔴 **Two-path dispatcher** — route interactive jobs to k8s Pod spec (+ Service + Ingress), batch jobs to sbatch with `apptainer exec`. Requires k8s client in portal. `slurm-bridge` handles Slurm registration for the interactive path.
- 🔴 **Interactive session Pod management** — generate Pod spec, Service, and Ingress for Jupyter/VS Code/bash sessions. Replace Traefik sidecar dynamic routes with k8s-native Ingress routing.
- 🔴 GPU job submission support
- 🔴 Inference server integration (model picker, chat UI)

### WP3-1-13: Monitoring & Observability
Prometheus, Grafana, slurm-exporter. Dashboards for admins and students.
- Prometheus + slurm-exporter deployment
- Grafana dashboards (cluster, GPU, jobs)
- Student-facing usage metrics in portal
- Alerting rules (node down, GPU OOM, queue full)

### WP3-1-14: Starter Lab Notebook Development
Template notebooks for the "first 5 minutes" experience.
- "Hello Sandbox" — submit a job, see results
- GPU training — fine-tune a small model
- LLM inference — call the API, build a RAG chain
- Experiment tracking — log a run to MLflow
- All pre-loaded in default workspace

### WP3-1-15: Student Documentation & Onboarding Guide
The docs students actually read. Practical, concise, example-heavy.
- Getting started guide (login → first job in 5 min)
- Tool catalog (what's available, how to access)
- GPU usage guide
- FAQ and common errors

### WP3-1-16: Sysadmin Runbook & Operations Guide
Ops documentation for long-term maintainability.
- Cluster bootstrap/teardown procedures
- Slinky + K8s upgrade runbook
- User and project management
- Backup and restore procedures
- Incident response playbook

---

## Phase 4: Validation ✅

### WP3-1-17: Integration Testing
End-to-end tests covering the full student journey.
- E2E test suite (extending verify-infrastructure.sh)
- Portal integration tests
- GPU and inference pipeline tests
- Performance benchmarks under concurrent users

### WP3-1-18: Pilot with Early Adopters
Real students use it. Observe, collect feedback, iterate.
- Pilot deployment on target HPC hardware
- Feedback collection (surveys, usage data, interviews)
- Bug and friction-point tracking
- Iteration plan from findings
- Go/no-go for full rollout
