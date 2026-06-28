#!/bin/bash
# scripts/build-custom-images.sh
set -euo pipefail

echo "🐳 Building custom Slurm images with libnss-extrausers..."

# 1. Build custom slurmctld
echo "  - Building slurmctld-custom:latest..."
docker build -t slurmctld-custom:latest - <<EOF
FROM ghcr.io/slinkyproject/slurmctld:25.11-ubuntu24.04
USER root
RUN apt-get update && apt-get install -y libnss-extrausers && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf
RUN sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf
USER slurm
EOF

# 2. Build custom slurmrestd
echo "  - Building slurmrestd-custom:latest..."
docker build -t slurmrestd-custom:latest - <<EOF
FROM ghcr.io/slinkyproject/slurmrestd:25.11-ubuntu24.04
USER root
RUN apt-get update && apt-get install -y libnss-extrausers && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf
RUN sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf
USER nobody
EOF

# 3. Build custom slurmd
echo "  - Building slurmd-custom:latest..."
docker build -t slurmd-custom:latest - <<EOF
FROM ghcr.io/slinkyproject/slurmd:25.11-ubuntu24.04
USER root
RUN apt-get update && apt-get install -y libnss-extrausers curl wget && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf
RUN sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf

# Install Apptainer and Apptainer-SUID for proot fallback
RUN APPTAINER_VERSION=1.3.6 && \\
    wget -q "https://github.com/apptainer/apptainer/releases/download/v\${APPTAINER_VERSION}/apptainer_\${APPTAINER_VERSION}_amd64.deb" -O /tmp/apptainer.deb && \\
    wget -q "https://github.com/apptainer/apptainer/releases/download/v\${APPTAINER_VERSION}/apptainer-suid_\${APPTAINER_VERSION}_amd64.deb" -O /tmp/apptainer-suid.deb && \\
    apt-get update && apt-get install -y /tmp/apptainer.deb /tmp/apptainer-suid.deb && \\
    rm /tmp/apptainer.deb /tmp/apptainer-suid.deb && apt-get clean

# Install proot static binary
RUN curl -fsSL https://github.com/proot-me/proot/releases/download/v5.3.0/proot-v5.3.0-x86_64-static -o /usr/local/bin/proot && \\
    chmod +x /usr/local/bin/proot

# Configure Apptainer: disable setuid (triggers proot fallback) and set proot path
RUN echo "proot path = /usr/local/bin/proot" >> /etc/apptainer/apptainer.conf

# Add user subuid/subgid (in case it is needed)
RUN echo "slurm:100000:65536" >> /etc/subuid && \\
    echo "slurm:100000:65536" >> /etc/subgid && \\
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap || true

# Verify starter-suid exists
RUN ls -la /usr/libexec/apptainer/bin/starter-suid
EOF

echo "🚀 Loading custom images into Kind cluster..."
kind load docker-image slurmctld-custom:latest
kind load docker-image slurmrestd-custom:latest
kind load docker-image slurmd-custom:latest

echo "✅ Custom Slurm images built and loaded successfully!"
