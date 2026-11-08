#!/bin/bash
set -euo pipefail

# Create temporary directory for certificate generation
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

KEY_PATH="$TMP_DIR/tls.key"
CRT_PATH="$TMP_DIR/tls.crt"

echo "🔐 Generating self-signed TLS certificate and private key..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$KEY_PATH" \
  -out "$CRT_PATH" \
  -subj "/CN=portal" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:portal,DNS:portal.slurm.svc.cluster.local,DNS:*.sandbox.local"

echo "📦 Creating/updating Kubernetes Secret traefik-tls-cert in namespace slurm..."
kubectl create secret generic traefik-tls-cert \
  --namespace slurm \
  --from-file=tls.crt="$CRT_PATH" \
  --from-file=tls.key="$KEY_PATH" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ TLS secret traefik-tls-cert successfully updated."
