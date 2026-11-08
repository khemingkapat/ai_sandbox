# In-Cluster Runner: Architecture & Proxmox LXC Setup Guide

This document outlines the architecture, security model, and setup instructions for the AI Sandbox GitHub Actions runner. It is designed for sysadmins and cluster engineers.

---

## 1. Security Architecture & Threat Model

### The Outbound Long-Polling Model
The runner operates strictly on an **outbound-only polling connection**:
- The runner daemon dials `api.github.com` via HTTPS (port 443).
- **Zero inbound ports** are opened on the firewall, Proxmox hypervisor, or Kubernetes API.

```
[GitHub API] <========(Outbound HTTPS 443 Long-Polling)========= [Proxmox Runner LXC (10.35.123.x)]
                                                                           │
                                                                   (Direct LAN 6443)
                                                                           ▼
                                                                [K3s Control: 10.35.123.50]
```

### Why Workstation Hosting Was Rejected
An architectural security audit demonstrated that running a self-hosted runner directly on a developer workstation introduces a critical Remote Code Execution (RCE) vector:
1. Workflows execute as the host user, granting arbitrary scripts access to `~/.ssh`, browser tokens, and personal credentials.
2. If `ptunnel` is active, any compromised workflow gains unconstrained `cluster-admin` control over the entire cluster.
3. Therefore, the runner **must reside exclusively inside an isolated Proxmox LXC container or VM** under an unprivileged system user.

---

## 2. Proxmox LXC Runner Deployment (10-Minute Setup)

### Step 1: Create an Unprivileged LXC Container in Proxmox
- **OS Template:** Debian 12 Minimal (or Ubuntu 24.04 LTS).
- **Resources:**
  - Sizing: 2 vCPUs, 2GB RAM, 20GB disk.
  - Unprivileged container: `Yes`.
- **Networking:**
  - Bridge: `vmbr0` (or the cluster management VLAN).
  - Static IP: e.g., `10.35.123.55/24` (Gateway: `10.35.123.1`).
  - DNS: Your local cluster DNS or `1.1.1.1`.

### Step 2: Install CLI Dependencies Inside Container
Log in to the container console and install the test runner dependencies:
```bash
apt-get update && apt-get install -y \
  curl git jq sudo ca-certificates tar bzip2 libicu-dev

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# Create unprivileged runner user
useradd -m -s /bin/bash github-runner
```

### Step 3: Configure Scoped Cluster Access
Copy the cluster kubeconfig to the runner user:
```bash
mkdir -p /home/github-runner/.kube
cp /path/to/config-proxmox /home/github-runner/.kube/config
chown -R github-runner:github-runner /home/github-runner/.kube
chmod 600 /home/github-runner/.kube/config

# Test direct LAN reachability (no tunnels needed!)
su - github-runner -c "kubectl get nodes"
```

### Step 4: Register and Start GitHub Actions Daemon
Switch to the `github-runner` user and register the daemon:
```bash
su - github-runner
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download runner package (check GitHub repo Settings -> Actions -> Runners for latest URL)
curl -o actions-runner-linux-x64-latest.tar.gz -L https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf ./actions-runner-linux-x64-latest.tar.gz

# Configure runner
./config.sh --url https://github.com/khemingkapat/ai_sandbox \
            --token <GITHUB_REGISTRATION_TOKEN> \
            --labels self-hosted,linux,local-cluster \
            --name proxmox-cluster-runner \
            --unattended

# Install systemd service as root
exit # Back to root
cd /home/github-runner/actions-runner
./svc.sh install github-runner
./svc.sh start
./svc.sh status
```

---

## 3. Operations & Maintenance Flags

### Scheduled GPU Maintenance Flag
When physical GPUs are offline or borrowed for external workloads:
1. Navigate to **GitHub Repository** -> **Settings** -> **Secrets and variables** -> **Actions** -> **Variables**.
2. Set `CLUSTER_GPU_MAINTENANCE` = `"true"`.
3. When `"true"`, Stage 2 hardware verification runs all core CPU, Slurm, network, and storage suites, while logging an explicit warning banner and skipping GPU assertions.
4. When the GPU returns, toggle `CLUSTER_GPU_MAINTENANCE` = `"false"`. The pipeline will now enforce GPU presence and fail immediately if drivers or devices drop offline.
