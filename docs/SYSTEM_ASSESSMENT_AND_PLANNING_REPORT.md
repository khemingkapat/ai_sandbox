# AI Sandbox: System Assessment & Planning Report

**Target Audience:** Computer Engineering Department Leadership, IT Operations Staff, and Project Stakeholders.  
**Purpose:** A comprehensive, single-source-of-truth document defining the physical infrastructure, workload capacity limits, and validated technology stack for the university AI Sandbox.

---

## Executive Summary

The AI Sandbox is engineered to support a 50–100 student cohort performing a mix of interactive AI prototyping, data preprocessing, and deep learning model training. To satisfy the competing demands of educational environments—specifically, the need for immediate interactive access versus the necessity of long-running batch training—the architecture standardizes on **Slinky (Slurm-on-Kubernetes)**. 

This hybrid architecture combines the elasticity and cloud-native container ecosystem of Kubernetes with the rigorous hardware queueing and fair-share scheduling algorithms of Slurm. Furthermore, the architecture minimizes the administrative overhead of the Sandbox by offloading Identity Management and Telemetry Storage directly to existing University IT systems.

---

## 1. Environment & Infrastructure Topology

The Sandbox utilizes a hybrid physical cluster mapped directly to Kubernetes NodeSets, deliberately bridging physical bare-metal hardware boundaries with container orchestration.

### 1.1 Physical Hardware Mapping
*   **Compute Nodes (CPU):** 5x Physical Nodes (Intel Xeon E5, 32-Core, 256GB RAM). These nodes host interactive Jupyter sessions, data preprocessing pipelines, and portal management services.
*   **Accelerator Nodes (GPU):** 1x Physical Node (AMD EPYC, 256GB RAM) featuring 2x NVIDIA L40 (48GB VRAM) GPUs.
    *   **GPU #1 (Dedicated):** Strictly hosts the persistent LLM Inference API for all student applications.
    *   **GPU #2 (Shared):** Time-sliced among students for queued interactive prototyping and batch fine-tuning workloads.

### 1.2 Storage Infrastructure & Identity
To prevent cross-tenant data contamination and avoid massive hardware storage costs, the storage layer relies on dynamic volume provisioning and static Read-Only mounts.

*   **Student Isolation (Dynamic PVCs):** The system strictly rejects legacy OS-level UID mapping. Authentication is delegated to the central university **Authentik OIDC** server. Upon successful login, the Go Portal dynamically provisions a Kubernetes Persistent Volume Claim (PVC) via an enterprise NFS provisioner, ensuring a student's Jupyter Pod is strictly hardware-isolated from other users at the volume level.
*   **Dataset Sharing (Read-Only Global Mount):** To prevent 100 students from duplicating massive 50GB AI models into their personal home directories, large shared datasets are mounted across all pods as `ReadOnlyMany` (ROX). This saves immense storage space while completely preventing accidental data deletion.

---

## 2. Capacity Planning & Workload Quotas

Supporting a 100-student cohort on 5 CPU nodes requires strict resource overcommitting. Because interactive student coding sessions are idle >90% of the time, the architecture employs a **3:1 CPU and 2:1 Memory overcommit strategy**. 

GPU resources cannot be safely overcommitted. They are fenced using Slurm partition limits to prevent Out-Of-Memory (OOM) crashes and queue starvation.

### 2.1 Partition Design & Quality of Service
*   **`interactive` Partition:** Preemption is DISABLED to protect active student code state. Jobs are strictly capped at 2 hours, 4 CPUs, 16GB RAM, and max 8GB VRAM slices on the shared GPU.
*   **`batch-cpu` Partition:** Medium priority queue for long-running (24h) data prep jobs running on the CPU cluster (Max 16 CPUs, 64GB RAM).
*   **`batch-gpu` Partition:** Medium priority queue for heavy deep learning (Max 7 Days). Strictly fenced to a 24GB VRAM cap to ensure 50% of the shared GPU remains instantly available for `interactive` workloads.
*   **`inference` Partition:** Highest priority, persistent allocation specifically for GPU #1 to ensure 24/7 central API availability.

### 2.2 Workload Profile Catalog
The following resource limits define the hard caps applied to individual student jobs.

| Workload Type | Run Mode | CPU | Memory | GPU (L40) | Duration | Tool Stack |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Interactive Prototyping** | Interactive | 4 Cores | 8 GB | None | 2 Hours | JupyterLab, VS Code |
| **Data Preprocessing** | Batch | 8 Cores | 32 GB | None | 24 Hours | Pandas, Dask, Polars |
| **Small Model Fine-Tuning** | Interactive | 4 Cores | 16 GB | 8GB VRAM Limit | 2 Hours | PyTorch, QLoRA |
| **Heavy Batch Training** | Batch | 16 Cores | 64 GB | 24GB VRAM Limit | 7 Days | PyTorch, Accelerate |
| **Central LLM API** | Service | 4 Cores | 32 GB | 1x Dedicated GPU | Persistent | Triton |

---

## 3. Technology Stack & Architecture Decisions

This section evaluates and justifies the specific software tools selected for the AI Sandbox. The selected technologies (**Option A** in all tables) are designed to minimize administrative overhead, maximize hardware throughput, and provide a stable student experience.

### 3.1 Container Runtime Strategy
**Decision: Native OCI-Only Execution via Slinky `slurm-bridge`**
*   **Rationale:** We transition completely away from legacy HPC Apptainer (Singularity) models. All workloads (both interactive notebooks and batch training scripts) will run natively as OCI containers (Docker) scheduled by Slurm via `slurm-bridge`. This eliminates complex container-in-container nesting, streamlines the Portal's codebase, and allows students to use standard Dockerfiles.

### 3.2 LLM Inference Runtime (Dual-Engine Strategy)
**Decision: Triton for Central Service (Option A), vLLM for Student Pods (Option B)**
Because the cluster supports both a massive shared API and individual student model testing, no single inference engine is optimal for both. We deploy a Dual-Engine strategy based on the workload target.

| Evaluation Criterion | Option A: NVIDIA Triton (TensorRT-LLM) | Option B: vLLM | Option C: Ollama |
| :--- | :--- | :--- | :--- |
| **Throughput & Concurrency** | **Absolute Maximum:** Squeezes peak hardware utilization via pre-compiled TensorRT engines. Outperforms vLLM at massive concurrency scales on L40 GPUs. | **Very High:** Achieved via continuous batching and PagedAttention. Excellent for mixed concurrent workloads. | **Moderate:** Excellent for single-user prototyping; struggles to scale throughput under heavy parallel requests. |
| **Setup & UX Complexity** | **Extremely High:** Models cannot be run instantly; they must be Ahead-of-Time (AOT) compiled into TRT engines specific to the L40 architecture. | **Moderate:** Requires python environments, configuration of engine args, and manual port routing. | **Extremely Low:** Single binary, automatic model downloading with zero config. |
| **Role in Sandbox** | **Central Inference API (GPU #1):** IT Admins absorb the heavy AOT compilation penalty to guarantee maximum concurrency for the 100-student API. | **Student Custom Pods (GPU #2):** Mandatory for students testing custom fine-tunes on demand. Dynamic HuggingFace loading means no AOT compilation is required. | **Rejected:** Cannot scale to multi-tenant loads effectively. |

### 3.3 Vector Database
**Decision: Qdrant deployed as a Centralized Service (Option A)**

| Evaluation Criterion | Option A: Qdrant | Option B: Milvus |
| :--- | :--- | :--- |
| **K8s Deploy Complexity** | **Extremely Simple:** Single binary deployed as a standard stateful set. | **Highly Complex:** Distributed architecture requiring multiple sidecars (ZooKeeper, MinIO, Pulsar). |
| **Memory Footprint** | **Low (~3GB RAM for 1M vectors):** Highly optimized Rust engine. | **High (8GB+ RAM):** High JVM/Go runtime overhead even for small-scale datasets. |
| **Rationale** | Deploying a central Qdrant service provides high-speed sub-millisecond retrieval while keeping memory footprints low, avoiding the IOPS penalty of local disk databases. | Powerful but massive overkill for a sandbox environment, causing high memory drain. |

### 3.4 RAG Orchestration Framework
**Decision: LlamaIndex (Option A)**

| Evaluation Criterion | Option A: LlamaIndex | Option B: LangChain |
| :--- | :--- | :--- |
| **Core Paradigm** | **Data & Search Centric:** Deeply specialized in ingestion, parsing, chunking, and querying. | **Agent & Workflow Centric:** Designed for multi-agent chains and sequential tools. |
| **Abstraction Level** | **High:** Allows students to build a full functional RAG pipeline in under 10 lines of code. | **Low-to-Medium:** Often requires verbose boilerplate code to accomplish simple RAG tasks. |
| **Rationale** | Superior choice for teaching strict RAG concepts cleanly, with highly stable APIs for data connections. | Rejected as the primary RAG tool; its generalized agent focus introduces unnecessary complexity for foundational RAG. |

### 3.5 ML Training & Fine-Tuning Stack
**Decision: NVIDIA NGC PyTorch with DaemonSet Pre-Puller (Option A)**

| Evaluation Criterion | Option A: NVIDIA NGC PyTorch | Option B: Upstream Docker Hub PyTorch | Option C: Custom Built Image |
| :--- | :--- | :--- | :--- |
| **CUDA Completeness** | **Pre-configured:** Built-in, hyper-optimized libraries (cuDNN, FlashAttention-2) for L40 GPUs. | **Basic:** Requires manual student installation of acceleration layers. | **Manual Compilation:** High effort to match vendor optimizations. |
| **Image Size** | **Very Large (15GB+):** Massive footprints due to vendor package inclusion. | **Moderate (6GB–8GB):** Standard runtime size. | **Optimized (4GB–6GB):** Customized layers. |
| **Rationale** | The NGC base ensures deep CUDA optimizations, saving students from compiler errors. To mitigate the massive 15GB image size, we deploy a K8s DaemonSet that forces the image to be permanently cached on all physical nodes, yielding guaranteed sub-5-second pod startups. | | |

### 3.6 Data Pipeline Framework
**Decision: Single-Node Dask & Polars (Option A)**

| Evaluation Criterion | Option A: Dask (Single-Node) / Polars | Option B: Apache Spark / Ray Data |
| :--- | :--- | :--- |
| **Scalability & Scope** | **Node-Bound:** Excellent for standard large datasets using streaming and in-memory partitions. | **Multi-Node Enterprise:** Designed for petabyte-scale distributed HDFS clusters. |
| **Deployment Complexity** | **None:** Runs inside standard Python runtimes within the student's isolated Jupyter Pod. | **Extremely High:** Requires Spark K8s Operators, YARN, and heavy JVM overhead. |
| **Rationale** | Massive multi-node datasets (>100GB) are rare in the curriculum. Bundling Single-Node Dask and Polars gives students robust ETL tools without crushing the cluster with JVM overhead. | |

### 3.7 Container Image Strategy
**Decision: Pre-baked OCI Image "Colab Model" (Option A)**

| Evaluation Criterion | Option A: Pre-baked OCI Image per Job Type | Option B: Single Base Image + Runtime Conda |
| :--- | :--- | :--- |
| **Pod Startup Latency** | **Fast (Cached):** Kubernetes nodes cache layers; pods launch in under 5 seconds. | **Extremely Slow:** Dynamic Conda resolution over NFS can take 5–15 minutes. |
| **Storage Overhead** | **Medium:** Requires hosting a secure container registry. | **High (Metadata):** Hundreds of thousands of tiny Conda files destroy NFS metadata IOPS. |
| **Rationale** | A Google Colab-style pre-baked image guarantees sub-5-second startup times. We explicitly reject NFS-backed Conda environments to protect the cluster filesystem from metadata thrashing. Obscure dependencies are handled via ephemeral `!pip install`. | |

### 3.8 GPU Sharing Mechanism
**Decision: Kubernetes GPU Time-Slicing (Option A)**  
*(Note: Pending final license review by University IT).*

| Evaluation Criterion | Option A: Kubernetes GPU Time-Slicing | Option B: NVIDIA vGPU |
| :--- | :--- | :--- |
| **VRAM Isolation** | **Soft:** Shares VRAM concurrently via round-robin. Relies on Slurm partitioning limits. | **Strict (Hard):** Allocates guaranteed hardware partitions preventing noisy neighbors. |
| **Licensing** | **Free:** Native to open-source NVIDIA GPU Operator. | **Commercial License:** Requires enterprise hypervisor licensing. |
| **Rationale** | Selected due to zero licensing cost and simple K8s ConfigMap deployment. We protect the hardware from OOM crashes by strictly capping student jobs at 8GB VRAM slices via Slurm `MaxTRESPerJob`. | |

### 3.9 Monitoring & Observability
**Decision: Remote Exporters Only (Option A)**

| Evaluation Criterion | Option A: Remote Exporters (DCGM, Node, Slurm) | Option B: Full Local Prometheus / Grafana Stack |
| :--- | :--- | :--- |
| **Resource Footprint** | **Extremely Low:** Exposes raw metrics via lightweight daemonsets. | **Massive:** Time-series databases require significant dedicated RAM. |
| **Rationale** | The Sandbox explicitly **rejects** running a local Prometheus database. Instead, lightweight exporters will serve metrics, allowing the University's Central Management Portal to scrape and store the data remotely, saving all local RAM for student workloads. | |

---

## Conclusion
The AI Sandbox architecture provides a highly resilient, isolated, and scalable environment for university-scale AI curriculum. By leveraging Slinky, strict capacity quotas, and a deeply optimized OCI-native software stack, the platform guarantees fair access to expensive GPU resources while maintaining the cloud-native agility required for modern ML engineering.
