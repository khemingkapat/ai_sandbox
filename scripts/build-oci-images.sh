#!/bin/bash
# scripts/build-oci-images.sh
set -euo pipefail

echo "🐳 Building interactive OCI images..."

# 1. Build JupyterLab image
echo "  - Building interactive-jupyter:latest..."
docker build -t interactive-jupyter:latest images/jupyterlab/

# 2. Build Code-server image
echo "  - Building interactive-codeserver:latest..."
docker build -t interactive-codeserver:latest images/codeserver/

# 3. Build Bash image
echo "  - Building interactive-bash:latest..."
docker build -t interactive-bash:latest images/bash/

echo "🚀 Loading interactive images into Kind cluster..."
kind load docker-image interactive-jupyter:latest
kind load docker-image interactive-codeserver:latest
kind load docker-image interactive-bash:latest

echo "✅ Interactive images built and loaded successfully!"
