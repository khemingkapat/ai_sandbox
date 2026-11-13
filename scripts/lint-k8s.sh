#!/usr/bin/env bash
# ==============================================================================
# lint-k8s.sh
# Kubernetes Manifest Linter & Schema Validator
# Filters out Helm values and non-Kubernetes resource configs.
# ==============================================================================
set -euo pipefail

echo "=============================================================================="
echo "☸️  Kubernetes Manifest Validation"
echo "=============================================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

# Find all yaml files in k8s/ excluding helm values and kind configs
MANIFEST_FILES=$(find "$ROOT_DIR/k8s" -type f \( -name "*.yaml" -o -name "*.yml" \) \
  ! -name "*values*" \
  ! -name "kind-config.yaml" \
  ! -name "slurm-cluster.yaml" | sort)

echo "Found $(echo "$MANIFEST_FILES" | wc -l) manifest files to validate."

if command -v kubeconform >/dev/null 2>&1; then
  echo "Using kubeconform for schema validation..."
  for file in $MANIFEST_FILES; do
    rel_path="${file#$ROOT_DIR/}"
    if kubeconform -summary -schema-location default -ignore-missing-schemas "$file"; then
      echo "  ✅ $rel_path"
    else
      echo "  ❌ $rel_path schema validation failed."
      FAILURES=$((FAILURES + 1))
    fi
  done
elif command -v kubectl >/dev/null 2>&1; then
  echo "kubeconform not found; using kubectl apply --dry-run=client..."
  for file in $MANIFEST_FILES; do
    rel_path="${file#$ROOT_DIR/}"
    if kubectl apply --dry-run=client -f "$file" >/dev/null 2>&1; then
      echo "  ✅ $rel_path"
    else
      echo "  ❌ $rel_path failed client validation."
      FAILURES=$((FAILURES + 1))
    fi
  done
else
  echo "❌ Neither kubeconform nor kubectl found."
  exit 1
fi

if command -v kube-linter >/dev/null 2>&1; then
  echo ""
  echo "Using kube-linter for security and best-practice checks..."
  if kube-linter lint --config "$ROOT_DIR/.kube-linter.yaml" "$ROOT_DIR/k8s"; then
    echo "  ✅ Security and best-practice checks passed."
  else
    echo "  ❌ kube-linter reported policy violations."
    FAILURES=$((FAILURES + 1))
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "❌ $FAILURES manifest(s) failed validation."
  exit 1
fi

echo "✅ All Kubernetes manifests passed validation."
exit 0
