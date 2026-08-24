#!/bin/bash
# scripts/build-oci-images.sh
set -euo pipefail

echo "🐳 Building interactive OCI images..."

# 1. Build JupyterLab image
echo "  - Building interactive-jupyter:latest..."
docker build -t interactive-jupyter:latest -t localhost:5000/interactive-jupyter:latest images/jupyterlab/

# 2. Build Code-server image
echo "  - Building interactive-codeserver:latest..."
docker build -t interactive-codeserver:latest -t localhost:5000/interactive-codeserver:latest images/codeserver/

# 3. Build Bash image
echo "  - Building interactive-bash:latest..."
docker build -t interactive-bash:latest -t localhost:5000/interactive-bash:latest images/bash/

echo "🚀 Pushing interactive images to local OCI registry (localhost:5000)..."
docker push localhost:5000/interactive-jupyter:latest
docker push localhost:5000/interactive-codeserver:latest
docker push localhost:5000/interactive-bash:latest

echo "✅ Interactive images built and pushed successfully!"
