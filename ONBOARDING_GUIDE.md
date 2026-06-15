# 🏛️ AI Sandbox — Architectural Overview Guide

> **Target Audience:** A second-year Computer Engineering student with a basic understanding of Docker, web development stacks, and machine learning.
>
> **Goal:** To thoroughly understand the architecture, data flows, and design choices of the AI Sandbox project across structured phases of learning, without getting lost in fine-grained command-line details or implementation syntax.

---

## 🗺️ System Overview & Design Philosophy

The AI Sandbox is built to solve a multi-tenant resource scheduling problem: **How do we allow hundreds of students to run heavy, containerized ML workloads (JupyterLab, PyTorch, etc.) on shared hardware with GPUs, without manual administrative overhead or security compromises?**

To solve this, the system merges two different technologies:
1. **Kubernetes (K8s):** Excellent for running long-running, stateless services (the web portal, databases, reverse proxies, and operators).
2. **Slurm:** Excellent for scheduling heavy, batch-oriented compute jobs (queuing, priorities, fair-share scheduling, and allocating physical GPUs to specific users).

Instead of using a traditional bare-metal Slurm cluster, we use **Slinky (Slurm on Kubernetes)** to run Slurm *inside* Kubernetes. This gives us the best of both worlds: K8s manages the infrastructure lifecycles, and Slurm schedules the workloads.

---

## 🗓️ Phases of Learning

| Phase | Focus | Architectural Concept | Key Files to Read |
| :--- | :--- | :--- | :--- |
| **Phase 1** | **Infrastructure & Storage Topology** | Multi-node Kind clusters, Persistent Storage mapping, and K8s-to-Slurm orchestration layers. | [README.md](file:///home/khemi/workspace/ai_sandbox/README.md), [slinky_migration_report.md](file:///home/khemi/workspace/ai_sandbox/slinky_migration_report.md) |
| **Phase 2** | **Networking, Routing & Control Plane** | The request-response lifecycle, JWT propagation, dynamic port lease databases, and Traefik reverse-proxy routing. | [main.go](file:///home/khemi/workspace/ai_sandbox/portal/main.go), [port_manager.go](file:///home/khemi/workspace/ai_sandbox/portal/port_manager.go) |
| **Phase 3** | **Verification & Fault-Tolerance Models** | System validation architecture, state recovery mechanisms, and multi-user isolation design. | [verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh), [values.yaml](file:///home/khemi/workspace/ai_sandbox/values.yaml) |

---

## 🗂️ Phase 1: Infrastructure & Storage Topology

In this phase, we focus on the foundation layer: how hardware is virtualized and how storage is shared across the stack.

### 1. The Virtualized Topology (Local Development)
For local development, we run the entire cluster on a single machine using **Kind (Kubernetes in Docker)**.
- **Topology:** Kind spawns 3 Docker containers that pretend to be independent Kubernetes virtual servers (nodes): `control-plane`, `worker-1`, and `worker-2`.
- **Namespace Separation:** We partition the cluster services into logical workspaces:
  - `default`: Holds the web portal database and testing utilities.
  - `slinky`: Holds the operator that monitors the state of Slurm daemons.
  - `slurm`: Holds the actual Slurm controller (`slurmctld`), REST API daemon (`slurmrestd`), and the compute workers (`slurmd`).

### 2. Storage Architecture & Shared Directories
ML workloads require quick access to massive datasets, and students need their code and Jupyter notebooks to persist. We use a single shared directory mapped across all layers:

```
┌────────────────────────────────────────────────────────┐
│                      Your Laptop                       │
│  Files stored locally at: ./storage/                   │
└──────────────────────────┬─────────────────────────────┘
                           │ Mapped via Kind (kind-config.yaml)
                           ▼
┌────────────────────────────────────────────────────────┐
│                  Kubernetes Node VM                    │
│  Mounted inside K8s Nodes at: /mnt/storage/            │
└──────────────────────────┬─────────────────────────────┘
                           │ Defined by PV (pv-pvc.yaml)
                           ▼
┌────────────────────────────────────────────────────────┐
│            PersistentVolume (slinky-storage-pv)        │
│  K8s abstraction representing the cluster-wide storage │
└──────────────────────────┬─────────────────────────────┘
                           │ Bound by PVC (pv-pvc.yaml)
                           ▼
┌────────────────────────────────────────────────────────┐
│        PersistentVolumeClaim (slinky-storage-pvc)      │
│  Mountable resource requested by individual Pods       │
└──────────────────────────┬─────────────────────────────┘
                           │ Mount Path: /mnt/storage/
                           ▼
┌────────────────────────────────────────────────────────┐
│          Slurm Controller & Compute Pods               │
│  All containers read/write to the same shared directory │
└────────────────────────────────────────────────────────┘
```

#### Shared Directory Layout
Under `/mnt/storage/`, we enforce a strict directory structure:
- `/common/software/`: Global applications (like JupyterLab). Contains their Apptainer container images (`.sif`) and a `manifest.yaml` describing how the portal should run them.
- `/common/kaggle_cache/`: Shared ML datasets (read-only for students to avoid duplicating disk space).
- `/projects/{project_name}/`: Private workspace for each student group where their training outputs, custom code, and job logs reside.

### 3. The Orchestration Bridge (Slinky)
Running Slurm inside K8s introduces a mapping problem: K8s thinks of containers as temporary, while Slurm expects compute nodes to have static hostnames and long-term identities.
- **slurm-operator:** A K8s controller that reads [values.yaml](file:///home/khemi/workspace/ai_sandbox/values.yaml) and translates K8s configurations into running Slurm components.
- **NodeSets:** A Slinky custom resource definition that acts like a K8s Deployment but is customized for Slurm worker nodes. If a worker pod crashes, the operator automatically recreates it and registers it back to the Slurm controller.

---

## ⚡ Phase 2: Network Routing & The Control Plane

In this phase, we trace the communication flow. How does an action on the UI turn into a running ML job, and how does the user connect to it?

### 1. The Dynamic Routing Loop
When a user launches an interactive tool like JupyterLab, it runs on an arbitrary port inside a Slurm compute pod. We cannot expose this port directly to the public internet for security and routing reasons. Instead, we use **Traefik** as a reverse proxy that dynamically reconfigures itself.

Here is the architectural loop for exposing an active job:

```
 ┌──────────────┐      1. Submit Job       ┌────────────────┐
 │  Go Portal   ├─────────────────────────►│   slurmrestd   │
 └──────┬───────┘                          └────────┬───────┘
        │                                           │ 2. Schedule
        │                                           ▼
        │                                  ┌────────────────┐
        │                                  │  Compute Node  │
        │                                  │  (slurmd Pod)  │
        │                                  └────────┬───────┘
        │                                           │
        │                                           │ 3. Allocate Port
        │ 4. Update SQLite                          ▼ (HTTP POST)
        │    & Write Traefik Route         ┌────────────────┐
        └──────────────────────────────────┤  /allocate_port│
                                           └────────────────┘
```

1. **Job Submission:** The Go Portal translates the user's web request into a batch job script and POSTs it to `slurmrestd`.
2. **Execution:** The Slurm controller schedules the job on a worker node. The container starts.
3. **Port Reservation:** The container doesn't know its final route. It calls the portal's `/allocate_port` API.
4. **Proxy Reconfiguration:** The Portal's `PortManager` leases a unique port (from a 30000–31000 pool), writes this lease to a SQLite database, and generates a routing configuration file. Traefik detects the file update and creates a route mapping `https://portal/proxy/{job_id}/` to the compute node's IP and port.

### 2. Authentication & Token Propagation
Security must be maintained from the browser all the way to the scheduler.
- **Go Portal:** Authenticates the user and signs a **JWT (JSON Web Token)** containing the user's username (`sun`) and group/project (`prj`).
- **Token Passing:** When the portal calls `slurmrestd`, it forwards this JWT in the `X-SLURM-USER-TOKEN` header.
- **Slurm Controller:** Validates the JWT signature. Slurm then runs the job under the user's operating system identity, ensuring they cannot read other projects' files in the shared `/projects/` folder.

---

## 🛡️ Phase 3: Verification & Fault-Tolerance Models

In this phase, we analyze how the system verifies itself and handles failures.

### 1. System Resilience & Fault Tolerance
A production infrastructure cluster must handle failures gracefully. The verification suite [verify-infrastructure.sh](file:///home/khemi/workspace/ai_sandbox/scripts/verify-infrastructure.sh) verifies three core architectural properties:

- **State Persistence (Disaster Recovery):**
  - *Scenario:* The main Slurm controller pod (`slurm-controller-0`) crashes or is killed.
  - *Expectation:* Current and queued jobs must not be lost.
  - *Architecture:* The controller continuously dumps its state to the shared PV. When a new pod restarts, Slinky mounts the same PV, reloads the state, and resumes scheduling without interrupting active compute runs.
- **Parallel Scheduling:**
  - *Expectation:* Multiple compute pods must run jobs simultaneously without locking the shared storage files.
  - *Architecture:* Storage is mounted with `ReadWriteMany` (RWX) permissions, allowing concurrent file writing from multiple physical nodes.
- **Tenant Isolation:**
  - *Expectation:* Student A must not be able to read or modify Student B's code or datasets.
  - *Architecture:* Slurm maps JWT identities to Linux Unix UIDs inside the container runtime, enforcing standard filesystem permissions on `/projects/projectX/`.

### 2. Understanding the Development Workflow
Before starting features:
- Read [DEVELOPMENT_WORKFLOW.md](file:///home/khemi/workspace/ai_sandbox/DEVELOPMENT_WORKFLOW.md) to understand branch naming conventions (`feature/*`, `agent/*`) and PR processes.
- Read [INCREMENT_LOG.md](file:///home/khemi/workspace/ai_sandbox/INCREMENT_LOG.md) to see a diary of recent architectural decisions.
- Read [work_packages.md](file:///home/khemi/workspace/ai_sandbox/work_packages.md) to understand which work package is assigned to you and how your contributions fit into the roadmap.
