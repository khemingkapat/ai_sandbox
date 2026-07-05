# WP3-1-2: Capacity Planning & Workload Profiling

This document outlines the workload profiling, partition design, resource quotas, and autoscaling configurations required to support a fair multi-user AI engineering environment for students.

---

## 📋 Workload Profile Catalog

Students run a diverse set of tasks ranging from basic notebook execution to intensive deep learning training runs. Below is the catalog of profiled workload types:

| Workload Type | Run Mode | CPU Resources | Memory | GPU Resources | Duration Limit | Typical Tool / Executable |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Interactive Prototyping** | Interactive | 2 Cores | 8 GB | None | 4 Hours | JupyterLab, VS Code, Bash |
| **Small Model Training** | Interactive | 4 Cores | 16 GB | 1x NVIDIA L4 (shared/mig) | 4 Hours | PyTorch, JupyterLab |
| **LLM Inference Server** | Interactive | 4 Cores | 32 GB | 1x NVIDIA L40S or L4 | 12 Hours | Ollama, vLLM, Qdrant |
| **Vector DB Setup** | Interactive | 2 Cores | 8 GB | None | 12 Hours | Qdrant, Milvus |
| **Heavy Batch Training** | Batch | 16 Cores | 64 GB | 2x or 4x NVIDIA H100 | 7 Days | `sbatch` (Python training script) |
| **Data Preprocessing** | Batch | 8 Cores | 32 GB | None | 24 Hours | `sbatch` (Pandas, Spark) |

---

## 🧩 Partition Design

We define four distinct Slurm/Slinky partitions to isolate workloads and prioritize resources appropriately.

```mermaid
gantt
    title Partition Access & Priority Schedule
    dateFormat  HH:mm
    axisFormat %H:%M
    
    section interactive
    Student Coding/Testing :active, 00:00, 04:00
    
    section batch-cpu
    CPU Batch Tasks        :active, 00:00, 24:00
    
    section batch-gpu
    Heavy Deep Learning    :active, 00:00, 48:00
    
    section inference
    LLM API Servers        :active, 00:00, 12:00
```

1.  **`interactive` (Default):**
    *   **Purpose:** Live student environments (Jupyter, VS Code).
    *   **Scheduling Priority:** High (preemption enabled over batch if cluster is full).
    *   **Max Job Duration:** 4 hours.
    *   **Resource Limits:** Max 4 CPUs and 16GB RAM per job.
2.  **`batch-cpu`:**
    *   **Purpose:** Long-running CPU data prep or non-GPU model training.
    *   **Scheduling Priority:** Medium.
    *   **Max Job Duration:** 24 hours.
    *   **Resource Limits:** Max 16 CPUs and 64GB RAM per job.
3.  **`batch-gpu`:**
    *   **Purpose:** Deep learning training runs requiring high GPU performance.
    *   **Scheduling Priority:** Medium.
    *   **Max Job Duration:** 7 days.
    *   **Resource Limits:** Max 4 GPUs, 16 CPUs, and 64GB RAM per job.
4.  **`inference`:**
    *   **Purpose:** Hosted LLM/embedding inference services.
    *   **Scheduling Priority:** High.
    *   **Max Job Duration:** 12 hours.
    *   **Resource Limits:** Max 1 GPU (typically L4/L40S) and 32GB RAM per job.

---

## 🔒 Resource Quotas Per Student/Project

To prevent a single student or project group from monopolizing the physical cluster, we enforce limits at the user level:

*   **Student (Individual Sandbox):**
    *   **Max Concurrent Jobs:** 3
    *   **Max CPU Cores (Total):** 8
    *   **Max Memory (Total):** 32 GB
    *   **Max GPUs (Total):** 1 (Interactive or Batch)
    *   **Shared Storage Quota:** 50 GB per user
*   **Project Group (Collaborative Research):**
    *   **Max Concurrent Jobs:** 10
    *   **Max CPU Cores (Total):** 32
    *   **Max Memory (Total):** 128 GB
    *   **Max GPUs (Total):** 4
    *   **Shared Storage Quota:** 200 GB per project

---

## 📈 Autoscaling Policy

To balance energy efficiency/cloud costs with student waiting times, the worker nodes (implemented as Slinky `NodeSets`) follow an elastic autoscaling policy:

```mermaid
graph TD
    Queue[Slurm Job Queue] -->|Pending Job Detected| Decider{Queue > 5 mins or Resource Starved?}
    Decider -->|Yes| ScaleOut[Scale NodeSet: Increase Replicas]
    Decider -->|No| Keep[Maintain Replica Count]
    
    NodeUsage[Node Usage] -->|Idle > 15 mins| ScaleIn[Scale NodeSet: Decrease Replicas]
```

### 1. CPU NodeSet (`slurmd-cpu`)
*   **Minimum Replicas:** 1 (always on to handle portal requests and basic tasks immediately).
*   **Maximum Replicas:** 8 (prevents cluster resource starvation).
*   **Scale-Out Trigger:** Queue pending time > 2 minutes for interactive jobs.
*   **Scale-In Trigger:** Node idle time > 15 minutes (graceful shutdown of worker pod).

### 2. GPU NodeSet (`slurmd-gpu`)
*   **Minimum Replicas:** 0 (scale-to-zero model when no GPU workloads are queued).
*   **Maximum Replicas:** 4 (limits expensive GPU compute overhead).
*   **Scale-Out Trigger:** Any pending job targeting the `batch-gpu` or `inference` partitions.
*   **Scale-In Trigger:** Node idle time > 10 minutes.
