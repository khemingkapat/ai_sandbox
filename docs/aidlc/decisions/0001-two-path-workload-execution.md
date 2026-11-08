# 0001 — Two-Path Workload Execution Model

Date: 2026-10-19  
Status: accepted  
Supersedes: Legacy SSH / direct Docker container execution

## Context
The AI Sandbox supports two fundamentally different student workload types:
1. **Interactive Workloads:** Long-running web sessions (JupyterLab, VS Code, Bash TTYD) requiring persistent HTTP/WebSocket routing, authentication, and ingress proxying.
2. **Batch HPC Workloads:** Scheduled compute jobs (multi-node CPU MPI, GPU model training/evaluation) requiring queuing, preemption, fair-share allocation, and non-interactive execution.

Attempting to run interactive web servers inside standard Slurm batch allocations caused port collision issues, complex reverse-proxy tunnels, and inefficient resource allocation. Conversely, running multi-node batch HPC jobs natively in standard Kubernetes without an HPC scheduler led to poor queue management and lack of fairshare accounting.

## Decision
Adopt a **Two-Path Dispatcher Architecture**:
1. **Interactive Path:** Interactive workspaces run as native Kubernetes OCI Pods in the `workload` namespace. The Go portal creates the `Pod`, `Service`, and Traefik `Ingress` dynamically with ForwardAuth middleware.
2. **Batch Path:** Batch workloads execute as Slurm jobs managed by Slinky (`slurmctld`). Batch job scripts execute software environments encapsulated as unprivileged Apptainer (`.sif`) containers streaming directly from `/mnt/storage`.
3. **Bridge & Accounting:** `slurm-bridge` annotates and registers Kubernetes interactive Pods into Slurm for unified resource tracking and fairshare accounting.

## Consequences
- **Positive:** Interactive sessions get instant HTTP/WebSocket ingress via Traefik without SSH port forwarding. Batch jobs leverage Slurm's multifactor priority algorithms and GRES GPU scheduling.
- **Negative:** Requires maintaining two container formats (OCI images for interactive tools, Apptainer `.sif` definitions for batch jobs).
- **Trigger for Revisiting:** If SchedMD Slinky provides transparent, native OCI-native batch scheduling directly via Kubernetes CRDs without requiring separate Apptainer encapsulation.
