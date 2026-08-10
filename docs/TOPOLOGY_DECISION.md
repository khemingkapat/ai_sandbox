# Topology & Scheduling Architecture

This document explains the physical to virtual mapping of the AI Sandbox cluster, specifically how batch jobs and interactive sessions coexist on the same worker nodes.

## 1. Batch Jobs: The Static Topology

You might wonder: *If we are using Kubernetes, why don't we just spawn a brand new Pod every time a student submits a batch training job?* 

We use a **static topology** for batch jobs (where the Slinky `slurmd` worker pods run permanently and are tied directly to the physical bare-metal servers) for three reasons:

1. **Job Scheduling Speed:** Slurm is designed to dispatch thousands of jobs per second. If it had to ask Kubernetes to spin up a new Pod, pull an image, attach network interfaces, and bind a GPU for *every single batch job*, the delay would be massive. By keeping the `slurmd` pods always running, Slurm can instantly inject batch jobs into them with zero boot-up delay.
2. **Hardware Awareness:** Heavy AI training requires exact knowledge of the physical hardware (e.g., NVLink topology between GPUs). If we use ephemeral, floating pods, Slurm loses its map of the physical motherboard. By permanently pinning the `slurmd` worker pod to a specific physical server, Slurm knows exactly what hardware it is assigning the job to.
3. **The "Virtual Bare-Metal" Trick:** Think of the static `slurmd` Pod not as a container, but as a virtual physical server. It boots up once when the cluster turns on, claims the physical GPUs on that specific node, and then sits there continuously, waiting for Slurm to send it Apptainer `.sif` batch scripts to execute.

## 2. Interactive Sessions: The Ephemeral Topology

Unlike batch jobs, **Interactive Sessions** (like JupyterLab or VS Code) *do* spawn as fresh, ephemeral Pods. 
* When a student clicks "Launch Jupyter", Slinky's `slurm-bridge` dynamically asks Kubernetes to create a brand new K8s Pod specifically for that session. 
* This ephemeral Pod is scheduled by Kubernetes wherever there is free CPU/RAM on the worker nodes. 
* Once the student shuts down their Jupyter session (or the Slurm time limit hits), that Pod is completely destroyed and the resources are freed.

## 3. Coexistence: Fencing & Overcommitting

If interactive pods are ephemeral but run on the same physical worker nodes as heavy batch jobs, how do they get scheduled if the batch jobs are consuming all the resources?

We solve the "noisy neighbor" problem through strict partitioning, guaranteeing space for interactive users:

### GPU Fencing (Hard Limits)
If we let a batch job use the whole GPU, interactive users would be blocked. We enforce a strict **Resource Fence** using Slurm's limits:
* A batch job is physically capped at **24GB of VRAM** (half of our 48GB NVIDIA L40 GPU).
* This programmatically guarantees that there is *always* 24GB of VRAM held in reserve for interactive Jupyter pods to spawn into instantly, no matter how many batch jobs are queued.

### CPU Overcommitting (Virtual Cores)
For CPU-bound work, we use an industry-standard **3:1 Overcommit Ratio**. 
* The worker nodes have 160 physical CPU cores, but we configure the cluster to expose **480 virtual cores**.
* Because interactive coding (typing, reading, debugging) uses almost zero CPU 90% of the time, we can safely stack these ephemeral interactive K8s pods on top of the batch jobs. Kubernetes simply time-slices the physical cores seamlessly. 
