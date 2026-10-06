# Interactive Tutorial Curriculum: AI Sandbox Practical Workloads

> **Status:** Active Specification  
> **Target Audience:** Students, Researchers, and AI Practitioners  
> **Environment:** Localized AI Sandbox (Compute Pods & Interactive Workspaces)  
> **Prerequisites:** Central Portal Login (Authentik SSO) & Basic Linux / Python Fluency  

---

## 🎯 Curriculum Overview & Learning Objectives

This curriculum trains students and researchers on the practical capabilities of the AI Sandbox platform. Rather than dealing with backend cluster administration, learners focus on executing real-world AI/ML workloads—navigating the storage hierarchy, managing compute lifecycles, and integrating with high-throughput shared AI acceleration infrastructure.

By completing this track, learners will be able to:
1. **Work within Platform Guardrails:** Understand private vs. shared storage tiers, resource quotas, and pre-baked optimized container images.
2. **Develop Interactively:** Launch and use containerized web IDEs (JupyterLab, VS Code) and command-line compute sessions (`salloc`) with GPU acceleration.
3. **Execute Scalable Batch Workloads:** Submit asynchronous data preprocessing (`batch-cpu`) and resilient deep learning training runs (`batch-gpu`) using Slurm (`sbatch`).
4. **Leverage Shared AI Infrastructure:** Integrate applications with the Central LLM Inference API, construct vector pipelines with Qdrant, and perform parameter-efficient fine-tuning (PEFT/QLoRA) on shared GPUs.
5. **Serve Custom Models:** Deploy and query private on-demand inference endpoints using vLLM.

---

## 📋 Tutorial Modules

### 🧭 Phase 1: Platform Orientation & User Environment

1. **Module 1: Orientation, Storage Tiers & Student Quotas**
   - **Concepts:** Understanding storage isolation in a multi-tenant sandbox. Differentiating private persistent home storage (`/projects/{project_name}` or `/home/{user}`), read-only shared datasets (`/mnt/shared_datasets`), pre-baked container caches, and node-local scratch space. Understanding quota caps (50 GB storage, 3 concurrent jobs, 8 vCPUs, 32 GB RAM, 8 GB vGPU slice).
   - **Hands-on Task:** Inspect environment variables, verify disk quotas using system tools, verify read permissions on `/mnt/shared_datasets`, and write temporary files to node scratch.

2. **Module 2: Container Environments & The Pre-Baked Image Catalog**
   - **Concepts:** Why the sandbox utilizes pre-baked OCI images (instant pod initialization, avoiding shared storage metadata contention from dynamic package installs). Using standard interactive environments vs. batch execution runtimes. Proper package management guidelines (`pip install --user`) for session-specific dependencies.
   - **Hands-on Task:** Launch a container shell using the pre-baked NVIDIA NGC PyTorch environment, inspect available hardware with `nvidia-smi` and `torch.cuda.is_available()`, and verify pre-installed acceleration libraries (FlashAttention-2, BitsAndBytes).

---

### 💻 Phase 2: Interactive Development & Prototyping

3. **Module 3: Launching Interactive Workspaces (JupyterLab & VS Code)**
   - **Concepts:** Interactive session architecture: pod creation via `slurm-bridge`, authenticated URL routing via Traefik reverse proxy, and session duration enforcement (2-hour default limit) to maintain cluster availability.
   - **Hands-on Task:** Launch an interactive JupyterLab instance from the portal, access the workspace securely via the generated proxy URL, create a Python notebook, and verify access to the allocated GPU slice.

4. **Module 4: Interactive Compute Allocations (`salloc` & CLI Debugging)**
   - **Concepts:** Interactive terminal sessions and debugging directly on compute nodes without consuming login node resources. Fair resource allocation hygiene: releasing allocations when inactive.
   - **Hands-on Task:** Request a bounded interactive GPU allocation using `salloc -p interactive --gres=gpu:1 --time=00:30:00`, execute interactive Python debugging steps with `srun`, monitor live execution, and terminate the session.

---

### 🚀 Phase 3: Batch Execution & Scalable Pipelines

5. **Module 5: Submitting Batch Data Preprocessing Jobs (`batch-cpu`)**
   - **Concepts:** Writing batch submission scripts: partition selection (`batch-cpu`), core counts (`--cpus-per-task`), memory allocation (`--mem`), walltime limits, and log capture (`--output`, `--error`). Utilizing single-node Polars and Dask for out-of-core data transformations within container memory limits.
   - **Hands-on Task:** Write an `sbatch` script that processes a multi-gigabyte dataset stored in `/mnt/shared_datasets` using Polars and writes preprocessed features to personal persistent storage.

6. **Module 6: GPU Batch Training & Checkpointing (`batch-gpu`)**
   - **Concepts:** Submitting long-running model training jobs (up to 24 GB VRAM, 7-day walltime). Designing fault-tolerant workflows that survive walltime limits or node maintenance through checkpoint/resume routines.
   - **Hands-on Task:** Submit an `sbatch` job running a PyTorch training loop on `batch-gpu`. Inspect stdout/stderr log output, check job status using `squeue`, and confirm model checkpoint persistence in `/projects/{project_name}/checkpoints`.

7. **Module 7: Job Lifecycle Management & Troubleshooting**
   - **Concepts:** Tracking job execution, analyzing accounting records, diagnosing common job failures (`OOMKilled` exit code 137, time limits, unmet hardware constraints), and terminating stalled workloads.
   - **Hands-on Task:** Inspect live job details with `scontrol show job`, query historical resource metrics using `sacct`, and safely terminate an active job with `scancel`.

---

### 🤖 Phase 4: Applied AI & Shared Services Workloads

8. **Module 8: Querying the Central LLM Inference API & Building RAG with Qdrant**
   - **Concepts:** Leveraging shared cluster services: querying the high-throughput Central LLM API (dedicated NVIDIA L40) and connecting to the centralized Qdrant vector database via OpenAI-compatible endpoints.
   - **Hands-on Task:** In a Jupyter environment, connect to the shared Central LLM API endpoint. Ingest documents into the centralized Qdrant instance using LlamaIndex, perform semantic retrieval, and execute a full Retrieval-Augmented Generation (RAG) query.

9. **Module 9: Parameter-Efficient Fine-Tuning (PEFT / QLoRA)**
   - **Concepts:** Fine-tuning large language models within the student interactive GPU envelope (8 GB VRAM cap). Applying 4-bit quantization (BitsAndBytes), Low-Rank Adaptation (LoRA), and gradient checkpointing to avoid memory overflow.
   - **Hands-on Task:** Execute a QLoRA fine-tuning script on a domain-specific dataset, monitor VRAM consumption with `nvidia-smi` to ensure adherence to the 8 GB quota, and save the resulting LoRA adapter weights to personal storage.

10. **Module 10: Hosting Custom Fine-Tuned Models (On-Demand vLLM Server)**
    - **Concepts:** Exposing custom-trained adapters using an on-demand, private vLLM serving pod. Maintaining endpoint portability: how private serving instances expose the same OpenAI-compatible REST API format as the central inference service.
    - **Hands-on Task:** Launch a private vLLM server hosting the LoRA adapter produced in Module 9, query the model endpoint via `curl` and Python OpenAI client requests, verify streaming generation, and gracefully shut down the service pod.


