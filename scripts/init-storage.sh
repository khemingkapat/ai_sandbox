#!/bin/bash
# scripts/init-storage.sh
# Initializes the unified directory hierarchy and sets up POSIX permissions for multi-tenant isolation.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

echo "📂 Initializing storage layout under $STORAGE_ROOT..."

# 1. Base Shared Infrastructure
mkdir -p "$STORAGE_ROOT/common/etc"
mkdir -p "$STORAGE_ROOT/common/software"
mkdir -p "$STORAGE_ROOT/registry"

# 2. Central Read-Only Models Hub
mkdir -p "$STORAGE_ROOT/models/huggingface/hub"
mkdir -p "$STORAGE_ROOT/models/torch"
mkdir -p "$STORAGE_ROOT/models/ollama"

# 3. Central Read-Only Curated Datasets
mkdir -p "$STORAGE_ROOT/datasets/kaggle/competitions"
mkdir -p "$STORAGE_ROOT/datasets/kaggle/public"
mkdir -p "$STORAGE_ROOT/datasets/vision"
mkdir -p "$STORAGE_ROOT/datasets/nlp"

# 4. Ephemeral Scratch Space
mkdir -p "$STORAGE_ROOT/scratch"

# 5. Multi-Tenant Student Private Workspaces
mkdir -p "$STORAGE_ROOT/projects/project1/.cache/huggingface"
mkdir -p "$STORAGE_ROOT/projects/project1/.cache/kagglehub"
mkdir -p "$STORAGE_ROOT/projects/project1/.kaggle"
mkdir -p "$STORAGE_ROOT/projects/project2/.cache/huggingface"
mkdir -p "$STORAGE_ROOT/projects/project2/.cache/kagglehub"
mkdir -p "$STORAGE_ROOT/projects/project2/.kaggle"
mkdir -p "$STORAGE_ROOT/projects/project3/.cache/huggingface"
mkdir -p "$STORAGE_ROOT/projects/project3/.cache/kagglehub"
mkdir -p "$STORAGE_ROOT/projects/project3/.kaggle"

echo "🔐 Setting permissions and ownership boundaries..."

# Root owned shared infrastructure (755)
chown -R 0:0 "$STORAGE_ROOT/common" "$STORAGE_ROOT/models" "$STORAGE_ROOT/datasets" "$STORAGE_ROOT/registry"
chmod 755 "$STORAGE_ROOT/common" "$STORAGE_ROOT/common/etc" "$STORAGE_ROOT/common/software"
chmod 755 "$STORAGE_ROOT/models" "$STORAGE_ROOT/models/huggingface" "$STORAGE_ROOT/models/huggingface/hub" "$STORAGE_ROOT/models/torch" "$STORAGE_ROOT/models/ollama"
chmod 755 "$STORAGE_ROOT/datasets" "$STORAGE_ROOT/datasets/kaggle" "$STORAGE_ROOT/datasets/kaggle/competitions" "$STORAGE_ROOT/datasets/kaggle/public" "$STORAGE_ROOT/datasets/vision" "$STORAGE_ROOT/datasets/nlp"
chmod 755 "$STORAGE_ROOT/registry"

# Ephemeral Scratch with POSIX Sticky Bit (1777)
chown 0:0 "$STORAGE_ROOT/scratch"
chmod 1777 "$STORAGE_ROOT/scratch"

# Private student project directories (700)
# project1 -> UID 1001
chown -R 1001:1001 "$STORAGE_ROOT/projects/project1"
chmod 700 "$STORAGE_ROOT/projects/project1"
chmod u=rwx,g=,o=,u-s,g-s "$STORAGE_ROOT/projects/project1"

# project2 -> UID 1002
chown -R 1002:1002 "$STORAGE_ROOT/projects/project2"
chmod 700 "$STORAGE_ROOT/projects/project2"
chmod u=rwx,g=,o=,u-s,g-s "$STORAGE_ROOT/projects/project2"

# project3 -> UID 1004 (shared team account)
chown -R 1004:1004 "$STORAGE_ROOT/projects/project3"
chmod 700 "$STORAGE_ROOT/projects/project3"
chmod u=rwx,g=,o=,u-s,g-s "$STORAGE_ROOT/projects/project3"

echo "✅ Storage initialization complete under $STORAGE_ROOT."
