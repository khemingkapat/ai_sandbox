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
| 6 | Container Environment & Image Pipeline | 🧩 Services | 🟡 Partial |
| 7 | Shared Storage, Datasets & Model Repository | 🧩 Services | 🟡 Partial |
| 8 | Network & Security Baseline | 🧩 Services | 🟡 Partial |
| 9 | LLM Inference Server Deployment | 🧩 Services | 🔴 Not started |
| 10 | Open-Source Model Curation & Evaluation | 🧩 Services | 🔴 Not started |
| 11 | Experiment Tracking Tools Setup | 🧩 Services | 🔴 Not started |
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

### WP3-1-6: Container Environment & Image Pipeline
Build curated OCI images for interactive workloads, validate Apptainer for batch, and migrate manifest schema.
- 🔴 **Manifest schema migration** — add `type` (interactive|batch) and `image` (OCI ref) fields; keep `image_file` (SIF) for batch only. Update `AppManifest` struct in portal.
- 🔴 **OCI images for interactive workloads** — Dockerfiles for JupyterLab, code-server, bash TUI. Push to local registry.
- 🟢 **Apptainer batch validation** ⚠️ EXPERIMENTAL — validate `apptainer exec user.sif` works inside slurmd pods under Slinky. Test GPU passthrough, shared filesystem binding, rootless UID enforcement. *This is interactive/experimental work — not Jules-delegatable.*
- 🔴 OCI registry deployment (local `registry:2`)
- 🔴 Pre-pull DaemonSet for fast startup
- 🟡 Existing manifests still reference `.sif` files (jupyterlab.sif, python.sif) — need migration

### WP3-1-7: Shared Storage, Datasets & Model Repository
Shared storage for workspaces, pre-downloaded datasets, and model weights.
- Production PVC configuration (NFS CSI or equivalent)
- Directory structure: /projects/, /datasets/, /models/, /scratch/
- Curated dataset collection
- Model weight cache (shared across users)
- Storage quotas and backup plan

### WP3-1-8: Network & Security Baseline
Network isolation, Traefik ingress, TLS, and authentication.
- Kubernetes NetworkPolicy definitions
- Traefik ingress with TLS
- Auth integration (JWT → SSO/OAuth2)
- RBAC for namespaces and resources
- Student workspace isolation

### WP3-1-9: LLM Inference Server Deployment
Central LLM service (Ollama/vLLM/TGI) with pre-loaded models.
- Inference server deployment
- Pre-loaded model set (Llama 3, Mistral, embeddings, etc.)
- API endpoint with rate limiting
- GPU resource allocation for inference
- Portal integration (model picker UI)

### WP3-1-10: Open-Source Model Curation & Evaluation
Select, benchmark, and document models for the sandbox.
- Curated model catalog (LLMs, vision, embeddings, code)
- Evaluation benchmarks per model
- Model cards with usage guidance
- Download/caching automation
- GPU memory requirements per model

### WP3-1-11: Experiment Tracking Tools Setup
Deploy MLflow (or similar) so students import mlflow and go.
- Tracking server deployment
- Storage backend (DB + artifact store on shared PVC)
- Per-student/project isolation
- Pre-configured client in container images
- Integration guide and examples

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
