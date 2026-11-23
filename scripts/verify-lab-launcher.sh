#!/usr/bin/env bash
# scripts/verify-lab-launcher.sh
# Stage 2 Live Cluster Verification Probe for Unit WP12-B: One-Click Lab Launcher & RO Curriculum Mount.
set -euo pipefail

echo "=== [WP12-B Probe] One-Click Lab Launcher & RO Curriculum Mount ==="

PASS_COUNT=0
TOTAL_COUNT=0
SPAWNED_SESSION_ID=""

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

cleanup() {
  if [ -n "${SPAWNED_SESSION_ID}" ]; then
    echo "Cleaning up test session session-${SPAWNED_SESSION_ID}..."
    kubectl delete pod "session-${SPAWNED_SESSION_ID}" -n workload --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete svc "svc-${SPAWNED_SESSION_ID}" -n workload --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete ingress "ing-${SPAWNED_SESSION_ID}" -n workload --ignore-not-found=true >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Helper to mint a short-lived HS256 dev JWT matching the portal's UNIVERSITY_JWT_SECRET
mint_jwt() {
  local sub="$1"
  local role="$2"
  python3 - "$sub" "$role" <<'PY'
import base64, hashlib, hmac, json, sys, time
sub, role = sys.argv[1], sys.argv[2]
secret = b"mock-university-jwt-secret-shared-with-portal"
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
hdr = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
now = int(time.time())
pld = b64(json.dumps({
    "iss": "university-sso",
    "sub": sub,
    "aud": "cpe-ai-sandbox",
    "role": role,
    "iat": now,
    "exp": now + 600,
}, separators=(",", ":")).encode())
sig = b64(hmac.new(secret, f"{hdr}.{pld}".encode(), hashlib.sha256).digest())
print(f"{hdr}.{pld}.{sig}")
PY
}

# 1. Verify /mnt/storage/labs exists with 01_hello_sandbox.ipynb and 2775 / GID 2999
LABS_STAT=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- stat -c "%a:%g" /mnt/storage/labs 2>/dev/null || echo "missing")
LAB_FILE_OK=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- test -f /mnt/storage/labs/01_hello_sandbox.ipynb && echo "ok" || echo "missing")
if [ "${LABS_STAT}" = "2775:2999" ] && [ "${LAB_FILE_OK}" = "ok" ]; then
  report_check "/mnt/storage/labs seeded with 01_hello_sandbox.ipynb (mode 2775, GID 2999)" 0
else
  report_check "/mnt/storage/labs seeded with 01_hello_sandbox.ipynb (mode 2775, GID 2999)" 1 "stat=${LABS_STAT}, file=${LAB_FILE_OK}"
fi

STUDENT_JWT=$(mint_jwt "user1" "student")

# 2. Verify GET /api/labs dynamically lists starter notebooks
LABS_JSON=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -H "Authorization: Bearer ${STUDENT_JWT}" http://127.0.0.1:8080/api/labs 2>/dev/null || echo "")
if echo "${LABS_JSON}" | grep -q "01_hello_sandbox.ipynb"; then
  report_check "GET /api/labs dynamically returns 01_hello_sandbox.ipynb" 0
else
  report_check "GET /api/labs dynamically returns 01_hello_sandbox.ipynb" 1 "body=${LABS_JSON}"
fi

# 3. Verify path traversal rejection on GET /launch
TRAVERSAL_CODE=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${STUDENT_JWT}" "http://127.0.0.1:8080/launch?lab=../../etc/passwd" 2>/dev/null || echo "000")
if [ "${TRAVERSAL_CODE}" = "400" ]; then
  report_check "GET /launch?lab=../../etc/passwd rejected with 400 Bad Request" 0
else
  report_check "GET /launch?lab=../../etc/passwd rejected with 400 Bad Request" 1 "Got HTTP ${TRAVERSAL_CODE}"
fi

# 4. Verify student GET /launch?lab=01_hello_sandbox.ipynb spawns/reuses pod and redirects 302
LAUNCH_HEADERS=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -i -H "Authorization: Bearer ${STUDENT_JWT}" "http://127.0.0.1:8080/launch?lab=01_hello_sandbox.ipynb" 2>/dev/null || echo "")
LAUNCH_CODE=$(echo "${LAUNCH_HEADERS}" | awk 'NR==1 {print $2}')
LAUNCH_LOC=$(echo "${LAUNCH_HEADERS}" | grep -i "^Location:" | awk '{print $2}' | tr -d '\r')
if [ "${LAUNCH_CODE}" = "302" ] && echo "${LAUNCH_LOC}" | grep -qE "^/user1/jupyterlab/[0-9]+/lab/tree/labs/01_hello_sandbox\.ipynb$"; then
  SPAWNED_SESSION_ID=$(echo "${LAUNCH_LOC}" | sed -E 's|^/user1/jupyterlab/([0-9]+)/.*|\1|')
  report_check "GET /launch?lab=01_hello_sandbox.ipynb returns 302 -> ${LAUNCH_LOC}" 0
else
  report_check "GET /launch?lab=01_hello_sandbox.ipynb returns 302 -> /user1/jupyterlab/<id>/lab/tree/labs/01_hello_sandbox.ipynb" 1 "code=${LAUNCH_CODE}, loc=${LAUNCH_LOC}"
fi

# 5. Verify student pod mounts labs ReadOnly and kernel rejects writes with EROFS
if [ -n "${SPAWNED_SESSION_ID}" ]; then
  POD_RO=$(kubectl get pod -n workload "session-${SPAWNED_SESSION_ID}" -o jsonpath='{.spec.containers[0].volumeMounts[?(@.subPath=="labs")].readOnly}' 2>/dev/null || echo "")
  WRITE_ERR=$(kubectl exec -n workload "session-${SPAWNED_SESSION_ID}" -- sh -c 'touch /mnt/storage/projects/project1/labs/ro_probe.txt 2>&1 || true' 2>/dev/null || echo "")
  if [ "${POD_RO}" = "true" ] && echo "${WRITE_ERR}" | grep -qiE "read-only|permission denied"; then
    report_check "Student pod mounts labs ReadOnly=true and blocks writes (${WRITE_ERR})" 0
  else
    report_check "Student pod mounts labs ReadOnly=true and blocks writes" 1 "readOnly=${POD_RO}, err=${WRITE_ERR}"
  fi
else
  report_check "Student pod mounts labs ReadOnly=true and blocks writes" 1 "No session pod spawned"
fi

# 6. Verify POST /api/labs/clone copies notebook into writable my_labs/
CLONE_RESP=$(kubectl exec -n slurm deploy/hpc-portal -c portal -- curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer ${STUDENT_JWT}" -H "Content-Type: application/json" -d '{"lab":"01_hello_sandbox.ipynb"}' http://127.0.0.1:8080/api/labs/clone 2>/dev/null || echo "")
CLONE_CODE=$(echo "${CLONE_RESP}" | tail -n1)
if [ "${CLONE_CODE}" = "200" ] && echo "${CLONE_RESP}" | grep -q "my_labs/"; then
  report_check "POST /api/labs/clone copies lab to writable my_labs/ (HTTP 200)" 0
else
  report_check "POST /api/labs/clone copies lab to writable my_labs/ (HTTP 200)" 1 "code=${CLONE_CODE}, body=${CLONE_RESP}"
fi

echo "=== Summary: ${PASS_COUNT}/${TOTAL_COUNT} checks passed ==="
if [ "${PASS_COUNT}" -eq "${TOTAL_COUNT}" ]; then
  exit 0
else
  exit 1
fi
