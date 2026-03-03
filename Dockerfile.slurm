FROM rockylinux:9

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
      && \
    dnf clean all && \
    ln -sf /usr/bin/python3 /usr/bin/python

# Install Python packages globally — add whatever your jobs need here
RUN pip3 install --no-cache-dir \
      numpy \
      pandas \
      scipy

RUN groupadd -r slurm 2>/dev/null || true && \
    useradd -r -g slurm -d /var/lib/slurm -s /sbin/nologin slurm 2>/dev/null || true && \
    groupadd -r munge 2>/dev/null || true && \
    useradd -r -g munge -d /var/lib/munge -s /sbin/nologin munge 2>/dev/null || true

RUN mkdir -p \
      /var/spool/slurmctld \
      /var/spool/slurmd \
      /var/log/slurm \
      /var/lib/slurm \
      /var/run/slurm \
      /var/run/munge \
      /var/lib/munge \
      /etc/slurm && \
    chown -R slurm:slurm \
      /var/spool/slurmctld \
      /var/spool/slurmd \
      /var/log/slurm \
      /var/lib/slurm \
      /var/run/slurm && \
    chown -R munge:munge \
      /var/run/munge \
      /var/lib/munge

RUN /sbin/create-munge-key

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
