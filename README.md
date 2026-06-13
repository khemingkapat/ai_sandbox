# AI Sandbox — Slinky HPC Kubernetes Prototype

A self-contained, multi-node Slurm HPC cluster running on a local Kubernetes (**Kind**) cluster using **Slinky** (SchedMD's official Slurm-on-Kubernetes suite). Designed for local development, testing, and platform design work for the AI Sandbox, without requiring physical compute nodes.

This prototype implements a **Kubernetes-native storage isolation** pattern, mapping the host-level `storage/` directory directly to compute pods via PersistentVolume (PV) and PersistentVolumeClaim (PVC) configurations. It bypasses complex LDAP/SSSD directory synchronization setups in favor of native Kubernetes directory-level mount isolation.

---

## Project Structure

*   [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml) — Defines the multi-node Kind cluster and mounts host-level storage.
*   [pv-pvc.yaml](file:///home/khemi/workspace/ai_sandbox/pv-pvc.yaml) — Configures the PersistentVolume and claim to link the mounted host storage.
*   [values.yaml](file:///home/khemi/workspace/ai_sandbox/values.yaml) — Helm configuration values for Slinky components (operator, controller, NodeSets).
*   [flake.nix](file:///home/khemi/workspace/ai_sandbox/flake.nix) — Nix environment defining local tools (`kind`, `kubectl`, `helm`) and shell helpers.
*   [scripts/start-slinky.sh](file:///home/khemi/workspace/ai_sandbox/scripts/start-slinky.sh) — Automates Slinky CRDs, Operator, and Slurm cluster installation.
*   [storage/projects/project1](file:///home/khemi/workspace/ai_sandbox/storage/projects/project1) — Shared storage mock project directory containing test workloads.
*   [slinky_migration_report.md](file:///home/khemi/workspace/ai_sandbox/slinky_migration_report.md) — Comprehensive technical report on Slinky architecture and migration plans.
*   [DEVELOPMENT_WORKFLOW.md](file:///home/khemi/workspace/ai_sandbox/DEVELOPMENT_WORKFLOW.md) — Team development roles and Git workflows.
*   [INCREMENT_LOG.md](file:///home/khemi/workspace/ai_sandbox/INCREMENT_LOG.md) — Incremental record of design choices and verification steps.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                       Kind Cluster (Kubernetes)                 │
│                                                                 │
│   Control Plane Pods            Slurm Compute Pods (NodeSet)    │
│  ┌──────────────────┐          ┌─────────────────────────────┐  │
│  │  slurm-operator  │          │   slurm-worker-0 (slurmd)   │  │
│  │  (SchedMD CRDs)  │          │   slurm-worker-1 (slurmd)   │  │
│  └────────┬─────────┘          └──────────────┬──────────────┘  │
│           │                                   │                 │
│           ▼                                   ▼                 │
│  ┌──────────────────┐          ┌─────────────────────────────┐  │
│  │ slurm-controller │◄────────►│        /mnt/storage         │  │
│  │  (slurmctld)     │          │  (ReadWriteMany PVC Mount)  │  │
│  └──────────────────┘          └──────────────┬──────────────┘  │
└───────────────────────────────────────────────┼─────────────────┘
                                                │
                                                ▼
                                     ┌────────────────────┐
                                     │   Host Storage     │
                                     │  (./storage/)      │
                                     └────────────────────┘
```

The system runs SchedMD's official `slurm-operator` in the `slinky` namespace to orchestrate the Slurm controller (`slurm-controller-0`) and worker NodeSets as Kubernetes pods in the `slurm` namespace. 

Rather than relying on complex SSSD/LDAP user and group synchronizations, directories are isolated natively by mapping the host's [storage/](file:///home/khemi/workspace/ai_sandbox/storage) directory to the Kind nodes, which is then exposed to Slurm pods via a `ReadWriteMany` PV and PVC mount at `/mnt/storage`.

---

## Design Choices

### Slinky (Slurm-on-Kubernetes)
We migrated from manual Rocky Linux 9 containers in Docker Compose to Slinky (SchedMD's official Kubernetes suite). Slinky deploys Slurm daemons (`slurmctld`, `slurmd`, `slurmrestd`) as native Kubernetes pods managed via CRDs. This transition enables:
*   **Elastic NodeSets:** Workers are defined as Kubernetes pools that can autoscale.
*   **Kubernetes Schedulers:** Allows co-scheduling jobs natively under both Kubernetes and Slurm control.

### Kubernetes-Native Storage Isolation
We deliberately discarded the complex SSSD and OpenLDAP configuration. Configuring LDAP servers and client SSSD daemons on container runtimes adds high configuration drift risk and runtime overhead. Instead, we mount the host [storage/](file:///home/khemi/workspace/ai_sandbox/storage) directory to Kind nodes and provision a manual PersistentVolume mapping. Compute pods mount this PVC at `/mnt/storage`, allowing workspace files and execution directories to be read and written directly with simple path-based separation.

### Shared Host Directory Simulation
To simulate a multi-host network filesystem (like NFS or Lustre), we mount the local host's `./storage` folder to `/mnt/storage` on all Kind nodes (control-plane and workers) via `extraMounts` in [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml). The `pv-pvc.yaml` defines a PersistentVolume (`slinky-storage-pv`) using the `hostPath` driver targeting `/mnt/storage`, which is bound by `slinky-storage-pvc` inside the `slurm` namespace.

### Nix Flake Environment
A Nix configuration ([flake.nix](file:///home/khemi/workspace/ai_sandbox/flake.nix)) packages the correct versions of `kind`, `kubectl`, and `kubernetes-helm`, eliminating manual environment setups and configuration conflicts. It loads shell helpers automatically upon activation.

---

## Setup & Usage

### 1. Initialize the Environment
Ensure you have Nix installed, then load the developer environment shell:
```bash
nix develop
```
*This loads the required CLI tools and exposes shell aliases (`kup`, `kdown`, `kstat`, `slurm-shell`).*

### 2. Boot the Cluster & Install Slinky
To create the Kind cluster and deploy the entire Slinky stack automatically, run:
```bash
kup
```
*This command creates the cluster using [kind-config.yaml](file:///home/khemi/workspace/ai_sandbox/kind-config.yaml) and runs [scripts/start-slinky.sh](file:///home/khemi/workspace/ai_sandbox/scripts/start-slinky.sh) to deploy Slinky charts and the storage PV/PVC.*

### 3. Verify the Deployment
Confirm that your PV and PVC are correctly created and bound:
```bash
kubectl get pv,pvc -n slurm
```
Ensure both `slinky-storage-pv` and `slinky-storage-pvc` show status `Bound`.

Verify that the Slurm compute pods are running:
```bash
kstat
```

---

## Submitting Jobs (Rapid Prototype)

### 1. Access the Slurm Shell
Enter the Slurm controller container to run scheduling commands:
```bash
slurm-shell
```

### 2. Run Test Jobs
Once inside the controller shell, run standard Slurm commands to schedule and manage jobs:
```bash
# Check cluster partition status
sinfo

# Run a job interactively across 2 nodes
srun -N2 hostname

# Check the queue
squeue

# Submit a batch job pointing to the shared storage workspace
sbatch --wrap="sleep 2 && hostname" -N2 --job-name=test_job
```

### 3. Verify Mount Access inside a Compute Pod
To confirm the storage mount is active inside a compute container:
```bash
kubectl exec -n slurm -it <pod-name-from-kstat> -c slurmd -- ls -la /mnt/storage
```
Ensure you can see [projects/project1](file:///home/khemi/workspace/ai_sandbox/storage/projects/project1) and other files mapped from your local workspace.

---

## Troubleshooting

**PVC Status is Stuck in `Pending`**
Verify the PersistentVolume exists and matches the storage class:
```bash
kubectl describe pvc -n slurm slinky-storage-pvc
kubectl get pv
```
Ensure `pv-pvc.yaml` was applied. If needed, re-apply it manually:
```bash
kubectl apply -f pv-pvc.yaml
```

**Slurmd Compute Pods Fail to Register**
Verify the pods status and inspect logs for error outputs:
```bash
kstat
kubectl logs -n slurm <worker-pod-name> -c slurmd
```

**Full Environment Reset**
To completely wipe the cluster and start fresh:
```bash
kdown
kup
```

---

*For detailed comparisons of the Compose vs Kubernetes design, see [slinky_migration_report.md](file:///home/khemi/workspace/ai_sandbox/slinky_migration_report.md).*
