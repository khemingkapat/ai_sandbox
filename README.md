# AI Sandbox — Slinky Migration Prototype

This project is a rapid-prototype environment for an AI Sandbox platform. We are migrating from a manual Docker Compose setup to **Slinky (Slurm on Kubernetes)** to provide a scalable, professional HPC scheduling experience.

## The Goal

The objective is to replace our legacy SSH-based job offloading with **Slinky**, enabling:

* **Native Slurm Scheduling:** Every job gets a real Slurm job ID, whether running on CPU or GPU nodes.
* **Kubernetes Infrastructure:** Replacing manual containers with automated Kubernetes (k3s/kind) orchestration.
* **Unified Queue:** No more splitting jobs between Slurm and non-Slurm; everything is scheduled through the Slurm-on-Kubernetes integration.

## Migration Plan

| Phase | Focus | Status |
| --- | --- | --- |
| **Phase 0** | Setup local environment (Nix Flake, Kind/k3s) | [In Progress] |
| **Phase 1** | Deploy Slinky Operator and Slurm Cluster | [Testing] |
| **Phase 2** | Integrate Slurm-Bridge for non-Slurm workloads | [Planned] |
| **Phase 3** | Portal API integration (Standardizing job submission) | [Planned] |

## Getting Started (Rapid Prototype)

We use **Nix Flakes** to maintain a clean environment.

1. **Initialize the Environment:**
```bash
nix develop

```


2. **Boot the Cluster:**
This command creates a multi-node cluster and automatically installs the Slinky stack:
```bash
kup

```


3. **Manage:**
* `kstat`: Monitor your pods.
* `slurm-shell`: Enter the controller to run `sinfo` or `squeue`.
* `kdown`: Cleanly delete the prototype cluster.

---

*For more details on the architecture, see [slinky_migration_report.md].*

