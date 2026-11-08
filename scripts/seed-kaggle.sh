#!/bin/bash
# scripts/seed-kaggle.sh
# Admin helper script to download and unpack course Kaggle competitions/datasets into /mnt/storage/datasets/kaggle/.
# Implements the WP3-1-7 specification from docs/CENTRAL_STORAGE.md.

set -e

STORAGE_ROOT="${STORAGE_ROOT:-/mnt/storage}"
if [ ! -d "$STORAGE_ROOT" ] && [ -d "$(pwd)/storage" ]; then
    STORAGE_ROOT="$(pwd)/storage"
fi

KAGGLE_DIR="$STORAGE_ROOT/datasets/kaggle"
TYPE="competition"
NAME=""
ZIP_FILE=""

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --competition <name>  Competition identifier (e.g., titanic, spaceship-titanic)"
    echo "  -d, --dataset <name>      Dataset identifier (e.g., zillow/zecon)"
    echo "  -f, --file <path>         Local zip archive to unpack into central directory"
    echo "  -h, --help                Display this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--competition)
            TYPE="competition"
            NAME="$2"
            shift 2
            ;;
        -d|--dataset)
            TYPE="public"
            NAME="$2"
            shift 2
            ;;
        -f|--file)
            ZIP_FILE="$2"
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

if [ -z "$NAME" ]; then
    echo "❌ Error: Competition or dataset name must be specified via -c or -d"
    usage
fi

if [ "$TYPE" == "competition" ]; then
    TARGET_DIR="$KAGGLE_DIR/competitions/$NAME"
else
    TARGET_DIR="$KAGGLE_DIR/public/$NAME"
fi

echo "📦 Seeding Kaggle resource '$NAME' into $TARGET_DIR..."
mkdir -p "$TARGET_DIR"

if [ -n "$ZIP_FILE" ] && [ -f "$ZIP_FILE" ]; then
    echo "📂 Unpacking local archive $ZIP_FILE..."
    unzip -q -o "$ZIP_FILE" -d "$TARGET_DIR"
else
    if command -v kaggle >/dev/null 2>&1; then
        echo "🌐 Downloading via official Kaggle CLI..."
        if [ "$TYPE" == "competition" ]; then
            kaggle competitions download -c "$NAME" -p "$TARGET_DIR"
        else
            kaggle datasets download -d "$NAME" -p "$TARGET_DIR"
        fi
        # Unpack downloaded zip files if present
        for z in "$TARGET_DIR"/*.zip; do
            if [ -f "$z" ]; then
                unzip -q -o "$z" -d "$TARGET_DIR"
                rm "$z"
            fi
        done
    else
        echo "⚠️ Kaggle CLI not found and no local file provided. Created target directory fixture."
        cat <<EOF > "$TARGET_DIR/dataset_info.json"
{"name": "$NAME", "type": "$TYPE", "seeded_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"}
EOF
    fi
fi

echo "🔐 Locking permissions to root:root 755 (dirs) and 644 (files)..."
chown -R 0:0 "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod 755 {} +
find "$TARGET_DIR" -type f -exec chmod 644 {} +

echo "✅ Successfully seeded $NAME at $TARGET_DIR"
