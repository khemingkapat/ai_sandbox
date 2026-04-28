#!/bin/bash
set -e

# Only run storage init on the controller node
if [ "$1" = "slurmctld" ]; then
    echo "---> Initializing shared project & common storage structure..."
    mkdir -p /mnt/storage/projects /mnt/storage/common/software /mnt/storage/common/kaggle_cache
    
    # We assign basic ownership, but the setup-users script will handle the strict group permissions later
    chown -R 990:990 /mnt/storage/projects /mnt/storage/common
    echo "---> Storage ready."
fi

# Hand off to giovtorres's original entrypoint for all Slurm startup logic
exec /usr/local/bin/docker-entrypoint.sh "$@"
