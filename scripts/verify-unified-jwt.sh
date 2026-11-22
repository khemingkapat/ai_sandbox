#!/usr/bin/env bash
# scripts/verify-unified-jwt.sh
# Stage 2 Live Cluster Verification Probe for Unit WP12-A: Unified JWT v1.2.0, SSO Bridge & 3-Tier RBAC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== [WP12-A Probe] Unified JWT v1.2.0, SSO Bridge & 3-Tier RBAC ==="

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

# 1. Check Traefik Security ConfigMap contains ForwardAuth alignment or auth routes
TRAEFIK_CONFIG=$(kubectl get cm -n slurm traefik-security-config -o jsonpath='{.data.security\.yaml}' 2>/dev/null || echo "")
if [ -n "${TRAEFIK_CONFIG}" ]; then
  report_check "Traefik security ConfigMap exists in slurm namespace" 0
else
  report_check "Traefik security ConfigMap exists in slurm namespace" 1 "Missing traefik-security-config"
fi

# 2. Check Portal Deployment in slurm namespace is Ready
PORTAL_READY=$(kubectl get deploy -n slurm hpc-portal -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${PORTAL_READY}" -ge 1 ]; then
  report_check "Portal deployment Ready in slurm namespace" 0
else
  report_check "Portal deployment Ready in slurm namespace" 1 "Ready replicas: ${PORTAL_READY}"
fi

# 3. Test unauthenticated /api/auth/verify returns 401 for API client
VERIFY_API_STATUS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/json" http://127.0.0.1:8080/api/auth/verify 2>/dev/null || echo "000")
if [ "${VERIFY_API_STATUS}" = "401" ]; then
  report_check "Unauthenticated API request to /api/auth/verify returns 401" 0
else
  report_check "Unauthenticated API request to /api/auth/verify returns 401" 1 "Got status: ${VERIFY_API_STATUS}"
fi

# 4. Test unauthenticated /api/auth/verify returns 302 for HTML client
VERIFY_HTML_STATUS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" -H "Accept: text/html" http://127.0.0.1:8080/api/auth/verify 2>/dev/null || echo "000")
if [ "${VERIFY_HTML_STATUS}" = "302" ]; then
  report_check "Unauthenticated HTML request to /api/auth/verify returns 302 redirect" 0
else
  report_check "Unauthenticated HTML request to /api/auth/verify returns 302 redirect" 1 "Got status: ${VERIFY_HTML_STATUS}"
fi

# 5. Test /api/auth/sso rejects missing/empty token with 401
SSO_EMPTY_STATUS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/auth/sso 2>/dev/null || echo "000")
if [ "${SSO_EMPTY_STATUS}" = "401" ]; then
  report_check "Missing token to /api/auth/sso returns 401" 0
else
  report_check "Missing token to /api/auth/sso returns 401" 1 "Got status: ${SSO_EMPTY_STATUS}"
fi

# 6. Test /api/admin/status rejects unauthenticated or student requests with 401 or 403
ADMIN_STATUS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/admin/status 2>/dev/null || echo "000")
if [ "${ADMIN_STATUS}" = "401" ] || [ "${ADMIN_STATUS}" = "403" ]; then
  report_check "Unauthenticated access to /api/admin/status denied (401/403)" 0
else
  report_check "Unauthenticated access to /api/admin/status denied" 1 "Got status: ${ADMIN_STATUS}"
fi

echo "=== Summary: ${PASS_COUNT}/${TOTAL_COUNT} checks passed ==="
if [ "${PASS_COUNT}" -eq "${TOTAL_COUNT}" ]; then
  exit 0
else
  exit 1
fi
