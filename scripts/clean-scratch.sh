#!/bin/bash
# scripts/clean-scratch.sh
# Purges ephemeral temporary files from /mnt/storage/scratch older than the retention threshold.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

SCRATCH_DIR="$STORAGE_ROOT/scratch"
RETENTION_DAYS=7
DRY_RUN=0

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --retention-days <N>  Retention threshold in days (default: 7)"
    echo "  -n, --dry-run             Simulate cleanup without deleting files"
    echo "  -p, --path <path>         Custom scratch path (default: $SCRATCH_DIR)"
    echo "  -h, --help                Display this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--retention-days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -p|--path)
            SCRATCH_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [ ! -d "$SCRATCH_DIR" ]; then
    echo "❌ Scratch directory $SCRATCH_DIR does not exist."
    exit 1
fi

echo "🧹 Inspecting scratch space at $SCRATCH_DIR (Retention: $RETENTION_DAYS days, Dry Run: $DRY_RUN)..."

if [ "$DRY_RUN" -eq 1 ]; then
    echo "🔍 [Dry Run] Stale files eligible for deletion:"
    find "$SCRATCH_DIR" -mindepth 1 -type f -mtime +"$RETENTION_DAYS" -ls || true
    echo "🔍 [Dry Run] Empty directories eligible for cleanup:"
    find "$SCRATCH_DIR" -mindepth 1 -type d -empty -mtime +"$RETENTION_DAYS" -ls || true
else
    echo "🗑️ Deleting stale files older than $RETENTION_DAYS days..."
    DELETED_FILES=$(find "$SCRATCH_DIR" -mindepth 1 -type f -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
    
    echo "🗑️ Removing empty stale directories..."
    find "$SCRATCH_DIR" -mindepth 1 -type d -empty -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
    
    echo "✅ Scratch cleanup completed. Purged $DELETED_FILES stale files."
fi
