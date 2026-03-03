# Slurm Docker Cluster — Local HPC Simulation

A self-contained, multi-node Slurm HPC cluster running entirely in Docker containers. Designed for local development, testing, and platform design work without requiring physical compute nodes.

---

## Project Structure

```
.
├── docker-compose.yml        # Defines all services (slurmctld + workers)
├── Dockerfile.slurm          # Custom image built on Rocky Linux 9
├── docker-entrypoint.sh      # Entrypoint script handling both controller and worker modes
├── data/
│   └── slurm.conf            # Slurm cluster configuration
└── test_jobs.sh              # Test job scripts
```

---

## Architecture Overview

```
┌───────────────────────────────────────────────────────┐
│               Docker Bridge Network                   │
│                  slurm_net                            │
│                                                       │
│  ┌────────────┐    ┌────────┐  ┌────────┐  ┌────────┐ │
│  │ slurmctld  │◄──►│worker1 │  │worker2 │  │worker3 │ │
│  │ (controller│    │(slurmd)│  │(slurmd)│  │(slurmd)│ │
│  │  port 6817)│    └────────┘  └────────┘  └────────┘ │
│  └────────────┘                                       │
└───────────────────────────────────────────────────────┘

Shared Volumes:
  etc_munge     → /etc/munge     (shared munge key across all nodes)
  slurm_state   → /var/spool/slurmctld  (controller state persistence)
  slurm_jobdir  → /data          (shared job working directory)
```

The cluster consists of one **controller node** (`slurmctld`) and three **worker nodes** (`worker1`, `worker2`, `worker3`), all running the same `local-slurm:latest` image but differentiated by the command passed at startup (`slurmctld` vs `slurmd`).

---

## Design Choices

### Base Image — Rocky Linux 9

Rocky Linux 9 was chosen as the base because it is binary-compatible with RHEL 9, which is the standard OS for most HPC environments. Slurm 22.05 is available directly from the EPEL repository with no manual compilation required.

We deliberately avoided `slaclab/slurm-docker` despite it being a Slurm 22.05 image, because it was built specifically for SLAC's on-premise infrastructure — it ships with a hardcoded `slurm.conf` enforcing LDAP authentication, accounting storage with `associations,limit,qos`, and tries to connect to SLAC's internal LDAP servers on startup. None of this is overridable by a bind-mounted config because supervisord loads the baked-in config before our volume mount takes effect.

### Single Shared Image

All nodes (controller and workers) are built from the same `Dockerfile.slurm`. The `command:` field in `docker-compose.yml` (`slurmctld` vs `slurmd`) is what differentiates their behavior at runtime via the entrypoint script. This keeps the image simple and avoids maintaining separate Dockerfiles.

Only `slurmctld` has the `build:` block in `docker-compose.yml`. Workers reference `image: local-slurm:latest` directly. This prevents a Docker BuildKit conflict where parallel builds of the same image tag collide and fail with `image already exists`.

### Munge Authentication

Munge is the standard authentication mechanism for Slurm. All nodes must share the **same munge key** — if each container generates its own key independently, Slurm daemons will silently reject each other's connections.

The key is generated once inside the `slurmctld` container at first startup using `/sbin/create-munge-key` (baked into the image), then persisted and shared to all worker containers via the `etc_munge` named volume mounted at `/etc/munge`. Workers wait for the key file to appear before starting `munged`.

### TCP Port Readiness Wait

Workers use a bash TCP probe to wait for slurmctld to be ready before launching slurmd:

```bash
until bash -c ">/dev/tcp/slurmctld/6817" 2>/dev/null; do
    sleep 2
done
```

This is more reliable than a fixed `sleep` because it checks actual TCP connectivity on port 6817, meaning slurmd will never try to register with a controller that isn't listening yet.

### Cgroup v1 Instead of v2

Slurm 22.05 on Rocky Linux 9 defaults to the `cgroup/v2` plugin, which requires a running dbus daemon (`/run/dbus/system_bus_socket`) to create systemd scopes for job step processes. Dbus is part of systemd and is not available inside plain Docker containers.

Both `cgroup_v1.so` and `cgroup_v2.so` are present in the image. We force v1 by writing `CgroupPlugin=cgroup/v1` into `/etc/slurm/cgroup.conf` inside the worker entrypoint before slurmd starts. The file is written at runtime (not bind-mounted) because a bind-mounted read-only file cannot be overwritten, and a named volume mount would shadow the directory entirely.

Additional settings in `slurm.conf` that reduce cgroup dependency:

- `ProctrackType=proctrack/linuxproc` — uses `/proc` for process tracking instead of cgroup
- `TaskPlugin=task/none` — disables task affinity features that would otherwise invoke cgroup

### Node State — UNKNOWN

Nodes are configured with `State=UNKNOWN` in `slurm.conf` instead of `State=CLOUD`. `CLOUD` tells slurmctld to call a `ResumeProgram` script to "power on" nodes on demand. Since our worker containers are always running alongside slurmctld, we use `UNKNOWN` which allows slurmd to self-register with the controller on startup without any power management callbacks.

### No Accounting Storage

`AccountingStorageType=accounting_storage/none` and `JobAcctGatherType=jobacct_gather/none` are set to disable the accounting subsystem entirely. Enabling accounting requires a running `slurmdbd` (Slurm Database Daemon) backed by a MySQL/MariaDB database. This is out of scope for a local simulation cluster and was the cause of the `AccountingStorageEnforce invalid` fatal errors seen with the original SLAC image.

### Shared Job Directory

All nodes share `/data` via the `slurm_jobdir` named volume. This simulates a shared filesystem (like NFS or Lustre in a real HPC cluster) so that job scripts submitted from the controller are accessible on worker nodes when they execute.

---

## Prerequisites

- Docker
- Docker Compose (v2 — used as `docker compose`, not `docker-compose`)

---

## Setup & Usage

### 1. Build the image

```bash
docker compose build
```

This builds `local-slurm:latest` from `Dockerfile.slurm` using Rocky Linux 9. Takes approximately 2–3 minutes on first build; subsequent builds use the layer cache.

### 2. Start the cluster

```bash
docker compose up -d
```

This starts all four containers (`slurmctld`, `worker1`, `worker2`, `worker3`) in detached mode.

### 3. Verify the cluster is healthy

```bash
# Wait ~10 seconds for workers to register, then:
docker exec slurmctld sinfo
```

Expected output:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite      3   idle worker[1-3]
```

If nodes show `down` or `unk`, check worker logs:
```bash
docker logs worker1
```

### 4. Submit jobs

```bash
# Run hostname on 2 nodes interactively
docker exec slurmctld srun -N2 hostname

# Run hostname on all 3 nodes
docker exec slurmctld srun -N3 hostname

# Run 6 parallel tasks across 2 nodes
docker exec slurmctld srun -N2 -n6 hostname

# Submit a batch job
docker exec slurmctld sbatch --wrap="sleep 3 && hostname" -N2 --job-name=my_job

# Check job queue
docker exec slurmctld squeue

# Run all test jobs at once (copy test_jobs.sh to data/ first)
docker exec slurmctld bash /data/test_jobs.sh
```

### 5. Stop the cluster

```bash
# Stop containers but keep volumes (preserves munge key and state)
docker compose down

# Stop and remove everything including volumes (full reset)
docker compose down -v
```

---

## Configuration Reference

### slurm.conf — Key Parameters

| Parameter | Value | Reason |
|---|---|---|
| `AuthType` | `auth/munge` | Standard Slurm authentication |
| `ProctrackType` | `proctrack/linuxproc` | Avoids cgroup dependency for process tracking |
| `TaskPlugin` | `task/none` | Disables task affinity, no cgroup needed |
| `AccountingStorageType` | `accounting_storage/none` | No slurmdbd or database required |
| `SuspendTime` | `-1` | Disables power management entirely |
| `State` | `UNKNOWN` | Allows slurmd to self-register on startup |
| `CommunicationParameters` | `NoAddrCache` | Forces DNS re-lookup every time, fixes DNS race conditions in Docker |

### cgroup.conf — Key Parameters

Written at runtime inside each worker container by `docker-entrypoint.sh`:

| Parameter | Value | Reason |
|---|---|---|
| `CgroupPlugin` | `cgroup/v1` | Forces v1 plugin; v2 requires dbus which is unavailable in containers |
| `CgroupAutomount` | `yes` | Mounts cgroup filesystem automatically |
| `ConstrainCores` | `no` | No CPU pinning needed for local simulation |
| `ConstrainRAMSpace` | `no` | No memory limits needed for local simulation |

---

## Troubleshooting

**Nodes stuck in `down` state after startup**
```bash
docker logs worker1   # check for munge or slurmd errors
docker exec slurmctld scontrol update nodename=worker1 state=resume
```

**Munge authentication errors**
```bash
docker compose down -v   # wipe volumes to regenerate munge key
docker compose up -d
```

**CPU mismatch error (`Node configuration differs from hardware`)**

Edit `slurm.conf` and update the `NodeName` line to match your host's CPU topology. Check your actual hardware with:
```bash
docker exec worker1 slurmd -C
```
Then update `CPUs=`, `CoresPerSocket=` accordingly.

**Full reset**
```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d
```
