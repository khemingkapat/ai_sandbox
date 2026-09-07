#!/bin/bash
# scripts/start-slinky.sh

echo "📦 Installing Slinky components..."
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
helm install slurm-operator-crds oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --namespace slinky --create-namespace
helm install slurm-operator oci://ghcr.io/slinkyproject/charts/slurm-operator --namespace slinky --wait
# Create slurm and workload namespaces and apply PV/PVC configuration
kubectl create namespace slurm --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace workload --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/pv-pvc.yaml

echo "🛠️ Building and loading custom Slurm images..."
./scripts/build-custom-images.sh

echo "⏳ Waiting for slurm-operator to be available..."
kubectl wait -n slinky --for=condition=available deployment/slurm-operator --timeout=300s

echo "🗄️ Deploying MariaDB for Slurm accounting..."
kubectl apply -f k8s/mariadb.yaml
echo "⏳ Waiting for MariaDB to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n slurm --timeout=120s

helm install slurm oci://ghcr.io/slinkyproject/charts/slurm --namespace slurm --create-namespace -f k8s/values.yaml

echo "⏳ Waiting for slurmctld to be ready (needed for token generation)..."
kubectl wait --for=condition=ready pod/slurm-controller-0 -n slurm --timeout=300s

echo "📊 Configuring accounting QoS and TRES limits..."
./scripts/setup-accounting.sh

echo "🔐 Generating SLURM_JWT token for slurm-bridge..."
BRIDGE_TOKEN=$(kubectl exec -n slurm slurm-controller-0 -c slurmctld -- scontrol token lifespan=unlimited | cut -d= -f2 | tr -d '\r')
kubectl create secret generic slurm-bridge-token -n slurm --from-literal=auth-token=$BRIDGE_TOKEN --dry-run=client -o yaml | kubectl apply -f -

echo "🌉 Deploying slurm-bridge..."
helm install slurm-bridge oci://ghcr.io/slinkyproject/charts/slurm-bridge --namespace slurm -f k8s/slurm-bridge-values.yaml --wait

echo "🏷️  Registering dedicated compute node (kind-worker3) with Slurm..."
kubectl label node kind-worker3 scheduler.slinky.slurm.net/slurm-bridge-external-node=true --overwrite
kubectl annotate node kind-worker3 scheduler.slinky.slurm.net/external-node-partitions=interactive,batch-cpu,batch-gpu,inference --overwrite

echo "🔧 Fixing inotify limits for Traefik file watcher..."
for node in $(kind get nodes); do
  docker exec $node sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288
done

echo "📦 Deploying in-cluster OCI registry..."
mkdir -p storage/registry
kubectl apply -f k8s/registry.yaml
echo "⏳ Waiting for local OCI registry to be ready..."
kubectl wait --for=condition=ready pod -l app=registry -n slurm --timeout=120s

echo "🔧 Configuring node containerd registry endpoints..."
for node in $(kind get nodes); do
  docker exec $node mkdir -p /etc/containerd/certs.d/localhost:5000
  cat <<'EOF' | docker exec -i $node tee /etc/containerd/certs.d/localhost:5000/hosts.toml > /dev/null
server = "http://kind-control-plane:5000"

[host."http://kind-control-plane:5000"]
  capabilities = ["pull", "resolve"]
EOF
done

echo "🏗️ Building and deploying HPC Portal..."
docker build -t hpc-portal:local -f portal/Dockerfile.portal portal/
kind load docker-image hpc-portal:local

echo "🛠️ Building and pushing interactive OCI images..."
./scripts/build-oci-images.sh

kubectl apply -f k8s/portal-rbac.yaml
kubectl apply -f k8s/portal-deployment.yaml
kubectl apply -f k8s/clean-scratch-cronjob.yaml

echo "📂 Initializing shared storage hierarchy and seeding baseline test models/datasets..."
docker exec -i kind-control-plane bash < scripts/init-storage.sh > /dev/null 2>&1 || true
docker exec -i kind-control-plane bash -s -- --test-mode < scripts/seed-models.sh > /dev/null 2>&1 || true
docker exec -i kind-control-plane bash -s -- --test-mode < scripts/seed-datasets.sh > /dev/null 2>&1 || true

echo "✅ Slinky, Storage, and HPC Portal are ready!"
