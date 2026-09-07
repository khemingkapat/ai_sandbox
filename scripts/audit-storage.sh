#!/bin/bash
# scripts/audit-storage.sh
# Audits shared and student project disk consumption, identifies duplicate datasets, and reports pro-rata usage.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

PROJECTS_DIR="$STORAGE_ROOT/projects"
MODELS_DIR="$STORAGE_ROOT/models"
DATASETS_DIR="$STORAGE_ROOT/datasets"
SCRATCH_DIR="$STORAGE_ROOT/scratch"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -p, --path <path>         Base storage root (default: $STORAGE_ROOT)"
    echo "  -h, --help                Display this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--path)
            STORAGE_ROOT="$2"
            PROJECTS_DIR="$STORAGE_ROOT/projects"
            MODELS_DIR="$STORAGE_ROOT/models"
            DATASETS_DIR="$STORAGE_ROOT/datasets"
            SCRATCH_DIR="$STORAGE_ROOT/scratch"
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

echo "============================================================"
echo "📊 AI Sandbox Storage Audit & Capacity Report"
echo "============================================================"
echo "Root Path: $STORAGE_ROOT"
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo ""

echo "--- 1. Top-Level Directory Utilization ---"
if [ -d "$STORAGE_ROOT" ]; then
    du -sh "$STORAGE_ROOT"/* 2>/dev/null | sort -hr || true
fi
echo ""

echo "--- 2. Student Projects Storage Breakdown ---"
if [ -d "$PROJECTS_DIR" ]; then
    printf "%-20s %-15s %-10s\n" "Project Directory" "Disk Usage" "Owner"
    printf "%-20s %-15s %-10s\n" "--------------------" "---------------" "----------"
    for proj in "$PROJECTS_DIR"/*; do
        if [ -d "$proj" ]; then
            pname=$(basename "$proj")
            size=$(du -sh "$proj" 2>/dev/null | awk '{print $1}')
            owner=$(stat -c "%U:%G" "$proj" 2>/dev/null || stat -f "%u:%g" "$proj" 2>/dev/null || echo "unknown")
            printf "%-20s %-15s %-10s\n" "$pname" "$size" "$owner"
        fi
    done
else
    echo "No projects directory found at $PROJECTS_DIR"
fi
echo ""

echo "--- 3. Slurm Account Pro-Rata Association (if Slurm active) ---"
if command -v sacctmgr >/dev/null 2>&1; then
    echo "Querying active Slurm accounts and member associations..."
    sacctmgr show association format=Account,User,Share -n -P 2>/dev/null || echo "SlurmDBD not reachable"
else
    echo "sacctmgr CLI not in PATH (skipping live SlurmDB query)"
fi
echo ""

echo "--- 4. Deduplication & Promotion Candidates ---"
echo "Scanning for duplicate dataset or model folder signatures across student workspaces..."

declare -A folder_map
duplicates_found=0

if [ -d "$PROJECTS_DIR" ]; then
    while IFS= read -r dir; do
        bname=$(basename "$dir")
        # Ignore common boilerplate directories and hidden directories
        if [[ "$bname" =~ ^(\.cache|\.kaggle|logs|software|\..*)$ ]]; then
            continue
        fi
        if [ -n "${folder_map[$bname]}" ]; then
            echo "⚠️ Potential duplicate found: '$bname'"
            echo "   -> Location 1: ${folder_map[$bname]}"
            echo "   -> Location 2: $dir"
            echo "   💡 Recommendation: Promote '$bname' to $DATASETS_DIR or $MODELS_DIR to save disk quota."
            duplicates_found=$((duplicates_found + 1))
        else
            folder_map[$bname]="$dir"
        fi
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 3 -type d -not -path '*/.*' 2>/dev/null)
fi

if [ "$duplicates_found" -eq 0 ]; then
    echo "✅ No obvious duplicate dataset directories detected across projects."
fi

echo ""
echo "============================================================"
echo "Audit complete."
echo "============================================================"
