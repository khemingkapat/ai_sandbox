#!/bin/bash
# scripts/init-storage.sh
# Initializes the directory hierarchy and sets up Unix permissions to isolate student projects.

set -e

STORAGE_ROOT="/mnt/storage"

echo "📂 Creating storage layout under $STORAGE_ROOT..."

# Ensure the base directories exist
mkdir -p "$STORAGE_ROOT/projects/project1"
mkdir -p "$STORAGE_ROOT/projects/project2"
mkdir -p "$STORAGE_ROOT/common"
mkdir -p "$STORAGE_ROOT/datasets"

echo "🔐 Setting permissions and ownership..."

# Sets owner and permissions:
# /mnt/storage/projects/project1 owned by UID 1001:1001 with perm 700 (drwx------)
chown 1001:1001 "$STORAGE_ROOT/projects/project1"
chmod 700 "$STORAGE_ROOT/projects/project1"

# /mnt/storage/projects/project2 owned by UID 1002:1002 with perm 700 (drwx------)
chown 1002:1002 "$STORAGE_ROOT/projects/project2"
chmod 700 "$STORAGE_ROOT/projects/project2"

# /mnt/storage/common owned by UID 0:0 with perm 555 (dr-xr-xr-x)
chown 0:0 "$STORAGE_ROOT/common"
chmod 555 "$STORAGE_ROOT/common"

# /mnt/storage/datasets owned by UID 0:0 with perm 555 (dr-xr-xr-x)
chown 0:0 "$STORAGE_ROOT/datasets"
chmod 555 "$STORAGE_ROOT/datasets"

echo "✅ Storage initialization complete."
