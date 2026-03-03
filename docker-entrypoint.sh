#!/bin/bash
set -e

# Fix munge key permissions
chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

# Start munged as munge user
su -s /bin/bash munge -c "munged"
sleep 1

if [ "$1" = "slurmctld" ]; then
    echo "---> Starting slurmctld..."
    mkdir -p /var/spool/slurmctld /var/log/slurm
    chown slurm:slurm /var/spool/slurmctld /var/log/slurm 2>/dev/null || true
    exec slurmctld -Dvvv

elif [ "$1" = "slurmd" ]; then

    # Force cgroup v1 plugin explicitly — v2 requires dbus which is not
    # available inside containers without a full systemd init
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
