#!/bin/bash
set -e

PORT=${ALLOCATED_PORT:-8888}
WORKSPACE_DIR=${WORKSPACE:-/mnt/storage}

echo "Starting VS Code Server on port $PORT with workspace $WORKSPACE_DIR"

if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$USER" ] && [ -d "$WORKSPACE_DIR" ]; then
        TARGET_UID=$(stat -c "%u" "$WORKSPACE_DIR")
        TARGET_GID=$(stat -c "%g" "$WORKSPACE_DIR")
        
        echo "Dynamically creating extrauser $USER with UID $TARGET_UID and GID $TARGET_GID"
        echo "$USER:x:$TARGET_UID:$TARGET_GID::/home/coder:/bin/bash" >> /var/lib/extrausers/passwd
        echo "$USER:x:$TARGET_GID:" >> /var/lib/extrausers/group
        
        export HOME=$WORKSPACE_DIR
        exec chroot --userspec=$TARGET_UID:$TARGET_GID / dumb-init /usr/bin/code-server --auth none --bind-addr "0.0.0.0:$PORT" --disable-telemetry --disable-update-check "$WORKSPACE_DIR"
    else
        exec dumb-init /usr/bin/code-server --auth none --bind-addr "0.0.0.0:$PORT" --disable-telemetry --disable-update-check "$WORKSPACE_DIR"
    fi
else
    exec dumb-init /usr/bin/code-server --auth none --bind-addr "0.0.0.0:$PORT" --disable-telemetry --disable-update-check "$WORKSPACE_DIR"
fi
