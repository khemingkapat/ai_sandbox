#!/bin/bash
set -e

# Only run storage init on the controller node
if [ "$1" = "slurmctld" ]; then
    echo "---> Initializing shared storage structure..."
    mkdir -p /mnt/storage/users /mnt/storage/projects /mnt/storage/public
    chown -R 990:990 /mnt/storage/users /mnt/storage/projects /mnt/storage/public
    echo "---> Storage ready."
fi

# Hand off to giovtorres's original entrypoint for all Slurm startup logic
exec /usr/local/bin/docker-entrypoint.sh "$@"
