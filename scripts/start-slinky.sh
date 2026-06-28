#!/bin/bash
# scripts/start-slinky.sh

echo "📦 Installing Slinky components..."
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --namespace slinky --create-namespace
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --namespace slinky --wait
# Create slurm namespace and apply PV/PVC configuration
kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f pv-pvc.yaml

helm install slurm oci://ghcr.io/slinkyproject/charts/slurm --namespace slurm --create-namespace -f values.yaml

echo "🏗️ Building and deploying HPC Portal..."
docker build -t hpc-portal:local -f portal/Dockerfile.portal portal/
kind load docker-image hpc-portal:local
kubectl apply -f portal-deployment.yaml

echo "✅ Slinky and HPC Portal are ready!"
