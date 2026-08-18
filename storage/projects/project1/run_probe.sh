#!/bin/bash
# ==============================================================================
# Security & Isolation Probe for AI Sandbox Apptainer Batch Jobs
# ==============================================================================

echo "======================================================================"
echo "🛡️  RUNNING AI SANDBOX SECURITY & ISOLATION AUDIT PROBE"
echo "    Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "    Node Hostname: $(hostname)"
echo "    Current User: $(whoami) (UID: $(id -u), GID: $(id -g))"
echo "======================================================================"
echo ""

# ------------------------------------------------------------------------------
# Test 1: Physical Host Disk & Raw Block Devices
# ------------------------------------------------------------------------------
echo "🔍 [Test 1] Inspecting Physical Host Hard Drives (/dev/nvme*, /dev/sd*)..."
FOUND_DRIVES=$(ls -d /dev/nvme* /dev/sd* 2>/dev/null || true)
if [ -n "$FOUND_DRIVES" ]; then
    echo "  ⚠️  [EXPOSED] Found raw block devices:"
    echo "      $FOUND_DRIVES"
    # Attempt read test
    for d in $FOUND_DRIVES; do
        if dd if="$d" of=/dev/null bs=512 count=1 2>/dev/null; then
            echo "      🔴 CRITICAL: Successfully read raw sectors from $d!"
        else
            echo "      🟢 SAFE: Read access to $d is blocked by DAC permissions."
        fi
    done
else
    echo "  ✅ [ISOLATED] No physical host hard drives (/dev/nvme*, /dev/sd*) are visible!"
fi
echo ""

# ------------------------------------------------------------------------------
# Test 2: Hardware Device Node Access (GPU / CDI / Loop)
# ------------------------------------------------------------------------------
echo "🔍 [Test 2] Checking Hardware & Accelerated Device Nodes..."
if [ -d "/dev/dri" ]; then
    echo "  ℹ️  /dev/dri devices present: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
fi
if ls /dev/nvidia* 1>/dev/null 2>&1; then
    echo "  ℹ️  NVIDIA GPU nodes present: $(ls /dev/nvidia* 2>/dev/null | tr '\n' ' ')"
else
    echo "  ℹ️  No NVIDIA GPU device nodes in this partition."
fi
if [ -e "/dev/loop-control" ]; then
    echo "  ℹ️  Loop devices accessible: $(ls -d /dev/loop* 2>/dev/null | head -n 4 | tr '\n' ' ')..."
fi
echo ""

# ------------------------------------------------------------------------------
# Test 3: Cross-Tenant Workspace Isolation
# ------------------------------------------------------------------------------
echo "🔍 [Test 3] Testing Cross-Tenant Workspace Access (/mnt/storage/projects/project2)..."
TARGET_PEER="/mnt/storage/projects/project2"
if [ -d "$TARGET_PEER" ]; then
    if ls "$TARGET_PEER" >/dev/null 2>&1; then
        echo "  🔴 VULNERABLE: Successfully read peer project workspace ($TARGET_PEER)!"
    else
        echo "  ✅ [ISOLATED] Access to peer project ($TARGET_PEER) is BLOCKED (Permission Denied)."
    fi
else
    echo "  ℹ️  Peer project directory $TARGET_PEER is not mounted or not present."
fi
echo ""

# ------------------------------------------------------------------------------
# Test 4: Shared Software Integrity & Image Tampering
# ------------------------------------------------------------------------------
echo "🔍 [Test 4] Testing Shared Software Tampering (/mnt/storage/common/software)..."
TEST_FILE="/mnt/storage/common/software/.probe_tamper_test"
if touch "$TEST_FILE" 2>/dev/null; then
    echo "  🔴 VULNERABLE: Write access granted to shared software folder! Image poisoning possible."
    rm -f "$TEST_FILE"
else
    echo "  ✅ [PROTECTED] Shared software folder is READ-ONLY. Image tampering blocked."
fi
echo ""

# ------------------------------------------------------------------------------
# Test 5: Cluster Secrets & Infrastructure Access
# ------------------------------------------------------------------------------
echo "🔍 [Test 5] Probing Cluster Secrets & Kubernetes API Tokens..."
if [ -f "/etc/munge/munge.key" ]; then
    if cat "/etc/munge/munge.key" >/dev/null 2>&1; then
        echo "  🔴 VULNERABLE: Munce authentication key is READABLE!"
    else
        echo "  ✅ [PROTECTED] /etc/munge/munge.key is protected by file permissions."
    fi
else
    echo "  ✅ [ISOLATED] No munge key present inside container namespace."
fi

K8S_TOKEN="/var/run/secrets/kubernetes.io/serviceaccount/token"
if [ -f "$K8S_TOKEN" ]; then
    echo "  ⚠️  [EXPOSED] Kubernetes service account token found inside pod."
else
    echo "  ✅ [ISOLATED] No Kubernetes API service account token mounted."
fi
echo ""

# ------------------------------------------------------------------------------
# Test 6: Container Privilege & Capability Boundaries
# ------------------------------------------------------------------------------
echo "🔍 [Test 6] Checking Container Capabilities and Privileges..."
echo "  - UID/GID Mapping: $(id)"
echo "  - Environment: HOME=$HOME, USER=$USER, WORKSPACE=$WORKSPACE"
if [ "$(id -u)" -eq 0 ]; then
    echo "  ⚠️  Running as UID 0 (root inside container namespace)."
else
    echo "  ✅ Running as non-root user (UID: $(id -u))."
fi

echo ""
echo "======================================================================"
echo "🛡️  PROBE AUDIT COMPLETE"
echo "======================================================================"
