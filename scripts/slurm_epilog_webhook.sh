#!/bin/bash
# Slurm Epilog script to send job metrics to the central portal

CENTRAL_PORTAL_URL="http://localhost:8080/api/webhook/slurm"

# Slurm passes several environment variables to the Epilog script.
# We extract them to form our payload.
JOB_ID=${SLURM_JOB_ID:-unknown}
USER_ID=${SLURM_JOB_USER:-unknown}
ACCOUNT=${SLURM_JOB_ACCOUNT:-unknown}
PARTITION=${SLURM_JOB_PARTITION:-unknown}
NODELIST=${SLURM_JOB_NODELIST:-unknown}

# Prepare JSON payload
PAYLOAD=$(cat <<EOF
{
  "job_id": "$JOB_ID",
  "user": "$USER_ID",
  "account": "$ACCOUNT",
  "partition": "$PARTITION",
  "nodelist": "$NODELIST",
  "event": "job_completed",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

# Send to the portal
curl -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$CENTRAL_PORTAL_URL" --max-time 5
