# Interactive Tutorial Module List: AI Sandbox Learning Track

> **Status:** Draft / Proposed Module Outline  
> **Target Environment:** Localized AI Sandbox (Inside user container / compute node)  
> **Prerequisites:** Completion of Central Portal Quickstart / Demo Pod

---

## 🎯 Architectural Intent & Scope

Following the findings in [interactive_tutorial_feasibility.md](file:///home/khemi/workspace/ai_sandbox/docs/interactive_tutorial_feasibility.md), this 10-module curriculum is designed exclusively for the **Localized AI Sandbox** environment. It teaches students how to use the hybrid Kubernetes + Slurm (Slinky) + Apptainer infrastructure safely without causing multi-tenant resource starvation, storage IOPS collapse, or orphaned compute jobs.

---

## 📋 The 10 Interactive Tutorial Modules

1. **Module 1: Sandbox Orientation & Shared Storage Topography**
   - **Focus:** Understanding filesystem tiers: `/projects/{project_name}` (persistent project workspace), `/common/software` (pre-built container images), `/common/kaggle_cache` (read-only shared datasets), and local node scratch space.
   - **Hands-on Task:** Inspect environment variables, verify quota limits, and distinguish persistent mounts from ephemeral container filesystems.

2. **Module 2: Slurm Cluster Topology & Inspection via Slinky**
   - **Focus:** Understanding how Slurm operates inside Kubernetes. Exploring partitions, node states, and cluster capacity.
   - **Hands-on Task:** Query partition availability using `sinfo`, inspect the active queue with `squeue`, and check fair-share priorities.

3. **Module 3: Rootless Container Execution with Apptainer**
   - **Focus:** Why Docker is restricted in multi-tenant HPC and how Apptainer provides secure, rootless container isolation.
   - **Hands-on Task:** Run commands inside a pre-built PyTorch `.sif` image using `apptainer exec` and explore an interactive container shell using `apptainer shell`.

4. **Module 4: Hardware Acceleration & GPU Allocation**
   - **Focus:** GPU topology, generic resources (`--gres=gpu:X`), NVIDIA container runtime integration, and the Apptainer `--nv` flag.
   - **Hands-on Task:** Allocate a GPU node, run `nvidia-smi` inside the Apptainer container, and verify PyTorch detects the CUDA device.

5. **Module 5: Interactive Sessions vs. Headless Jobs (`salloc` & `srun`)**
   - **Focus:** The role of interactive debugging sessions versus batch processing. Preventing idle interactive allocations that hoard cluster resources.
   - **Hands-on Task:** Request a bounded interactive allocation using `salloc`, run a step with `srun`, and observe automatic teardown on timeout.

6. **Module 6: Production Batch Workloads with `sbatch`**
   - **Focus:** Anatomy of an HPC batch submission script: resource directives (`#SBATCH`), memory allocation (`--mem`), CPU cores (`--cpus-per-task`), walltime limits (`--time`), and log file capture (`--output`, `--error`).
   - **Hands-on Task:** Author an `sbatch` script for an asynchronous model training run, submit it to the queue, and verify job decoupling from the local terminal.

7. **Module 7: Storage I/O Hygiene & Dataset Staging**
   - **Focus:** Avoiding shared network storage IOPS exhaustion during high-throughput ML dataloading. Understanding the penalty of small-file random reads on shared mounts.
   - **Hands-on Task:** Benchmark reading a dataset directly from `/common/kaggle_cache` versus staging it to node-local scratch/RAM disk before training.

8. **Module 8: Interactive Web Services & Dynamic Reverse Proxy Routing**
   - **Focus:** How the Sandbox exposes web-based IDEs (JupyterLab) through dynamic port leases and Traefik reverse-proxy routing without public port mapping.
   - **Hands-on Task:** Launch a headless JupyterLab instance inside a Slurm allocation, verify port binding via the local lease database, and access the session securely via its proxy URL.

9. **Module 9: Job Lifecycle Monitoring, Accounting & Remediation**
   - **Focus:** Diagnosing job states, understanding accounting logs, identifying resource bottlenecks, and cleaning up runaway workloads.
   - **Hands-on Task:** Inspect a running job with `scontrol show job`, query historical resource usage with `sacct`, and terminate a stuck or rogue job using `scancel`.

10. **Module 10: Fault Tolerance, Preemption & Checkpointing**
    - **Focus:** Surviving walltime cutoffs, node reboots, and Kubernetes `OOMKilled` (Exit Code 137) events. Implementing robust checkpoint/resume patterns.
    - **Hands-on Task:** Trigger an intentional job walltime timeout, verify automated checkpoint persistence to `/projects/{project_name}/checkpoints`, and resume training seamlessly from the saved state.
