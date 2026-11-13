# Unit: WP14-B — Pre-Baked Client SDKs & 5 Starter Curriculum Labs

Status: in-progress (Phase 1 — Gate A+B)
Parent GitHub WP: #14
Exploratory? no

## Intent
Implement the client-side half of Work Package 14 by pre-baking the required Data Pipeline (`polars`, `dask`), Vector/RAG (`qdrant-client`, `llama-index`), and Fine-Tuning (`torch`, `transformers`, `peft`) libraries directly into `images/jupyterlab/Dockerfile` (`interactive-jupyter:latest` per M1 Report §4.7), wiring `QDRANT_URL` into student interactive session pods (`portal/session_manager.go`), and seeding the 5 turnkey starter curriculum notebooks (`01_hello_sandbox.ipynb` through `05_gpu_lora_finetuning.ipynb`) into `project1` so students can run end-to-end AI workflows with zero runtime `pip`/`conda` NFS metadata storms.

## Scope & Non-goals
- **In scope:**
  - **Pre-Baked JupyterLab Client Image (`images/jupyterlab/Dockerfile`, `scripts/build-oci-images.sh`, `scripts/transfer-images-proxmox.sh`):**
    - Pre-bake `mlflow`, `polars`, `dask[dataframe]`, `pyarrow`, `qdrant-client`, `llama-index-core`, `llama-index-vector-stores-qdrant`, `llama-index-llms-openai-like`, `torch` (CPU/CUDA-compatible wheel), `transformers`, `peft`, and `nbclient`/`nbconvert` into `images/jupyterlab/Dockerfile`.
    - Set default `ENV QDRANT_URL="http://qdrant.services.svc.cluster.local:6333"` alongside `MLFLOW_TRACKING_URI="http://mlflow.services.svc.cluster.local:5000"`.
    - Import the updated `interactive-jupyter:latest` image into K3s node-local `containerd` (`ai-worker1` / `ai-control`) so student pods start in `<5s` without pulling from the internet or compiling on NFS.
  - **Portal Session Environment Wiring (`portal/session_manager.go`, `portal/session_manager_test.go`):**
    - Inject `QDRANT_URL=http://qdrant.services.svc.cluster.local:6333` into spawned interactive session pods in `workload` namespace.
  - **5 Turnkey Starter Curriculum Notebooks (`templates/projects/project1/starter_labs/`, `scripts/init-storage.sh`):**
    - `01_hello_sandbox.ipynb`: Cluster orientation, POSIX UID/GID (`1001:2001`) verification, scoped VFS check, and Slurm batch script generation.
    - `02_data_processing_polars.ipynb`: Single-node out-of-core ETL with `polars` and `dask` streaming from read-only `/mnt/storage/datasets` (`titanic/train.csv`, `imdb/train.csv`) and writing Parquet output to `/mnt/storage/scratch`.
    - `03_experiment_tracking_mlflow.ipynb`: Training loop logging hyperparameters, step metrics, and artifact files to live central MLflow (`http://mlflow.services.svc.cluster.local:5000`).
    - `04_llm_inference_and_rag.ipynb`: End-to-end RAG pipeline using `llama-index` and `qdrant-client` to chunk syllabus documents, index embeddings into live central Qdrant (`http://qdrant.services.svc.cluster.local:6333`), retrieve top-K context via cosine similarity, and query central `vLLM` (with graceful offline fallback when the GPU node is paused/offline).
    - `05_gpu_lora_finetuning.ipynb`: Parameter-Efficient Fine-Tuning (`peft` LoRA adapter injection with `LoraConfig` + `torch`) loading model config from `/mnt/storage/models`, auto-selecting `cuda` vs `cpu`, executing training steps, and logging LoRA adapter metrics/metadata to live central MLflow.
    - Update `scripts/init-storage.sh` to seed `templates/projects/project1/starter_labs/*.ipynb` into `/mnt/storage/projects/project1/starter_labs/` with `1001:2001` (`mode 2770`) ownership.
  - **Automated Verification Suite (`scripts/verify-starter-labs.sh`):**
    - End-to-end verification probe running inside a non-root (`1001:2001`) student pod in `workload` namespace with scoped `subPath` mounts, verifying pre-baked SDK imports, read-only boundary enforcement (`EROFS` on `/mnt/storage/datasets` and `/mnt/storage/models`), and headless execution of all 5 starter notebooks against live cluster services (`qdrant`, `mlflow`, `/mnt/storage`).
- **Non-goals:**
  - Modifying server-side Qdrant (`k8s/qdrant/`) or MLflow (`k8s/mlflow/`) manifests (already completed in WP11 and WP14-A).
  - Requiring physical GPU availability on `ai-sandbox-gpu-vm` for Gate C/D verification to pass when the GPU node is offline.

## Constraints and decisions to respect
- [ADR 0002: Storage and UID/GID Isolation Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- [ADR 0004: Central AI Services Architecture & Namespace Decoupling](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md)
- [M1 System Assessment Report §§4.4–4.7](file:///home/khemi/workspace/ai_sandbox/docs/reports/M1_SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md)
- **Resolved Strategic Decisions (Khem):**
  1. **Graceful Hardware Fallback:** Labs 03, 04, and 05 execute real network operations against live CPU-hosted `Qdrant` (`:6333`) and `MLflow` (`:5000`), while gracefully handling `vLLM`/GPU offline status so headless tests validate the full stack deterministically right now.
  2. **Pre-Baked OCI Image Strategy (§4.7):** Pre-bake the curriculum SDKs directly into `images/jupyterlab/Dockerfile` and cache in node-local K3s `containerd` to prevent NFS metadata storms.
  3. **Workspace Seeding:** Seed the 5 starter notebooks into `project1` (`/mnt/storage/projects/project1/starter_labs/`) first via `templates/projects/project1/starter_labs/` and `scripts/init-storage.sh`.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp14b.md` | Unit specification and Bolt Log |
| `docs/aidlc/UNITS.md` | Flip WP14-B status at Gate D |
| `docs/aidlc/PROJECT_CONTEXT.md` | Update Starter Labs capability status at Gate D |
| `portal/session_manager.go` | Inject `QDRANT_URL` environment variable into spawned student session pods |
| `portal/session_manager_test.go` | Locked unit test asserting `QDRANT_URL` and `MLFLOW_TRACKING_URI` injection on created pods |
| `images/jupyterlab/Dockerfile` | Pre-bake `polars`, `dask`, `qdrant-client`, `llama-index`, `torch`, `transformers`, `peft` & `QDRANT_URL` |
| `scripts/transfer-images-proxmox.sh` | Include `interactive-jupyter:latest` side-loading into `ai-worker1` K3s `containerd` |
| `scripts/init-storage.sh` | Seed `starter_labs/` into `/mnt/storage/projects/project1/starter_labs/` with `1001:2001` ownership |
| `templates/projects/project1/starter_labs/01_hello_sandbox.ipynb` | Starter Lab 01: Sandbox orientation, UID/GID & Slurm job script |
| `templates/projects/project1/starter_labs/02_data_processing_polars.ipynb` | Starter Lab 02: Out-of-core ETL with Polars & Dask |
| `templates/projects/project1/starter_labs/03_experiment_tracking_mlflow.ipynb` | Starter Lab 03: Experiment tracking & artifacts with central MLflow |
| `templates/projects/project1/starter_labs/04_llm_inference_and_rag.ipynb` | Starter Lab 04: RAG pipeline with LlamaIndex, live Qdrant & vLLM fallback |
| `templates/projects/project1/starter_labs/05_gpu_lora_finetuning.ipynb` | Starter Lab 05: PyTorch PEFT LoRA fine-tuning & MLflow checkpoint logging |
| `scripts/verify-starter-labs.sh` | Gate C locked end-to-end verification probe for WP14-B |

## Implementation Plan (Bundled for Gate A+B)
1. **Portal Env Wiring (`portal/session_manager.go` & `portal/session_manager_test.go`):**
   - Add `{Name: "QDRANT_URL", Value: "http://qdrant.services.svc.cluster.local:6333"}` to the session container environment in `CreateSession`.
2. **Pre-Baked JupyterLab Image (`images/jupyterlab/Dockerfile` & `scripts/transfer-images-proxmox.sh`):**
   - Update `images/jupyterlab/Dockerfile` to install CPU-friendly PyTorch plus `polars`, `dask[dataframe]`, `pyarrow`, `qdrant-client`, `llama-index-core`, `llama-index-vector-stores-qdrant`, `llama-index-llms-openai-like`, `transformers`, `peft`, and `mlflow`.
   - Rebuild `interactive-jupyter:latest` and import into `ai-worker1` K3s `containerd` (`k8s.io` namespace).
3. **Starter Curriculum Notebooks & Seeding (`templates/projects/project1/starter_labs/`, `scripts/init-storage.sh`):**
   - Author the 5 structured `.ipynb` (nbformat v4) notebooks with markdown explanations and executable code cells.
   - Update `scripts/init-storage.sh` and sync the notebooks into `/mnt/storage/projects/project1/starter_labs/` owned by `1001:2001`.
4. **Verification Suite (`scripts/verify-starter-labs.sh`):**
   - Author the locked verification script testing pre-baked imports, VFS read-only boundaries, and headless execution (`jupyter nbconvert --to notebook --execute`) of all 5 notebooks inside a non-root `workload` pod.

## Acceptance criteria
1. **Happy Path (Pre-Baked SDK Imports & Headless Execution of All 5 Starter Labs):**
   - Given `interactive-jupyter:latest` cached on `ai-worker1` and the 5 notebooks seeded under `/mnt/storage/projects/project1/starter_labs/`,
   - When a non-root student pod (`UID 1001`, `GID 2001`) in the `workload` namespace imports the pre-baked SDKs (`polars`, `dask`, `qdrant_client`, `llama_index`, `mlflow`, `torch`, `transformers`, `peft`) and executes all 5 notebooks headlessly (`jupyter nbconvert --to notebook --execute`),
   - Then all 5 notebooks execute to completion (`exit 0`) with zero runtime `pip install` invocations.
2. **Failure/Boundary Rejection (Read-Only Dataset/Model Mounts & Network Isolation Preserved):**
   - Given the student pod running in `workload` with scoped `subPath` mounts (`datasets` and `models` mounted `readOnly: true`),
   - When a process inside the pod attempts to write or mutate files inside `/mnt/storage/datasets` or `/mnt/storage/models` or connect directly to backend PostgreSQL (`mlflow-postgres.services.svc.cluster.local:5432`),
   - Then the Linux kernel rejects the file writes with `EROFS (Errno 30: Read-only file system)` and the CNI `NetworkPolicy` drops the TCP connection to port `5432`.
3. **Integration Contract (Live Central MLflow, Live Qdrant & Portal Session Env):**
   - Given `portal/session_manager.go` creating a session pod and Labs 02–05 executing in `workload`,
   - When the notebooks interact with cluster services and storage,
   - Then `CreateSession` injects both `MLFLOW_TRACKING_URI` and `QDRANT_URL`, Lab 02 writes transformed Parquet to `/mnt/storage/scratch`, Lab 03 & Lab 05 create verified experiment runs in `http://mlflow.services.svc.cluster.local:5000`, and Lab 04 indexes and queries vectors in `http://qdrant.services.svc.cluster.local:6333`.

## Open questions
- None. All 3 strategic decisions resolved by Khem during Phase 1 Inception.

## Test / Verification plan (Locked at Gate C)
- **Stage 1 (Fast Cloud / Static & Unit Checks):**
  - `cd portal && go test -v -race ./...`
  - `bash -n scripts/verify-starter-labs.sh scripts/init-storage.sh scripts/transfer-images-proxmox.sh`
- **Stage 2 (In-Cluster Verification Probe):**
  - `bash scripts/verify-starter-labs.sh` (9 automated assertions verifying portal unit tests, seeded notebooks & POSIX `1001:2001` ownership, pre-baked SDK imports, `EROFS` read-only dataset/model protection + Postgres 5432 block, and headless execution of Labs 01, 02, 03, 04, and 05 against live cluster storage, MLflow, and Qdrant).

## Bolt log
- 2026-11-13: Phase 1 Inception (`analyze-gap`) completed; 3 strategic decisions resolved by Khem. Created branch `feat/wp14b`, drafted `docs/aidlc/units/wp14b.md`, and completed `audit-spec` review.
