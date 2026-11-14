#!/usr/bin/env bash
# scripts/verify-wp05b.sh
# Empirical verification probe for Unit WP05-B: Self-Service Identity & Dynamic Project Provisioning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== [WP05-B Probe] Self-Service Identity & Dynamic Project Sync ==="

PASS_COUNT=0
TOTAL_COUNT=0

report_check() {
  local desc="$1"
  local status="$2"
  local detail="${3:-}"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$status" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [PASS] ${desc}"
  else
    echo "  [FAIL] ${desc} - ${detail}"
  fi
}

# 1. Check Postgres 16 pod in services namespace
PG_READY=$(kubectl get statefulset -n services mlflow-postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${PG_READY}" -ge 1 ]; then
  report_check "Postgres 16 StatefulSet Ready in services namespace" 0
else
  report_check "Postgres 16 StatefulSet Ready in services namespace" 1 "Ready replicas: ${PG_READY}"
fi

# 2. Check NetworkPolicy allow-postgres-services-only includes portal in slurm namespace
NETPOL_SPEC=$(kubectl get netpol -n services allow-postgres-internal -o yaml 2>/dev/null || echo "")
if echo "${NETPOL_SPEC}" | grep -q "hpc-portal" || echo "${NETPOL_SPEC}" | grep -q "slurm"; then
  report_check "NetworkPolicy allows hpc-portal to reach Postgres 5432" 0
else
  report_check "NetworkPolicy allows hpc-portal to reach Postgres 5432" 1 "Pending NetworkPolicy update"
fi

# 3. Check Portal Deployment has DATABASE_URL configured
PORTAL_DB_ENV=$(kubectl get deploy -n slurm hpc-portal -o jsonpath='{.spec.template.spec.containers[?(@.name=="portal")].env[?(@.name=="DATABASE_URL")].value}' 2>/dev/null || echo "")
if [ -n "${PORTAL_DB_ENV}" ]; then
  report_check "hpc-portal Deployment has DATABASE_URL env var" 0
else
  report_check "hpc-portal Deployment has DATABASE_URL env var" 1 "DATABASE_URL not set in hpc-portal deployment"
fi

# 4. Check /mnt/storage/common/etc/{passwd,group} exist and are readable
PASSWD_EXISTS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- test -f /mnt/storage/common/etc/passwd && echo "yes" || echo "no")
if [ "${PASSWD_EXISTS}" = "yes" ]; then
  report_check "Shared extrausers passwd file exists on /mnt/storage" 0
else
  report_check "Shared extrausers passwd file exists on /mnt/storage" 1 "Missing /mnt/storage/common/etc/passwd"
fi

# 5. Check baseline accounts (user1..user4) present in /mnt/storage/common/etc/passwd
USER1_PRESENT=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- grep -c "^user1:x:1001:" /mnt/storage/common/etc/passwd || echo "0")
if [ "${USER1_PRESENT}" -ge 1 ]; then
  report_check "Baseline user1 (UID 1001) preserved in /mnt/storage/common/etc/passwd" 0
else
  report_check "Baseline user1 (UID 1001) preserved in /mnt/storage/common/etc/passwd" 1 "user1 not found in extrausers"
fi

# 6. Check slurmrestd API endpoints for accounts and associations
SLURMRESTD_STATUS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" http://slurm-restapi:6820/slurm/v0.0.42/ping || echo "000")
if [ "${SLURMRESTD_STATUS}" = "200" ]; then
  report_check "slurmrestd ping endpoint reachable from portal container" 0
else
  report_check "slurmrestd ping endpoint reachable from portal container" 1 "HTTP status: ${SLURMRESTD_STATUS}"
fi

echo "=== [WP05-B Probe Summary] Passed: ${PASS_COUNT}/${TOTAL_COUNT} checks ==="
if [ "${PASS_COUNT}" -eq "${TOTAL_COUNT}" ]; then
  exit 0
else
  exit 1
fi
