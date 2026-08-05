# AI Sandbox: Staging Environment Specification

**Purpose:** This document defines the bare-metal VM request for the Staging/Integration environment. It is designed to validate the Slinky (Slurm-on-Kubernetes) architecture, GPU time-slicing, and NFS integrations before moving to the full production scale defined in the `SYSTEM_ASSESSMENT_AND_PLANNING_REPORT.md`.

## 1. Staging Topology Overview

To properly test multi-node scheduling, parallel workloads, and proper control plane isolation, the staging environment utilizes a 4-node topology:

- **1x Management Node:** Dedicated to Kubernetes control plane, Traefik, and Slurm controllers.
- **2x CPU Worker Nodes:** To validate parallel job scheduling (e.g., Slurm dispatching a job across multiple nodes).
- **1x GPU Worker Node:** To validate NVIDIA GPU Operator time-slicing and inference workloads.
- **1x NFS Share:** To validate dynamic student storage provisioning.

## 2. Virtual Machine Request Specs

### 2.1 Management / Control Plane Node (1x VM)
- **Role:** Kubernetes API, etcd, Traefik Ingress, Slurmctld, Go Portal.
- **Specs:** 4 Cores, 16 GB RAM, 100 GB Local SSD
- **Rationale:** No student workloads run here. Forcing management services onto a dedicated node ensures they can communicate over the network with workers properly, uncovering any networking/DNS issues missed in a single-node `kind` cluster.

### 2.2 CPU Worker Nodes (2x VMs)
- **Role:** `slurmd` workers executing `interactive` and `batch-cpu` jobs.
- **Specs (per VM):** 8 Cores, 32 GB RAM, 100 GB Local SSD
- **Rationale:** Having *two* nodes is critical for testing parallel workloads and ensuring Slurm's multi-node scheduling works correctly. 8 cores provides enough headroom to test 3:1 CPU overcommit logic.

### 2.3 GPU Worker Node (1x VM)
- **Role:** Testing Triton/vLLM inference APIs and time-sliced student training jobs.
- **Specs:** 8 Cores, 32 GB RAM, 100 GB Local SSD
- **GPUs Attached:** 1x (or 2x) NVIDIA T4, A10G, or L40 (passed through via PCIe).
- **Rationale:** Essential for validating that Kubernetes can pass GPUs to pods and that Slurm respects the 8GB VRAM chunk limits. A physical GPU is required to test the NVIDIA GPU Operator's time-slicing configuration.

### 2.4 Shared Storage
- **Role:** Student home directories and shared datasets.
- **Specs:** 500 GB NFS Share
- **Rationale:** Validates the `nfs-subdir-external-provisioner`. Ensures jobs dynamically create and mount private sub-directories correctly.

## 3. Security Requirements

Since these bare-metal VMs will be accessible over the internet:
1. **No Public Control Plane:** Do NOT expose the Kubernetes API (port 6443) or Slurm RPC ports to the public internet.
2. **Access via VPN:** Administrative access should require a VPN (e.g., Tailscale, WireGuard, or University VPN).
3. **Web Gateway:** Only expose HTTP/HTTPS (80/443) via the Traefik Ingress Controller for testing the Portal UI.
