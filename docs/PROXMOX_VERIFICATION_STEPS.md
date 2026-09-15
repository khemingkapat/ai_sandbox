# Proxmox VM Environment: Staged Deployment & Verification Guide

This document outlines the phased plan to replicate the AI Sandbox Slinky HPC cluster (currently running locally in Kind) onto Ubuntu virtual machines in Proxmox VE.

---

## 🏛️ Architectural Context & Design Decisions

### 1. Topology Selection (1 Control Plane + 1 Worker Initially)
* **The 2-Control Plane Anti-Pattern Avoided:** Raft/etcd quorum is calculated as $\lfloor N/2 \rfloor + 1$. A 2-node control plane requires 2 nodes for quorum, tolerating 0 node failures while doubling network partition and split-brain risks.
* **Phase 1 Baseline:** We start with **1 Control Plane VM (4 vCPU, 16 GB RAM)** and **1 Worker VM (8 vCPU, 32 GB RAM)** residing on Proxmox Host 1.
* **Phase 2 Expansion:** The secondary VM allocation on Proxmox Host 2 will be added as a **second Worker node** to enable true multi-node Slurm job scheduling (`srun -N2`).

### 2. Storage Strategy (`hostPath` backed by External NFS)
* In the local Kind cluster, storage was bind-mounted from the workstation via Docker daemon `extraMounts`.
* Across separate Proxmox VMs, `hostPath` without a distributed filesystem causes immediate data divergence.
* **Solution:** An external NFS share is mounted to `/mnt/storage` at the OS level on all VMs. This allows [`k8s/pv-pvc.yaml`](../k8s/pv-pvc.yaml) to remain unmodified while providing true POSIX-compliant ReadWriteMany (RWX) storage across nodes.

### 3. Kubernetes Distribution: K3s
* **Rationale:** Reduces operational overhead compared to vanilla kubeadm (single binary, embedded containerd, bundled sqlite/etcd, automated TLS rotation).
* **Flags:** Default Traefik and ServiceLB are explicitly disabled (`--disable traefik --disable servicelb`) to prevent conflicts with the repository's custom Traefik and Slinky configurations.

---

## 🗺️ Staged Deployment Pipeline

```
┌────────────────────────────────────────────────────────┐
│  Stage 0: OS & Shared Storage Baseline                 │
│  (NFS mount, swapoff, kernel modules, inotify limits)  │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│  Stage 1: Kubernetes Cluster Bootstrap                 │
│  (1 CP + 1 Worker via K3s, workstation kubeconfig)     │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│  Stage 2: Storage Layer & Multi-Node RWX Verification  │
│  (Namespaces, PV/PVC, cross-node pod sync test)        │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│  Stage 3: Core Infrastructure                          │
│  (Cert-Manager, MariaDB for Slurmdbd, OCI Registry)    │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│  Stage 4: Slinky & Slurm Orchestration                 │
│  (CRDs, Operator, slurmctld, slurmd worker, srun test) │
└───────────────────────────┬────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────┐
│  Stage 5: HPC Portal & Dynamic Routing                 │
│  (Traefik, TLS certificates, Portal deployment)        │
└────────────────────────────────────────────────────────┘
```

---

## Stage 0: OS & Shared Storage Baseline

**Goal:** Configure base operating system prerequisites, kernel modules, file-watcher sysctls, and mount the external NFS storage uniformly on both VMs.

### Step 0.1: Run on BOTH VMs (Control Plane & Worker)

```bash
# 1. Update packages and install prerequisites
sudo apt update && sudo apt install -y \
  qemu-guest-agent \
  curl \
  apt-transport-https \
  ca-certificates \
  nfs-common

sudo systemctl enable --now qemu-guest-agent

# 2. Configure kernel modules required by container runtime
cat <<EOS | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOS
sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Configure sysctl parameters (Networking & Inotify watchers for Traefik/Slurm)
cat <<EOS | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOS
sudo sysctl --system

# 4. Disable swap permanently (Kubernetes memory management requirement)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 5. Create mount points and local directories
sudo mkdir -p /mnt/storage
sudo mkdir -p /mnt/slurm-state  # Local to Control Plane for slurmctld state
```

### Step 0.2: Configure NFS Mount in `/etc/fstab` (Both VMs)

Add the external NFS export to `/etc/fstab` on both VMs:
```bash
# Example: replace with your actual NFS server IP and export path
<NFS_SERVER_IP>:/path/to/ai_sandbox_storage /mnt/storage nfs rw,sync,hard,intr,_netdev 0 0
```
Mount immediately:
```bash
sudo mount -a
```

### 🔍 Stage 0 Verification
Execute on **Control Plane VM**:
```bash
echo "stage0-sync-$(date +%s)" | sudo tee /mnt/storage/test_sync.txt
```
Execute on **Worker VM**:
```bash
cat /mnt/storage/test_sync.txt
echo "worker-ack" | sudo tee -a /mnt/storage/test_sync.txt
```
* **Pass Criteria:**
  * Worker VM prints the string created by the Control Plane VM.
  * Worker VM writes back without permission or locking errors.
  * Clean up: `sudo rm /mnt/storage/test_sync.txt`.

---

## Stage 1: Kubernetes Cluster Bootstrap (K3s)

**Goal:** Establish the Kubernetes control plane and join the worker node using K3s.

### Step 1.1: On the Control Plane VM
Install K3s server without conflicting components:
```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=vxlan \
  --write-kubeconfig-mode 644" sh -
```

Retrieve the cluster join token and note the Control Plane IP:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
ip route get 1.1.1.1 | awk '{print $7}'
```

### Step 1.2: On the Worker VM
Join the worker node to the control plane:
```bash
curl -sfL https://get.k3s.io | K3S_URL="https://<CONTROL_PLANE_IP>:6443" \
  K3S_TOKEN="<NODE_TOKEN_FROM_STEP_1.1>" sh -
```

### Step 1.3: On your Local Workstation
Export the cluster `kubeconfig` to your development machine:
```bash
mkdir -p ~/.kube
scp user@<CONTROL_PLANE_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/config-proxmox

# Replace 127.0.0.1 with the actual Control Plane IP
sed -i 's/127\.0\.0\.1/<CONTROL_PLANE_IP>/g' ~/.kube/config-proxmox

export KUBECONFIG=~/.kube/config-proxmox
```

### 🔍 Stage 1 Verification
Run from your local workstation:
```bash
kubectl get nodes -o wide
```
* **Pass Criteria:**
  * Both Control Plane and Worker show `STATUS: Ready`.
  * Roles show `control-plane,master` for CP and `<none>` (or `worker`) for Worker.

---

## Stage 2: Storage Layer & Multi-Node RWX Verification

**Goal:** Verify that Kubernetes pods running on different physical VMs can bind to `/mnt/storage` concurrently.

### Step 2.1: Apply Namespaces and Storage Resources
From your local workstation in `ai_sandbox/`:
```bash
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/pv-pvc.yaml
```

Check PV and PVC status:
```bash
kubectl get pv,pvc -n slurm
kubectl get pv,pvc -n workload
```
* Both `slinky-storage-pvc` and `slurm-state-pvc` must report `STATUS: Bound`.

### 🔍 Stage 2 Verification (Cross-Node Pod Read/Write Test)
Deploy two test pods targeted to specific nodes:

```bash
CP_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
WORKER_NODE=$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}' | head -n 1)

# Deploy Pod 1 on Control Plane
kubectl run test-node-cp --image=busybox --restart=Never -n slurm \
  --overrides="{\"spec\":{\"nodeName\":\"$CP_NODE\",\"volumes\":[{\"name\":\"s\",\"persistentVolumeClaim\":{\"claimName\":\"slinky-storage-pvc\"}}],\"containers\":[{\"name\":\"b\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"echo cp-verified > /mnt/storage/cross_pod.txt && sleep 3600\"],\"volumeMounts\":[{\"mountPath\":\"/mnt/storage\",\"name\":\"s\"}]}]}}"

# Deploy Pod 2 on Worker
kubectl run test-node-worker --image=busybox --restart=Never -n slurm \
  --overrides="{\"spec\":{\"nodeName\":\"$WORKER_NODE\",\"volumes\":[{\"name\":\"s\",\"persistentVolumeClaim\":{\"claimName\":\"slinky-storage-pvc\"}}],\"containers\":[{\"name\":\"b\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"cat /mnt/storage/cross_pod.txt && sleep 3600\"],\"volumeMounts\":[{\"mountPath\":\"/mnt/storage\",\"name\":\"s\"}]}]}}"

# Wait for worker pod to execute
sleep 5
kubectl logs test-node-worker -n slurm
```

* **Pass Criteria:**
  * `kubectl logs test-node-worker -n slurm` outputs `cp-verified`.
  * Clean up:
    ```bash
    kubectl delete pod test-node-cp test-node-worker -n slurm
    rm -f /mnt/storage/cross_pod.txt
    ```

---

## Stage 3: Supporting Infrastructure

**Goal:** Deploy cert-manager, MariaDB for Slurmdbd accounting, and the in-cluster OCI registry.

### Step 3.1: Install Cert-Manager
```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

### Step 3.2: Deploy MariaDB for Slurm Accounting
```bash
kubectl apply -f k8s/mariadb.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n slurm --timeout=180s
```

### Step 3.3: Deploy Local In-Cluster Registry
Ensure `storage/registry` directory exists on the NFS mount:
```bash
mkdir -p /mnt/storage/registry
kubectl apply -f k8s/registry.yaml
kubectl wait --for=condition=ready pod -l app=registry -n slurm --timeout=120s
```

### 🔍 Stage 3 Verification
```bash
kubectl get pods -n cert-manager
kubectl get pods -n slurm -l app.kubernetes.io/name=mariadb
kubectl get pods -n slurm -l app=registry
```
* **Pass Criteria:** All pods show `1/1 Running`.

---

## Stage 4: Slinky & Slurm Orchestration

**Goal:** Deploy Slinky CRDs, operator, Slurm controller (`slurmctld`), compute NodeSets, and verify job scheduling.

### Step 4.1: Deploy Operator CRDs and Controller
```bash
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --namespace slinky --create-namespace
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --namespace slinky --wait

kubectl wait -n slinky --for=condition=available deployment/slurm-operator --timeout=300s
```

### Step 4.2: Deploy Slurm Cluster
```bash
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm --namespace slurm --create-namespace -f k8s/values.yaml
kubectl wait --for=condition=ready pod/slurm-controller-0 -n slurm --timeout=300s
```

### Step 4.3: Configure Accounting & Generate Tokens
```bash
./scripts/setup-accounting.sh

BRIDGE_TOKEN=$(kubectl exec -n slurm slurm-controller-0 -c slurmctld -- scontrol token lifespan=unlimited | cut -d= -f2 | tr -d '\r')
kubectl create secret generic slurm-bridge-token -n slurm --from-literal=auth-token=$BRIDGE_TOKEN --dry-run=client -o yaml | kubectl apply -f -

helm install slurm-bridge oci://ghcr.io/slinkyproject/charts/slurm-bridge --namespace slurm -f k8s/slurm-bridge-values.yaml --wait
```

### 🔍 Stage 4 Verification (Slurm Cluster Sanity)
Exec into the Slurm controller pod to check partition state and dispatch a test workload:
```bash
# Check Slurm partition states
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sinfo

# Execute an interactive test job
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- srun -N1 hostname

# Submit a test batch job
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- sbatch --wrap="sleep 2 && hostname" --job-name=proxmox_verify
kubectl exec -n slurm slurm-controller-0 -c slurmctld -- squeue
```

* **Pass Criteria:**
  * `sinfo` shows partitions in `idle` or `up` status.
  * `srun -N1 hostname` prints the hostname of the running slurmd pod.
  * `sbatch` job transitions through `PD` (Pending) -> `R` (Running) -> `CG`/completed.

---

## Stage 5: HPC Portal & Dynamic Routing

**Goal:** Configure Traefik ingress, TLS certificates, and the HPC Portal.

### Step 5.1: Deploy TLS Certificates & Traefik Configuration
```bash
./scripts/generate-certs.sh
kubectl apply -f k8s/traefik-security-configmap.yaml
kubectl apply -f k8s/network-policies/
```

### Step 5.2: Deploy HPC Portal
```bash
kubectl apply -f k8s/portal-rbac.yaml
kubectl apply -f k8s/portal-deployment.yaml
kubectl apply -f k8s/clean-scratch-cronjob.yaml
```

### 🔍 Stage 5 Verification
```bash
kubectl get pods -n slurm -l app=hpc-portal
kubectl get svc -n slurm -l app=hpc-portal
```
* **Pass Criteria:** HPC Portal pod is `Running`. Accessing the portal service via node IP / NodePort or Traefik route returns HTTP 200 / login page.

---

## ⚠️ Troubleshooting & Common Pitfalls

| Symptom | Root Cause | Remediation |
| :--- | :--- | :--- |
| **NFS stale file handle or lock timeout** | Missing `nfs-common` or incorrect mount options in `/etc/fstab` | Ensure `nfs-common` is installed on all VMs. Use `rw,sync,hard,intr,_netdev` in `/etc/fstab`. |
| **Pods on Worker cannot reach Control Plane** | UFW firewall active or VXLAN port 8472 blocked | Run `sudo ufw disable` or allow UDP 8472 (Flannel VXLAN) and TCP 6443 (API Server). |
| **Traefik file watcher fails (`too many open files`)** | Inotify user instance limit exceeded | Verify `fs.inotify.max_user_instances = 8192` in `/etc/sysctl.d/k8s.conf` and reload with `sudo sysctl --system`. |
| **Slurm worker pod (`slurmd`) stuck in CrashLoopBackOff** | Mismatched Munge key or inability to mount `/mnt/storage` | Verify `slurm-storage-pv` is `Bound`. Ensure Munge secrets are identical across namespaces. |
| **K3s token expired or invalid** | Join token copied with trailing whitespace/newline | Use `tr -d '\n'` when copying `/var/lib/rancher/k3s/server/node-token`. |
