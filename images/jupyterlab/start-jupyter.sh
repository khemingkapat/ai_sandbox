#!/bin/bash
set -e

PORT=${ALLOCATED_PORT:-8888}
BASE_URL=${BASE_URL:-/}
NOTEBOOK_DIR=${WORKSPACE:-/mnt/storage}

echo "Starting JupyterLab on port $PORT with base URL $BASE_URL and notebook dir $NOTEBOOK_DIR"

# If running as root, we must allow it. In production, we expect to run as a dynamic user.
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$USER" ] && [ -d "$NOTEBOOK_DIR" ]; then
        TARGET_UID=$(stat -c "%u" "$NOTEBOOK_DIR")
        TARGET_GID=$(stat -c "%g" "$NOTEBOOK_DIR")
        
        echo "Dynamically creating extrauser $USER with UID $TARGET_UID and GID $TARGET_GID"
        echo "$USER:x:$TARGET_UID:$TARGET_GID::/home/jovyan:/bin/bash" >> /var/lib/extrausers/passwd
        echo "$USER:x:$TARGET_GID:" >> /var/lib/extrausers/group
        
        export HOME=$NOTEBOOK_DIR
        exec chroot --userspec=$TARGET_UID:$TARGET_GID / jupyter lab --ip=0.0.0.0 --port=$PORT --ServerApp.base_url=$BASE_URL --ServerApp.token='' --ServerApp.password='' --notebook-dir=$NOTEBOOK_DIR --no-browser
    else
        exec jupyter lab --allow-root --ip=0.0.0.0 --port=$PORT --ServerApp.base_url=$BASE_URL --ServerApp.token='' --ServerApp.password='' --notebook-dir=$NOTEBOOK_DIR --no-browser
    fi
else
    exec jupyter lab \
        --ip=0.0.0.0 \
        --port=$PORT \
        --ServerApp.base_url=$BASE_URL \
        --ServerApp.token='' \
        --ServerApp.password='' \
        --notebook-dir=$NOTEBOOK_DIR \
        --no-browser
fi
