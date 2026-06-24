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
RUN apt-get update && apt-get install -y libnss-extrausers && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN sed -i 's/passwd:\s*files/passwd:         files extrausers/g' /etc/nsswitch.conf
RUN sed -i 's/group:\s*files/group:          files extrausers/g' /etc/nsswitch.conf
EOF

echo "🚀 Loading custom images into Kind cluster..."
kind load docker-image slurmctld-custom:latest
kind load docker-image slurmrestd-custom:latest
kind load docker-image slurmd-custom:latest

echo "✅ Custom Slurm images built and loaded successfully!"
