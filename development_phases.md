# Phase 1 — Environment & Storage Foundation

## Overview

Phase 1 sets up the core Slurm cluster with a shared storage structure visible across all nodes, mimicking an NFS filesystem. This is the foundation everything else builds on.

---

## Design Decisions

### What we build on: giovtorres/slurm-docker-cluster

Rather than building and maintaining our own Slurm Docker image, we pull directly from [giovtorres/slurm-docker-cluster](https://github.com/giovtorres/slurm-docker-cluster) on Docker Hub. This gives us:

- Slurm 25.11.x built from source (latest stable)
- Full accounting stack: MySQL + slurmdbd (needed for Phase 5 job tracking)
- REST API via slurmrestd with JWT authentication on port 6820 (needed for Phase 5 backend)
- Apptainer (Singularity) pre-installed on all worker nodes (needed for Phase 2)
- Dynamic worker registration — workers self-register as `c1`, `c2`, etc. and can be scaled up/down without rebuilding

We do not maintain a Dockerfile. If giovtorres releases a bug fix or new Slurm version, we just update `SLURM_VERSION` in `.env` and pull the new image.

### What we add on top

The only thing we add is the shared storage layer. giovtorres uses named Docker volumes which are opaque — you can't browse them from your host machine. We replace the storage directories with bind-mounts pointing to `./storage/` in this repo, so files are visible and editable directly from the host.

```
./storage/users/     → /mnt/storage/users    (per-user home directories)
./storage/projects/  → /mnt/storage/projects (shared project files)
./storage/public/    → /mnt/storage/public   (public datasets)
```

These mounts are applied to every container — slurmctld and all workers — so a file placed in `./storage/users/user1/` is accessible from any node the job runs on.

### Entrypoint override

We override the entrypoint on `slurmctld` only with a small wrapper (`docker-entrypoint.sh`) that initializes the storage directory permissions on first boot, then hands off to giovtorres's original entrypoint for all Slurm startup logic:

```bash
mkdir -p /mnt/storage/users /mnt/storage/projects /mnt/storage/public
chown -R 990:990 ...   # 990 is the slurm system user UID inside the container
exec /usr/local/bin/docker-entrypoint.sh "$@"
```

---

## Repository Structure

```
ai_sandbox/
├── docker-compose.yml        # pulls giovtorres image, adds storage mounts
├── docker-entrypoint.sh      # storage init wrapper (10 lines)
├── .env.example              # configuration template
├── .env                      # your local config (not committed)
├── jobs/                     # job scripts
│   └── sleep_test.sh
└── storage/                  # mock NFS — visible on host and all nodes
    ├── users/
    ├── projects/
    └── public/
```

---

## First-Time Setup

### 1. Clone and configure

```bash
git clone <your-repo>
cd ai_sandbox
cp .env.example .env
```

Edit `.env` if needed — the defaults work fine for a local machine:

```env
CPU_WORKER_COUNT=2   # increase if you want more compute nodes
GPU_ENABLE=false     # leave false unless you have an NVIDIA GPU
```

### 2. Create storage directories

Docker won't create these automatically:

```bash
mkdir -p storage/users storage/projects storage/public
```

### 3. Make entrypoint executable

```bash
chmod +x docker-entrypoint.sh
```

### 4. Start the cluster

```bash
docker compose up -d
```

Wait about 30 seconds, then verify the cluster is up:

```bash
docker exec slurmctld sinfo
```

Expected output:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
cpu*         up   infinite      2   idle c[1-2]
```

---

## User Management

Slurm has its own accounting system separate from the Linux user system. You need to create a user in both places.

### Slurm accounting hierarchy

```
cluster (linux)
  └── organization account (e.g. cpe)
        └── project account (e.g. project1)
              └── user (e.g. user1)
```

### Create the hierarchy

```bash
docker exec slurmctld bash
```

Inside the container:

```bash
# create org and project accounts
sacctmgr add account cpe description="CPE Organization"
sacctmgr add account project1 parent=cpe description="Project 1"

# create the user under the project
sacctmgr add user user1 account=project1

# verify
sacctmgr show associations
```

Exit the container:
```bash
exit
```

### Create the Linux user on every node

Slurm also needs the user to exist as a real Linux user on each node so it can run jobs under that identity. UID must match across all nodes — we use 1000.

```bash
docker exec slurmctld useradd -m -u 1000 user1
docker exec ai_sandbox-cpu-worker-1 useradd -m -u 1000 user1
docker exec ai_sandbox-cpu-worker-2 useradd -m -u 1000 user1
```

If you have more workers, repeat for each one (`ai_sandbox-cpu-worker-3`, etc.).

---

## Copying Files Into the Cluster

### Option A — via shared storage (recommended)

Place files directly into `./storage/` on your host. They are immediately visible on all nodes at `/mnt/storage/`:

```bash
cp myfile.txt storage/users/user1/
```

Inside any container it appears at `/mnt/storage/users/user1/myfile.txt`.

### Option B — copy into /data (job working directory)

Use `docker cp` to copy into the shared job directory:

```bash
docker cp jobs/sleep_test.sh slurmctld:/data/sleep_test.sh
```

Then fix ownership so user1 can access it:

```bash
docker exec slurmctld chown user1:user1 /data/sleep_test.sh
docker exec slurmctld chmod +x /data/sleep_test.sh
```

---

## Submitting Jobs

### Basic job script

```bash
#!/bin/bash
#SBATCH --job-name=sleep_test
#SBATCH --output=/data/sleep_test_%j.out
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:01:00

echo "Job started at $(date)"
echo "Running on nodes: $SLURM_NODELIST"
echo "Submitted by: $(whoami)"

srun bash -c 'echo "Task running as $(whoami) on $(hostname) at $(date)" && sleep 10 && echo "Done as $(whoami) on $(hostname)"'
```

Note: inside `srun bash -c`, use single quotes so that `$(whoami)` and `$(hostname)` are evaluated on the worker at runtime, not on the controller at submission time.

### Submit as a specific user

```bash
docker exec slurmctld sbatch --uid=user1 /data/sleep_test.sh
```

### Monitor the job

```bash
# watch the queue
docker exec slurmctld squeue

# watch only user1's jobs
docker exec slurmctld squeue -u user1
```

### Read the output

```bash
docker exec slurmctld bash -c "cat /data/sleep_test_*.out"
```

Expected output with 2 nodes × 2 tasks:
```
Job started at Sun Mar 22 08:44:17 UTC 2026
Running on nodes: c[1-2]
Submitted by: user1
Task running as user1 on c1 at Sun Mar 22 08:44:17 UTC 2026
Task running as user1 on c1 at Sun Mar 22 08:44:17 UTC 2026
Task running as user1 on c2 at Sun Mar 22 08:44:17 UTC 2026
Task running as user1 on c2 at Sun Mar 22 08:44:17 UTC 2026
Done as user1 on c1
Done as user1 on c1
Done as user1 on c2
Done as user1 on c2
```

---

## Cluster Management

```bash
# stop the cluster (keeps all data and volumes)
docker compose down

# full reset — wipes all volumes including the database
docker compose down -v

# scale workers up or down
docker compose up -d --scale cpu-worker=4

# view logs
docker compose logs -f slurmctld
```

---

## Known Gotchas

**`whoami` returns a UID number instead of a username**
The Linux user doesn't exist on that node yet. Run `useradd -m -u 1000 user1` on the affected worker.

**All tasks land on one node instead of spreading across both**
Usually means the user doesn't exist on one of the workers. Create the user on all worker nodes with matching UID.

**`slurmdbd.conf: No such file or directory` on first start**
The `etc_slurm` named volume is empty and shadowing the configs baked into the image. Run `docker compose down -v` and start again.

**Files copied in have wrong ownership**
Run `docker exec slurmctld chown user1:user1 /data/<filename>` after copying.
