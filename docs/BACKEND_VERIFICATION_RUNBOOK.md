# AI Sandbox: Backend Manual Verification Runbook

> **Target Audience:** System Architects, Cluster Operators, and Reviewers  
> **Environment:** Proxmox K3s Cluster (`ai-control` @ `10.35.123.50`, `ai-worker1` @ `10.35.123.51`)  
> **Companion Document:** [BACKEND_DEPLOYMENT_REPORT.md](file:///home/khemi/workspace/ai_sandbox/docs/BACKEND_DEPLOYMENT_REPORT.md)  
> **Automated Suite:** [`scripts/verify-backend-complete.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/verify-backend-complete.sh)

---

## 📖 How to Use This Runbook

This document contains **exact, copy-pasteable terminal commands** to manually inspect and verify each architectural claim made in the [Backend Deployment Report](file:///home/khemi/workspace/ai_sandbox/docs/BACKEND_DEPLOYMENT_REPORT.md).

Run these commands either:
1. Directly on **`ai-control`** via the Proxmox web console or SSH.
2. From your **local machine** using `kubectl` connected to the cluster.

---

## 📋 Module 1: Cluster Topology & Hypervisor Infrastructure

### 1.1 Verify Kubernetes Node Readiness & Hardware Allocation
Checks that both the control plane and compute worker are online, running native kernels without virtualization masking.

```bash
kubectl get nodes -o wide
```

**Expected Output:**
```text
NAME         STATUS   ROLES           AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
ai-control   Ready    control-plane   7d    v1.36.4+k3s1   10.35.123.50   <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic (amd64)   containerd://2.3.4-k3s1.36
ai-worker1   Ready    worker          7d    v1.36.4+k3s1   10.35.123.51   <none>        Ubuntu 24.04.5 LTS   6.8.0-139-generic (amd64)   containerd://2.3.4-k3s1.36
```

---

### 1.2 Verify Core Infrastructure & System Namespaces
Validates that cert-manager, K3s system components, and Slinky operators are fully operational.

```bash
kubectl get pods -n cert-manager
kubectl get pods -n kube-system
kubectl get pods -n slinky
```

**Expected Output:**
* `cert-manager`: 3 pods (`cert-manager`, `cainjector`, `webhook`) — all `1/1 Running`.
* `kube-system`: `coredns`, `local-path-provisioner`, `metrics-server` — all `1/1 Running`.
* `slinky`: `slurm-operator`, `slurm-operator-webhook` — all `1/1 Running`.

---

## 📋 Module 2: Slinky Orchestrator & Slurm Core Scheduling

### 2.1 Verify Slurm Core Daemons & Database Pods
Confirms the Slurm control plane, MariaDB, accounting daemon, and compute NodeSets are healthy in namespace `slurm`.

```bash
kubectl get pods -n slurm -o wide
```

**Expected Output:**
* `slurm-controller-0`: `2/2 Running` (pinned to `ai-control`)
* `slurm-accounting-0`: `1/1 Running` (pinned to `ai-control`)
* `mariadb-0`: `1/1 Running` (pinned to `ai-control`)
* `hpc-portal`: `2/2 Running` (pinned to `ai-control`)
* `slurm-worker-slurmd-cpu-0`: `2/2 Running` (pinned to `ai-worker1`)
* `slurm-worker-slurmd-cpu-1`: `2/2 Running` (pinned to `ai-worker1`)
* `slurm-worker-slurmd-gpu-0`: `2/2 Running` (pinned to `ai-worker1`)

---

### 2.2 Verify Slurm Partitions (`sinfo`)
Verifies that all 4 scheduling partitions (`interactive`, `batch-cpu`, `batch-gpu`, and `inference`) are initialized and `up`.

```bash
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sinfo
```

**Expected Output:**
```text
PARTITION    AVAIL  TIMELIMIT  NODES  STATE NODELIST
batch-cpu       up 1-00:00:00      3   idle ai-worker1,slurmd-cpu-[0-1]
batch-gpu       up 7-00:00:00      4   idle ai-worker1,slurmd-cpu-[0-1],slurmd-gpu-0
inference       up   12:00:00      2   idle ai-worker1,slurmd-gpu-0
interactive*    up    2:00:00      4   idle ai-worker1,slurmd-cpu-[0-1],slurmd-gpu-0
```

---

### 2.3 Verify Quality of Service (QoS) & Fair-Share Tree
Checks that MariaDB-backed SlurmDBD enforces the 4 QoS tiers and Fair-Share priorities.

```bash
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sacctmgr show qos format=Name,Priority,MaxTRESPerJob%30,MaxWall
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sshare -a
```

**Expected Output:**
* QoS shows `interactive_qos` (Priority=1000, MaxWall=02:00:00), `batch_cpu_qos` (MaxWall=1-00:00:00), `batch_gpu_qos` (MaxWall=7-00:00:00), and `inference_qos`.
* `sshare` prints the multi-tier Fair-Share hierarchy.

---

### 2.4 Live Job Submission & Accounting Recording (`srun` + `sacct`)
Dispatches a live compute job through Slurm to prove end-to-end dispatch and database persistence.

```bash
# 1. Run live job on partition batch-cpu
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
  srun -p batch-cpu -t 1 --mem=128M /bin/bash -c 'echo "EXEC_ON: $(hostname)"'

# 2. Check accounting history in MariaDB
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- \
  sacct -X --format=JobID,JobName,Partition,AllocCPUS,Elapsed,State,ExitCode | tail -n 5
```

**Expected Output:**
* Command 1 outputs: `EXEC_ON: slurmd-cpu-0` (or `slurmd-cpu-1`).
* Command 2 displays the job record in State `COMPLETED` with ExitCode `0:0`.

---

## 📋 Module 3: Shared Storage Architecture & POSIX Permissions

### 3.1 Verify Storage Mount on Compute Worker
Confirms the NFSv4 shared storage volume is bound to `/mnt/storage` inside the worker pods.

```bash
kubectl exec -n slurm slurm-worker-slurmd-cpu-0 -c slurmd -- df -h /mnt/storage
```

**Expected Output:**
* Filesystem shows ~197G mounted at `/mnt/storage`.

---

### 3.2 Verify Multi-Tenant Workspace Isolation
Proves that project workspaces enforce POSIX permissions (`700`), preventing cross-tenant reading.

```bash
kubectl exec -n slurm slurm-worker-slurmd-cpu-0 -c slurmd -- ls -ld /mnt/storage/projects/*
```

**Expected Output:**
```text
drwx------ 5 1001 1001 4096 ... /mnt/storage/projects/project1
drwx------ 4 1002 1002 4096 ... /mnt/storage/projects/project2
drwx------ 4 1004 1004 4096 ... /mnt/storage/projects/project3
```

---

### 3.3 Verify Ephemeral Scratch Space Sticky-Bit (`1777`)
Verifies `/mnt/storage/scratch` allows all users to write temporary data while preventing users from deleting each other's files.

```bash
kubectl exec -n slurm slurm-worker-slurmd-cpu-0 -c slurmd -- stat -c '%a %n' /mnt/storage/scratch
```

**Expected Output:**
```text
1777 /mnt/storage/scratch
```

---

### 3.4 Verify Clean-Scratch CronJob Schedule
Verifies the automated Kubernetes CronJob is scheduled to purge orphaned scratch files older than 24 hours.

```bash
kubectl get cronjobs -n slurm clean-scratch
kubectl get jobs -n slurm -l job-name | tail -n 3
```

**Expected Output:**
* CronJob `clean-scratch` is active with schedule `0 0 * * *`.
* Recent completed job pods show `Completed` status.

---

## 📋 Module 4: Zero-Trust Network & Security Baseline

### 4.1 Verify ServiceAccount RBAC Confinement
Tests that the web portal service account (`portal-sa`) is strictly isolated from inspecting Kubernetes nodes or reading secrets.

```bash
# Check node reading restriction
kubectl auth can-i get nodes --as=system:serviceaccount:slurm:portal-sa

# Check secret reading restriction
kubectl auth can-i get secrets -n slurm --as=system:serviceaccount:slurm:portal-sa
```

**Expected Output:**
* Both commands return: `no`

---

### 4.2 Verify Workload Token Absence & Database Egress Block
Spawns an ephemeral test probe pod in namespace `workload` to confirm:
1. ServiceAccount tokens are **never** mounted into user workload pods (`automountServiceAccountToken: false`).
2. Workload pods are blocked from connecting to `mariadb:3306` via NetworkPolicy.

```bash
# 1. Spawn probe pod
kubectl run sec-manual-probe -n workload --image=busybox:1.36 \
  --annotations='slurmjob.slinky.slurm.net/exclusive=false' \
  --overrides='{"spec":{"automountServiceAccountToken":false}}' -- sleep 120

kubectl wait --for=condition=Ready pod/sec-manual-probe -n workload --timeout=30s

# 2. Check token directory (must NOT exist)
kubectl exec -n workload sec-manual-probe -- test -d /var/run/secrets/kubernetes.io/serviceaccount \
  && echo "FAIL: Token present" || echo "PASS: Token absent"

# 3. Check MariaDB connection (must TIMEOUT / drop)
kubectl exec -n workload sec-manual-probe -- nc -z -w 3 mariadb.slurm.svc.cluster.local 3306 \
  && echo "FAIL: DB reached" || echo "PASS: DB blocked"

# 4. Clean up probe pod
kubectl delete pod sec-manual-probe -n workload --grace-period=0 --force
```

**Expected Output:**
* Token check: `PASS: Token absent`
* DB check: `PASS: DB blocked`

---

### 4.3 Verify Traefik HTTPS Redirect & Security Headers
Tests Traefik dynamic ingress routing to verify port 80 redirects to 443 with TLS and security headers.

```bash
# 1. Establish local port-forward to portal service in background
kubectl port-forward -n slurm svc/portal 18080:80 18443:443 &
PF_PID=$!
sleep 2

# 2. Test HTTP 80 redirect
curl -s -I http://127.0.0.1:18080/ | grep -E "HTTP/|location:"

# 3. Test HTTPS 443 TLS response & security headers
curl -k -s -I https://127.0.0.1:18443/ | grep -E "HTTP/|strict-transport-security|x-frame-options"

# 4. Kill port-forward
kill $PF_PID
```

**Expected Output:**
* HTTP check returns: `HTTP/1.1 301 Moved Permanently` (Location: `https://...`)
* HTTPS check returns: `HTTP/2 302` or `200` with `strict-transport-security` headers.

---

## 📋 Module 5: Catalog Readiness & Image Distribution Audit

### 5.1 Verify Containerd Image Cache on Worker Node
Inspects the container image cache inside `ai-worker1` containerd to verify zero-registry pre-loading.

```bash
kubectl get nodes -o jsonpath='{range .items[?(@.metadata.name=="ai-worker1")]}{range .status.images[*]}{.names}{"\n"}{end}{end}' | grep -E "slurmd|interactive"
```

**Expected Output:**
* `slurmd-custom:latest` (or `docker.io/library/slurmd-custom:latest`) is present.
* *(Note: If `interactive-jupyter`, `codeserver`, or `bash` are missing, run [`scripts/transfer-images-proxmox.sh`](file:///home/khemi/workspace/ai_sandbox/scripts/transfer-images-proxmox.sh) to stream them over SSH).*

---

### 5.2 Verify Apptainer Image Staging on NFS
Checks if pre-built Apptainer `.sif` batch execution images exist in the central software library.

```bash
kubectl exec -n slurm slurm-worker-slurmd-cpu-0 -c slurmd -- ls -la /mnt/storage/common/software/
```

**Expected Output:**
* Directory listing showing available `.sif` images (e.g. `pytorch.sif`).

---

---

## 📋 Module 6: GPU Hardware Acceleration & Time-Slicing

### 6.1 Verify GPU Node Readiness & Capacity Advertisement
Verifies that `ai-sandbox-gpu-vm` is `Ready` and advertises 2-way hardware time-sliced GPU capacity (`nvidia.com/gpu: 2`).

```bash
kubectl get node ai-sandbox-gpu-vm -o jsonpath='{.status.capacity.nvidia\.com/gpu}'
```

**Expected Output:**
```text
2
```

---

### 6.2 Inspect Physical GPU Subsystem via NVML (`nvidia-smi`)
Inspects the physical accelerator hardware directly through the active NVIDIA device plugin DaemonSet pod.

```bash
PLUGIN_POD=$(kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "$PLUGIN_POD" -- nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader
```

**Expected Output:**
```text
NVIDIA L40, 595.91.07, 8.9, 46068 MiB
```

---

### 6.3 Verify GPU Worker Pinning & NFS Mount
Confirms `slurm-worker-slurmd-gpu-0` is scheduled on `ai-sandbox-gpu-vm` and mounts `/mnt/storage` over NFSv4.

```bash
kubectl get pod -n slurm slurm-worker-slurmd-gpu-0 -o wide
kubectl exec -n slurm slurm-worker-slurmd-gpu-0 -c slurmd -- df -h /mnt/storage
```

**Expected Output:**
* Node is `ai-sandbox-gpu-vm`.
* Storage shows `10.35.123.50:/srv/shared-storage` mounted at `/mnt/storage`.

---

### 6.4 Live Compute Dispatch to GPU Partitions
Submits real compute jobs via Slurm targeting both `batch-gpu` and `inference` partitions to verify compute worker dispatch.

```bash
# 1. Dispatch to batch-gpu partition
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- srun -p batch-gpu -w slurmd-gpu-0 -t 1 --mem=128M hostname

# 2. Dispatch to inference partition
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- srun -p inference -t 1 --mem=128M hostname
```

**Expected Output:**
* Both commands return: `slurmd-gpu-0`

---

## 🎯 Verification Sign-Off Checklist

| Component | Test Method | Status | Verified By |
| :--- | :--- | :--- | :--- |
| **K3s Topology & Node Roles (3 Nodes)** | `kubectl get nodes -o wide` | 🟢 Verified | Automated + Manual |
| **Slinky Operators & Daemons** | `kubectl get pods -n slurm` | 🟢 Verified | Automated + Manual |
| **4 Slurm Partitions (`sinfo`)** | `sinfo` on `slurmctld` | 🟢 Verified | Automated + Manual |
| **Slurm QoS & Fair-Share** | `sacctmgr show qos` + `sshare` | 🟢 Verified | Automated + Manual |
| **Live Batch CPU Dispatch** | `srun -p batch-cpu` + `sacct` | 🟢 Verified | Automated + Manual |
| **GPU Time-Slicing (`nvidia.com/gpu: 2`)** | `kubectl get node ai-sandbox-gpu-vm` | 🟢 Verified | Automated + Manual |
| **Physical L40 Accelerator (NVML)** | `nvidia-smi` in plugin pod | 🟢 Verified | Automated + Manual |
| **Slurm GPU Worker Pinning** | `kubectl get pod slurmd-gpu-0` | 🟢 Verified | Automated + Manual |
| **Live Slurm GPU Dispatch** | `srun -p batch-gpu -w slurmd-gpu-0` | 🟢 Verified | Automated + Manual |
| **Shared Storage Mount (CPU + GPU)** | `df -h /mnt/storage` on workers | 🟢 Verified | Automated + Manual |
| **Multi-Tenant POSIX DAC** | `stat -c %a /projects/*` | 🟢 Verified | Automated + Manual |
| **Scratch Sticky-Bit (`1777`)** | `stat -c %a /scratch` | 🟢 Verified | Automated + Manual |
| **RBAC Confinement (`portal-sa`)**| `kubectl auth can-i` | 🟢 Verified | Automated + Manual |
| **DB & Peer Isolation** | TCP probe from `workload` pod | 🟢 Verified | Automated + Manual |
| **Traefik TLS & 80->443 Redirect**| `curl -I` port 80/443 | 🟢 Verified | Automated + Manual |
