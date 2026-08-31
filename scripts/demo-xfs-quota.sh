#!/bin/bash
# scripts/demo-xfs-quota.sh
# 
# This script simulates the production "Layer 2" storage environment locally.
# Because we don't have the real production NFS server yet, we create a "virtual" 
# hard drive (a 1GB file) and format it as XFS. We mount it with project quotas
# enabled, just like the real server will be configured, and prove the kernel blocks writes.

set -e

DEMO_IMG="/tmp/xfs-demo.img"
DEMO_MNT="/mnt/demo-storage"
PROJECT_DIR="$DEMO_MNT/projects/project1"
PROJECT_ID=500
QUOTA_LIMIT="50m" # 50 Megabytes for the demo

echo "====================================================="
echo "🛠️  Simulating Production XFS Storage Server Layer 2"
echo "====================================================="

echo "[1/6] Creating a 1GB virtual XFS disk..."
sudo umount "$DEMO_MNT" 2>/dev/null || true
rm -f "$DEMO_IMG"
truncate -s 1G "$DEMO_IMG"
mkfs.xfs -f -q "$DEMO_IMG"

echo "[2/6] Mounting disk with 'pquota' (Project Quotas) enabled..."
sudo mkdir -p "$DEMO_MNT"
sudo mount -o loop,pquota "$DEMO_IMG" "$DEMO_MNT"

echo "[3/6] Initializing project directory for UID 1001..."
sudo mkdir -p "$PROJECT_DIR"
sudo chown 1001:1001 "$PROJECT_DIR"

echo "[4/6] Registering Project ID $PROJECT_ID and setting hard limit to $QUOTA_LIMIT..."
# The -s flag applies the project ID to the directory tree
sudo xfs_quota -x -c "project -s -p $PROJECT_DIR $PROJECT_ID" "$DEMO_MNT"
# Set the hard block limit
sudo xfs_quota -x -c "limit -p bhard=$QUOTA_LIMIT $PROJECT_ID" "$DEMO_MNT"

echo ""
echo "====================================================="
echo "🧪 Testing Kernel Enforcement"
echo "====================================================="

echo "[5/6] Writing 40MB of data (Under Quota)..."
if sudo -u "#1001" dd if=/dev/zero of="$PROJECT_DIR/test1.dat" bs=1M count=40 status=none; then
    echo "✅ Success: 40MB written."
else
    echo "❌ Failed to write valid data!"
    exit 1
fi

echo "[6/6] Attempting to write an additional 20MB (Over Quota)..."
echo "--> Expecting kernel to throw 'Disk quota exceeded'"
if sudo -u "#1001" dd if=/dev/zero of="$PROJECT_DIR/test2.dat" bs=1M count=20 status=none 2>/tmp/xfs_err; then
    echo "❌ CRITICAL FAILURE: Kernel allowed write past quota!"
    exit 1
else
    ERR_OUT=$(cat /tmp/xfs_err)
    echo -e "✅ Kernel Successfully Blocked Write: \033[0;31m$ERR_OUT\033[0m"
fi

echo ""
echo "📊 Current XFS Quota Report:"
sudo xfs_quota -x -c "report -p" "$DEMO_MNT"

echo ""
echo "🧹 Cleaning up virtual disk..."
sudo umount "$DEMO_MNT"
rm -f "$DEMO_IMG"
echo "Done!"
