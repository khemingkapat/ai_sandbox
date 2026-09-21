#!/bin/bash
# scripts/transfer-images-proxmox.sh
# Streams locally built Docker images directly into K3s containerd (k8s.io namespace)
# over SSH without requiring an external container registry.

set -euo pipefail

CTRL_IP="10.35.123.50"
WORKER_IP="10.35.123.51"
SSH_USER="admin_ai"

echo "============================================================"
echo "🚀 Slinky Image Side-Loader for Proxmox K3s"
echo "============================================================"
echo "Target Control Plane: $SSH_USER@$CTRL_IP"
echo "Target Worker Node:   $SSH_USER@$WORKER_IP"
echo ""

# 1. Transfer slurmctld-custom to ai-control
echo "📦 [1/4] Transferring slurmctld-custom:latest -> ai-control..."
docker save slurmctld-custom:latest | ssh "$SSH_USER@$CTRL_IP" "sudo k3s ctr -n k8s.io images import -"

# 2. Transfer slurmrestd-custom to ai-control
echo "📦 [2/4] Transferring slurmrestd-custom:latest -> ai-control..."
docker save slurmrestd-custom:latest | ssh "$SSH_USER@$CTRL_IP" "sudo k3s ctr -n k8s.io images import -"

# 3. Transfer hpc-portal:local to ai-control
echo "📦 [3/4] Transferring hpc-portal:local -> ai-control..."
docker save hpc-portal:local | ssh "$SSH_USER@$CTRL_IP" "sudo k3s ctr -n k8s.io images import -"

# 4. Transfer slurmd-custom to ai-worker1
echo "📦 [4/4] Transferring slurmd-custom:latest -> ai-worker1..."
docker save slurmd-custom:latest | ssh "$SSH_USER@$WORKER_IP" "sudo k3s ctr -n k8s.io images import -"

echo ""
echo "✅ All custom images successfully imported into K3s containerd!"
