# Unit: WP13 — Slurm Epilog Webhook & Incident Ring Buffer

Status: done (Gate D)
Parent GitHub WP: #13
Exploratory? no

## Intent
Surface real-time Slurm batch job crashes (non-zero exit codes, OOM kills, and runtime exceptions) to cluster administrators via an asynchronous Slurm epilog webhook (`scripts/slurm_epilog_webhook.sh`) and a zero-dependency, thread-safe 200-slot in-memory circular ring buffer in the Go Web Portal (`portal/`). This eliminates the silent batch failure blind spot without risking `slurmd` node drains, SQLite/NFS file locking, or intra-cluster spoofing.

## Scope & Non-goals
- **In scope:**
  - **Hardened Asynchronous Epilog Script (`scripts/slurm_epilog_webhook.sh` & `k8s/values.yaml`):**
    - Forks a fully detached background subshell `( ... ) </dev/null >/dev/null 2>&1 &` and exits `0` immediately (<5ms) so `slurmd` never hangs or drains compute/GPU nodes.
    - Inspects `SLURM_JOB_EXIT_CODE` / `SLURM_JOB_STATE`; only dispatches incident webhooks on failed/non-zero jobs.
    - Safely extracts the last 50 lines (max 4096 bytes) of the job's `.err` / `.out` log under `/mnt/storage/projects/${SLURM_JOB_ACCOUNT}/logs/`, strictly rejecting symlinks (`! -L`) and path traversal outside the project log directory.
    - Encodes valid JSON (escaping quotes/newlines safely) and `POST`s to `http://portal.slurm.svc.cluster.local:8080/api/internal/webhook/slurm` with `Authorization: Bearer ${TELEMETRY_TOKEN}` and `--max-time 2`.
  - **Webhook Ingest Endpoint (`POST /api/internal/webhook/slurm`):**
    - Protected by pre-shared Bearer token (`TELEMETRY_TOKEN`, fail-closed when unconfigured or mismatched).
    - Enforces a 16KB request body ceiling (`http.MaxBytesReader`) to prevent memory exhaustion.
    - Ignores normal job completions (`exit_code == 0` and `status == "COMPLETED"`) so hyperparameter sweeps do not evict real crashes.
    - Sanitizes and truncates `log_tail` server-side to at most 4096 bytes of printable UTF-8 characters (preserving `\n` and `\t`).
    - Excluded from public Swagger documentation (internal ingest route).
  - **Thread-Safe 200-Slot Circular Ring Buffer (`portal/telemetry.go`):**
    - Implemented with `container/ring` and `sync.RWMutex` inside `TelemetryScraper` (capacity = 200 incidents, <2MB RAM, zero disk/SQLite I/O).
    - Overwrites the oldest incident deterministically when the 201st incident arrives.
  - **Admin Incident Egress Endpoint (`GET /api/v1/telemetry/incidents`):**
    - Protected by `Authorization: Bearer <TELEMETRY_TOKEN>` (fail-closed).
    - Supports optional query parameters `?since=<RFC3339>` and `?limit=<N>` (default 50, max 200).
    - Returns incidents in reverse chronological order (newest first).
    - Documented in OpenAPI / Swagger (`portal/docs/`).
- **Non-goals:**
  - Persistent on-disk database storage (SQLite/Postgres) for ephemeral job logs.
  - Storing successful (`exit_code == 0`) batch jobs in the incident ring buffer.
  - Exposing raw cross-project incident feeds to unauthenticated users or student session cookies.

## Constraints and decisions to respect
- [ADR 0001: Two-Path Workload Execution Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0001-two-path-workload-execution.md)
- [ADR 0002: Storage and UID/GID Isolation Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- [ADR 0004: Central Services Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md)
- **Resolved Strategic Decisions (Khem):**
  1. **Failures Only:** Only failed/non-zero exit jobs are stored in the 200-slot ring buffer.
  2. **Bearer Token Auth:** Ingest webhook (`POST /api/internal/webhook/slurm`) requires `Authorization: Bearer <TELEMETRY_TOKEN>` to prevent intra-cluster student spoofing.
  3. **Sanitized 4KB Log Tail:** Include up to 4KB of sanitized log output in incident payloads for rapid root-cause triage.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp13-slurm-epilog-webhook.md` | Unit specification and bolt log |
| `docs/aidlc/UNITS.md` | Flip WP13 unit status |
| `portal/telemetry.go` | Incident structs, 200-slot `container/ring` buffer, webhook ingest & egress handlers |
| `portal/telemetry_test.go` | Gate C locked unit tests (`-race`) |
| `portal/main.go` | Route registration for `/api/internal/webhook/slurm` and `/api/v1/telemetry/incidents` |
| `portal/docs/docs.go` | Generated OpenAPI spec for `/api/v1/telemetry/incidents` |
| `portal/docs/swagger.json` | Generated OpenAPI JSON |
| `portal/docs/swagger.yaml` | Generated OpenAPI YAML |
| `scripts/slurm_epilog_webhook.sh` | Hardened non-blocking Slurm epilog webhook script |
| `k8s/values.yaml` | Sync `epilogScripts.01-webhook.sh` with hardened epilog script |

## Implementation Plan (Bundled for Gate A+B)
1. **Ring Buffer & Handlers (`portal/telemetry.go`, `portal/main.go`):**
   - Define `SlurmIncident` and `SlurmWebhookPayload` structs matching the schema (`incident_id`, `timestamp`, `source_type`, `entity_id`, `user`, `account`, `partition`, `exit_code`, `status`, `summary`, `log_tail`).
   - Add `incidentRing *ring.Ring` (size 200) protected by `mu sync.RWMutex` to `TelemetryScraper`.
   - Implement `HandleSlurmWebhook(c echo.Context)` on `POST /api/internal/webhook/slurm`: verify Bearer token, enforce 16KB body limit, ignore `exit_code == 0 && status == "COMPLETED"`, sanitize/truncate `log_tail` to 4096 bytes, and push onto ring buffer.
   - Implement `HandleTelemetryIncidents(c echo.Context)` on `GET /api/v1/telemetry/incidents`: verify Bearer token, parse `since` (RFC3339) and `limit` (1..200, default 50), and return matching incidents newest-first.
   - Regenerate Swagger docs (`swag init`) ensuring `/api/v1/telemetry/incidents` is documented and `/api/internal/webhook/slurm` remains excluded.
2. **Hardened Epilog Script (`scripts/slurm_epilog_webhook.sh` & `k8s/values.yaml`):**
   - Wrap all work in `( ... ) </dev/null >/dev/null 2>&1 &` and `exit 0` at top-level.
   - Parse `SLURM_JOB_EXIT_CODE` (extracting numeric exit status before `:`, e.g., `1:0` -> `1`) and exit early if `0` and `SLURM_JOB_STATE == "COMPLETED"`.
   - Locate log file under `/mnt/storage/projects/${SLURM_JOB_ACCOUNT}/logs/*_${SLURM_JOB_ID}.{err,out}`, verify `[ ! -L "$f" ]` and `realpath` confinement, extract `tail -n 50 | tail -c 4096`, JSON-encode safely, and `curl --max-time 2` with Bearer token to `CENTRAL_PORTAL_URL`.

## Acceptance criteria
1. **Happy Path (Webhook Ingest & Incident Egress):**
   - Given a configured `TelemetryScraper` with `TELEMETRY_TOKEN="supersecret"`,
   - When `POST /api/internal/webhook/slurm` receives a valid Bearer token and a failed job payload (`job_id: "1042"`, `exit_code: 137`, `status: "FAILED"`, `log_tail: "CUDA out of memory"`),
   - Then it returns `201 Created`, and a subsequent `GET /api/v1/telemetry/incidents` returns `200 OK` containing the incident with `entity_id: "1042"`, `exit_code: 137`, and the `log_tail`.
2. **Failure/Boundary Rejection (Unauthorized & Spoofing Prevention):**
   - Given `POST /api/internal/webhook/slurm` or `GET /api/v1/telemetry/incidents`,
   - When a request arrives without a token, with an invalid Bearer token, or when `TELEMETRY_TOKEN` is empty/unconfigured,
   - Then the server rejects the request with `401 Unauthorized` and does not mutate the ring buffer.
3. **Failure-Only Filtering & 4KB Log Truncation:**
   - Given a webhook payload with `exit_code: 0` and `status: "COMPLETED"`,
   - When posted to `/api/internal/webhook/slurm`,
   - Then it returns `200 OK` (ignored) without adding an entry to the incident ring buffer; and when a failed job payload contains a 10KB `log_tail` with control characters, the stored `log_tail` is sanitized and truncated to `<= 4096` bytes.
4. **200-Slot Ring Buffer Eviction & Query Filtering (`since` / `limit`):**
   - Given 205 failed job events pushed sequentially into the portal,
   - When `GET /api/v1/telemetry/incidents?limit=200` is queried,
   - Then exactly 200 incidents are returned in newest-first order (jobs #205 down to #6, with #1–#5 evicted), and `?limit=5` or `?since=<timestamp>` accurately filters the result set.
5. **Non-Blocking Epilog Script & Symlink Safety:**
   - Given `scripts/slurm_epilog_webhook.sh`,
   - When executed with `SLURM_JOB_EXIT_CODE="1:0"` and a symlinked log file or unreachable portal URL,
   - Then the script exits `0` in `< 500ms` without reading symlinked targets outside the project logs directory.

## Open questions
- All 3 strategic decisions resolved by Khem during Phase 1 Inception:
  1. Record only failed jobs (`exit_code != 0` or `status != "COMPLETED"`).
  2. Enforce `Authorization: Bearer <TELEMETRY_TOKEN>` on webhook ingest.
  3. Include sanitized 4KB `log_tail` in incident telemetry.

## Test / Verification plan (Locked at Gate C)
- **Stage 1 (Fast Checks):**
  - `cd portal && go test -v -race -run "TestTelemetry|TestSlurmWebhook|TestIncident" ./...`
  - `cd portal && go vet ./...`
  - `bash -n scripts/slurm_epilog_webhook.sh`
- **Stage 2 (Epilog Script & Integration Probe):**
  - Automated test executing `scripts/slurm_epilog_webhook.sh` against a local test server verifying non-blocking exit `0`, JSON formatting, symlink rejection, and Bearer header propagation.

## Bolt log
- 2026-11-11: Phase 1 Inception (`analyze-gap`) completed; 3 strategic decisions confirmed by Khem. Drafted unit spec and performed Red-Team `audit-spec` review. Gate A+B approved on feature branch `feat/wp13-slurm-epilog-webhook`.
- 2026-11-11: Phase 2 Gate C locked tests generated in `portal/telemetry_test.go` covering 5 acceptance criteria (Auth enforcement, Happy path ingest/egress, failure-only filtering, 4KB log sanitization, 200-slot buffer eviction & query bounds, 16KB payload limit, and race concurrency). Negative proof confirmed via stub 501 assertion failures. Tests locked into `.aidlc/gate_c_wp13-slurm-epilog-webhook.manifest`.
- 2026-11-11: Phase 3 construction completed: implemented `container/ring` 200-slot buffer, Bearer token auth, 16KB body limiter, printable UTF-8 log sanitizer, `/api/internal/webhook/slurm` ingest, `/api/v1/telemetry/incidents` egress, hardened non-blocking `scripts/slurm_epilog_webhook.sh`, updated `k8s/values.yaml` epilog script, and regenerated OpenAPI Swagger documentation (`portal/docs/`).
- 2026-11-11: Phase 4 Gate D empirical verification: all 15 unit tests pass with `go test -v -race`, test manifest hash intact (zero tampering), zero out-of-scope code edits, live cluster operational.
- 2026-11-11: Gate D accepted by human architect. Verified on live Slurm batch-cpu queue (job 185); batch-gpu parity confirmed at Slurm daemon level (hardware GPU test deferred until physical L40 GPU re-attachment). Bolt complete.
