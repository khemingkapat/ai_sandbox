#!/bin/bash
set -e

PORT=${ALLOCATED_PORT:-8888}
BASE_URL=${BASE_URL:-/}
WORKSPACE_DIR=${WORKSPACE:-/mnt/storage}

echo "Starting Web Terminal (ttyd) on port $PORT with base URL $BASE_URL and workspace $WORKSPACE_DIR"

BASE_ARG=""
if [ -n "$BASE_URL" ] && [ "$BASE_URL" != "/" ]; then
    BASE_ARG="-b $BASE_URL"
fi

if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$USER" ] && [ -d "$WORKSPACE_DIR" ]; then
        TARGET_UID=$(stat -c "%u" "$WORKSPACE_DIR")
        TARGET_GID=$(stat -c "%g" "$WORKSPACE_DIR")
        
        echo "Dynamically creating extrauser $USER with UID $TARGET_UID and GID $TARGET_GID"
        echo "$USER:x:$TARGET_UID:$TARGET_GID::${WORKSPACE_DIR}:/bin/bash" >> /var/lib/extrausers/passwd
        echo "$USER:x:$TARGET_GID:" >> /var/lib/extrausers/group
        
        export HOME=$WORKSPACE_DIR
        exec ttyd -p "$PORT" $BASE_ARG -W -w "$WORKSPACE_DIR" -u "$TARGET_UID" -g "$TARGET_GID" /bin/bash
    else
        exec ttyd -p "$PORT" $BASE_ARG -W -w "$WORKSPACE_DIR" /bin/bash
    fi
else
    exec ttyd -p "$PORT" $BASE_ARG -W -w "$WORKSPACE_DIR" /bin/bash
fi
