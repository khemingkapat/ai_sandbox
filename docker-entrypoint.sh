#!/bin/bash
set -e

# Fix MUNGE permissions
chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

# Start Munge
su -s /bin/bash munge -c "munged"
sleep 1

# Ensure sandbox-user home
mkdir -p /home/sandbox-user
chown 1000:1000 /home/sandbox-user

if [ "$1" = "slurmctld" ]; then
    echo "---> Initializing Shared Storage..."
    mkdir -p /mnt/storage/users /mnt/storage/projects /mnt/storage/public
    chown -R 1000:1000 /mnt/storage/
    
    echo "---> Starting slurmctld..."
    mkdir -p /var/spool/slurmctld /var/log/slurm /var/run/slurm
    chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm /var/run/slurm
    exec slurmctld -D -v

elif [ "$1" = "slurmd" ]; then
    echo "---> Waiting for slurmctld..."
    until bash -c ">/dev/tcp/slurmctld/6817" 2>/dev/null; do
        sleep 2
    done
    
    echo "---> Starting slurmd..."
    mkdir -p /var/spool/slurmd /var/log/slurm /var/run/slurm
    chown -R slurm:slurm /var/spool/slurmd /var/log/slurm /var/run/slurm
    
    # We explicitly do NOT create a cgroup.conf to avoid triggering the plugin
    
    exec slurmd -D -v

else
    exec "$@"
fi
