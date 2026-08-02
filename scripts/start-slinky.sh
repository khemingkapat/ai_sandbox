#!/bin/bash
# scripts/start-slinky.sh

echo "📦 Installing Slinky components..."
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --namespace slinky --create-namespace
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --namespace slinky --wait
# Create slurm namespace and apply PV/PVC configuration
kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/pv-pvc.yaml

echo "🛠️ Building and loading custom Slurm images..."
./scripts/build-custom-images.sh

echo "⏳ Waiting for slurm-operator-controller-manager to be available..."
kubectl wait -n slinky --for=condition=available deployment/slurm-operator-controller-manager --timeout=300s

echo "📦 Applying declarative SlurmCluster CRD..."
kubectl apply -f k8s/slurm-cluster.yaml

echo "⏳ Waiting for slurmctld to be ready (needed for token generation)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=slurmctld -n slurm --timeout=300s

echo "🔐 Generating SLURM_JWT token for slurm-bridge..."
BRIDGE_TOKEN=$(kubectl exec -n slurm slurm-controller-0 -c slurmctld -- scontrol token lifespan=unlimited | cut -d= -f2 | tr -d '\r')
kubectl create secret generic slurm-bridge-token -n slurm --from-literal=auth-token=$BRIDGE_TOKEN --dry-run=client -o yaml | kubectl apply -f -

echo "🌉 Deploying slurm-bridge..."
helm install slurm-bridge oci://ghcr.io/slinkyproject/charts/slurm-bridge --namespace slurm -f k8s/slurm-bridge-values.yaml --wait

echo "🏷️  Registering dedicated compute node (kind-worker3) with Slurm..."
kubectl label node kind-worker3 scheduler.slinky.slurm.net/slurm-bridge-external-node=true --overwrite
kubectl annotate node kind-worker3 scheduler.slinky.slurm.net/external-node-partitions=all --overwrite

echo "🔧 Fixing inotify limits for Traefik file watcher..."
for node in $(kind get nodes); do
  docker exec $node sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288
done

echo "🏗️ Building and deploying HPC Portal..."
docker build -t hpc-portal:local -f portal/Dockerfile.portal portal/
kind load docker-image hpc-portal:local

echo "🛠️ Building and loading interactive OCI images..."
./scripts/build-oci-images.sh

kubectl apply -f k8s/portal-rbac.yaml
kubectl apply -f k8s/portal-deployment.yaml

echo "✅ Slinky and HPC Portal are ready!"
