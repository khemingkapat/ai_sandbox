# Tech Stack & Architecture Decisions

> **📋 System Assessment Report**
> This document is part of the System Assessment & Planning Report:
> - [Environment Assessment](./ENVIRONMENT_ASSESSMENT.md) — Hardware, architecture, and deployment topology
> - [Capacity Planning](./CAPACITY_PLANNING.md) — Workload profiles, partitions, and resource quotas
> - **[Tech Stack Decisions](./TECH_STACK_DECISION.md)** — Technology choices and architectural decision records

This document records the core technology stack and architectural decisions for the AI Sandbox, mapping the flow from the user to the physical HPC cluster via the Slinky scheduling suite.

## 1. Reference Architecture

```mermaid
architecture-beta
    group cluster(logos:kubernetes)[Physical HPC K8s Cluster]
    
    service browser(logos:chrome)[Student Browser]
    service traefik(logos:traefik)[Traefik Ingress] in cluster
    
    service portal(logos:go)[Go Portal] in cluster
    service slurmctld(logos:linux-tux)[Slinky / Slurm Controller] in cluster
    
    service jupyter(logos:jupyter)[Jupyter / Interactive Pods] in cluster
    service batch(logos:docker)[Batch Training Pods] in cluster
    
    service nfs(logos:linux-tux)[Enterprise NFS Storage]

    browser:R --> L:traefik
    traefik:B --> T:portal
    
    portal:R --> L:slurmctld
    slurmctld:B --> T:jupyter
    slurmctld:B --> T:batch
    
    traefik:B --> T:jupyter
    
    nfs:T --> B:jupyter
    nfs:T --> B:batch
```

## 2. Core Stack Decisions

### Workload Scheduling & Orchestration: Slinky (Slurm-on-Kubernetes)
*   **Decision:** Use Slinky to bridge Kubernetes and Slurm.
*   **Rationale:** Allows us to leverage Kubernetes for infrastructure management (elastic scaling, OCI images) while maintaining Slurm's superior fair-share and GRES (Generic Resource) scheduling logic for university multi-tenancy.

### Ingress & Routing: Traefik
*   **Decision:** Use Traefik as the Ingress Controller.
*   **Rationale:** Standard, robust solution. Traefik handles dynamic session proxying perfectly (e.g., routing `/proxy/job-123` to a specific dynamically spun-up Jupyter pod) without needing to write custom reverse-proxy logic in the Go Portal.

### Middle Tier: Go Portal
*   **Decision:** Use a custom Go-based portal.
*   **Rationale:** Go is highly performant. The portal will orchestrate API calls to `slurmrestd` and manage the creation of Traefik dynamic routes for interactive sessions. 

### Interactive Environment: Jupyter / VS Code Pods
*   **Decision:** Run Jupyter/VS Code as interactive Slurm jobs within K8s Pods.
*   **Rationale:** Provides instant web-based access to compute.

### Development Environments (Local vs. Prod)
*   **Decision:** `kind` (Kubernetes in Docker) and `Nix` are restricted strictly to local development and reproducible builds.
*   **Rationale:** Local dev simulates the cluster (using `hostPath` for storage). Production will run on the physical bare-metal nodes (Intel Xeons + NVIDIA L40s).

## 3. Storage Layer & Identity Isolation

### Storage Infrastructure: Standard NFS with Subdir Provisioner
*   **Decision:** We will deploy the `nfs-subdir-external-provisioner` (Kubernetes CSI) pointing to a standard Linux NFS server.
*   **Rationale:** This provisioner allows Kubernetes to automatically carve out individual directories on the NFS server whenever a new student logs in, treating them as independent volumes.

### Identity & Isolation: Cloud-Native Dynamic PVCs
*   **Decision:** We are dropping OS-level UID mapping (`libnss-extrausers`). Instead, we will use OIDC/SSO at the Go Portal level. The Portal will instruct Kubernetes to dynamically provision a unique Persistent Volume Claim (PVC) for each student's home directory.
*   **Rationale:** This completely sidesteps the nightmare of syncing LDAP/UIDs across ephemeral pods. From the pod's perspective, it just mounts a volume to `/home/jovyan` (or similar). Kubernetes and the NFS provisioner handle the isolation at the volume level.

### Dataset Sharing: Global Read-Only Mount
*   **Decision:** We will create a single, static Persistent Volume (PV) for shared datasets (e.g., massive AI models, training data).
*   **Rationale:** Every Slinky/Jupyter pod will mount this volume as `ReadOnlyMany` (ROX) at a path like `/mnt/shared_datasets`. This prevents students from accidentally deleting or modifying shared data, while avoiding the cost of duplicating datasets into each student's private directory.
