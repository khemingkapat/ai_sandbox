#!/bin/bash
set -e

# Fix munge key permissions
chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

# Start munged as munge user
su -s /bin/bash munge -c "munged"
sleep 1

# Phase 1: Ensure directory structure in the shared mount
# (Only the controller needs to initialize the structure if empty)
if [ "$1" = "slurmctld" ]; then
    echo "---> Initializing Storage Structure..."
    mkdir -p /mnt/storage/users /mnt/storage/projects /mnt/storage/public
    # Set permissions so our sandbox-user can write to them
    chown 1000:1000 /mnt/storage/users /mnt/storage/projects /mnt/storage/public
    
    echo "---> Starting slurmctld..."
    mkdir -p /var/spool/slurmctld /var/log/slurm
    chown slurm:slurm /var/spool/slurmctld /var/log/slurm 2>/dev/null || true
    exec slurmctld -Dvvv

elif [ "$1" = "slurmd" ]; then

    # Force cgroup v1 plugin explicitly
    cat > /etc/slurm/cgroup.conf << 'EOF'
CgroupPlugin=cgroup/v1
CgroupAutomount=yes
CgroupMountpoint=/sys/fs/cgroup
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainSwapSpace=no
ConstrainDevices=no
EOF

    echo "---> Waiting for slurmctld port 6817..."
    until bash -c ">/dev/tcp/slurmctld/6817" 2>/dev/null; do
        echo "--- slurmctld not ready, retrying in 2s..."
        sleep 2
    done
    echo "---> slurmctld is up, starting slurmd..."

    mkdir -p /var/spool/slurmd /var/log/slurm
    chown slurm:slurm /var/spool/slurmd /var/log/slurm 2>/dev/null || true

    exec slurmd -Dvvv

else
    exec "$@"
fi
