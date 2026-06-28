#!/bin/bash
set -e

PORT=${ALLOCATED_PORT:-8888}
BASE_URL=${BASE_URL:-/}
NOTEBOOK_DIR=${WORKSPACE:-/mnt/storage}

echo "Starting JupyterLab on port $PORT with base URL $BASE_URL and notebook dir $NOTEBOOK_DIR"

# If running as root, we must allow it. In production, we expect to run as a dynamic user.
ALLOW_ROOT=""
if [ "$(id -u)" -eq 0 ]; then
    ALLOW_ROOT="--allow-root"
fi

exec jupyter lab \
    $ALLOW_ROOT \
    --ip=0.0.0.0 \
    --port=$PORT \
    --ServerApp.base_url=$BASE_URL \
    --ServerApp.token='' \
    --ServerApp.password='' \
    --notebook-dir=$NOTEBOOK_DIR \
    --no-browser
