#!/usr/bin/env bash
# ==============================================================================
# scripts/slurm_epilog_webhook.sh: Hardened Slurm Epilog Incident Webhook
#
# Safety Contract:
# 1. Non-blocking: forks a fully detached background subshell and exits 0
#    immediately (<5ms) so slurmd never hangs or marks worker nodes DRAIN/DOWN.
# 2. Failure-only: exits immediately if job succeeded (exit_code == 0).
# 3. Security: rejects symlinks (! -L) and confines log reads to project directory.
# 4. Sanitization: limits log snippet to last 50 lines / max 4096 bytes.
# ==============================================================================

# Background worker subshell - fully detached from slurmd standard descriptors
(
  # Slurm environment variables
  JOB_ID="${SLURM_JOB_ID:-unknown}"
  USER_ID="${SLURM_JOB_USER:-unknown}"
  ACCOUNT="${SLURM_JOB_ACCOUNT:-unknown}"
  PARTITION="${SLURM_JOB_PARTITION:-unknown}"
  NODELIST="${SLURM_JOB_NODELIST:-$(hostname)}"
  RAW_EXIT_CODE="${SLURM_JOB_EXIT_CODE:-0}"
  JOB_STATE="${SLURM_JOB_STATE:-FAILED}"

  # Parse numeric exit code (Slurm often exports EXIT_CODE:SIGNAL, e.g. "1:0" or "0:0")
  EXIT_CODE="${RAW_EXIT_CODE%%:*}"
  if ! [[ "${EXIT_CODE}" =~ ^-?[0-9]+$ ]]; then
    EXIT_CODE=0
  fi

  # Filter: If job completed successfully with exit code 0, do not dispatch incident
  if [ "${EXIT_CODE}" -eq 0 ] && [ "${JOB_STATE}" = "COMPLETED" ]; then
    exit 0
  fi

  # Determine portal URL and token
  PORTAL_URL="${CENTRAL_PORTAL_URL:-http://portal.slurm.svc.cluster.local:8080/api/internal/webhook/slurm}"
  TOKEN="${TELEMETRY_TOKEN:-${TELEMETRY_SECRET:-}}"

  # Discover and sanitize crash log tail
  LOG_TAIL=""
  PROJECT_LOG_DIR="${STORAGE_ROOT:-/mnt/storage}/projects/${ACCOUNT}/logs"

  if [ -d "${PROJECT_LOG_DIR}" ]; then
    REAL_LOG_DIR="$(realpath "${PROJECT_LOG_DIR}" 2>/dev/null || true)"
    # Prefer stderr (*_<jobid>.err), fallback to stdout (*_<jobid>.out)
    for CANDIDATE in "${PROJECT_LOG_DIR}"/*_"${JOB_ID}".err "${PROJECT_LOG_DIR}"/*_"${JOB_ID}".out; do
      if [ -f "${CANDIDATE}" ] && [ ! -L "${CANDIDATE}" ]; then
        REAL_CANDIDATE="$(realpath "${CANDIDATE}" 2>/dev/null || true)"
        # Symlink / Traversal guard: ensure resolved path is strictly inside project log directory
        if [[ -n "${REAL_LOG_DIR}" && "${REAL_CANDIDATE}" == "${REAL_LOG_DIR}"* ]]; then
          LOG_TAIL="$(tail -n 50 "${CANDIDATE}" 2>/dev/null | tail -c 4096 | tr -d '\000-\010\013\014\016-\037' || true)"
          if [ -n "${LOG_TAIL}" ]; then
            break
          fi
        fi
      fi
    done
  fi

  # Construct JSON payload safely
  if command -v python3 >/dev/null 2>&1; then
    PAYLOAD=$(JOB_ID="${JOB_ID}" USER_ID="${USER_ID}" ACCOUNT="${ACCOUNT}" \
      PARTITION="${PARTITION}" NODELIST="${NODELIST}" EXIT_CODE="${EXIT_CODE}" \
      JOB_STATE="${JOB_STATE}" LOG_TAIL="${LOG_TAIL}" python3 -c '
import os, sys, json
payload = {
    "job_id": os.environ.get("JOB_ID", "unknown"),
    "user": os.environ.get("USER_ID", "unknown"),
    "account": os.environ.get("ACCOUNT", "unknown"),
    "partition": os.environ.get("PARTITION", "unknown"),
    "nodelist": os.environ.get("NODELIST", "unknown"),
    "exit_code": int(os.environ.get("EXIT_CODE", 0)),
    "status": os.environ.get("JOB_STATE", "FAILED"),
    "log_tail": os.environ.get("LOG_TAIL", "")
}
print(json.dumps(payload))
' 2>/dev/null)
  fi

  # Fallback to pure bash JSON if python3 is unavailable
  if [ -z "${PAYLOAD:-}" ]; then
    ESCAPED_LOG="${LOG_TAIL//\\/\\\\}"
    ESCAPED_LOG="${ESCAPED_LOG//\"/\\\"}"
    ESCAPED_LOG="$(printf '%s' "${ESCAPED_LOG}" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')"
    PAYLOAD="{\"job_id\":\"${JOB_ID}\",\"user\":\"${USER_ID}\",\"account\":\"${ACCOUNT}\",\"partition\":\"${PARTITION}\",\"nodelist\":\"${NODELIST}\",\"exit_code\":${EXIT_CODE},\"status\":\"${JOB_STATE}\",\"log_tail\":\"${ESCAPED_LOG}\"}"
  fi

  # Dispatch HTTP POST with strict 2-second timeout
  AUTH_HEADER=()
  if [ -n "${TOKEN}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
  fi

  curl -s -S -X POST \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "${PAYLOAD}" \
    "${PORTAL_URL}" \
    --max-time 2 >/dev/null 2>&1 || true

) </dev/null >/dev/null 2>&1 &

# Epilog must exit 0 immediately to prevent slurmd from draining nodes
exit 0
