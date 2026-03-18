FROM rockylinux:9

# Install base dependencies
RUN dnf install -y epel-release && \
    dnf install -y \
      slurm \
      slurm-slurmctld \
      slurm-slurmd \
      munge \
      munge-libs \
      bash \
      procps-ng \
      python3 \
      python3-pip \
      sudo \
      && \
    dnf clean all && \
    ln -sf /usr/bin/python3 /usr/bin/python

# Create the sandbox-user with a fixed UID (Phase 1: Unified Identity)
# This ensures that files created on the host or other nodes have consistent permissions
RUN groupadd -g 1000 sandbox-group && \
    useradd -u 1000 -g 1000 -m -s /bin/bash sandbox-user && \
    echo "sandbox-user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Python packages globally
RUN pip3 install --no-cache-dir \
      numpy \
      pandas \
      scipy

# Slurm and Munge system users
RUN groupadd -r slurm 2>/dev/null || true && \
    useradd -r -g slurm -d /var/lib/slurm -s /sbin/nologin slurm 2>/dev/null || true && \
    groupadd -r munge 2>/dev/null || true && \
    useradd -r -g munge -d /var/lib/munge -s /sbin/nologin munge 2>/dev/null || true

# Prepare necessary directories
RUN mkdir -p \
      /var/spool/slurmctld \
      /var/spool/slurmd \
      /var/log/slurm \
      /var/lib/slurm \
      /var/run/slurm \
      /var/run/munge \
      /var/lib/munge \
      /etc/slurm \
      /mnt/storage/users \
      /mnt/storage/projects \
      /mnt/storage/public && \
    chown -R slurm:slurm \
      /var/spool/slurmctld \
      /var/spool/slurmd \
      /var/log/slurm \
      /var/lib/slurm \
      /var/run/slurm && \
    chown -R munge:munge \
      /var/run/munge \
      /var/lib/munge && \
    # Ensure the sandbox-user owns the base mount points initially
    chown -R sandbox-user:sandbox-group /mnt/storage

RUN /sbin/create-munge-key

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
