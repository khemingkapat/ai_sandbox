#!/bin/bash
# scripts/start-slinky.sh

echo "📦 Installing Slinky components..."
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --namespace slinky --create-namespace
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --namespace slinky --wait
helm install slurm oci://ghcr.io/slinkyproject/charts/slurm --namespace slurm --create-namespace -f values.yaml
echo "✅ Slinky is ready!"
