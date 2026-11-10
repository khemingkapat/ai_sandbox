# Unit: WP13-A — Cluster Health Telemetry Endpoint & Interactive Swagger UI

Status: done (Gate D)
Parent GitHub WP: #13 / #0
Exploratory? no

## Intent
Deliver a resilient, non-blocking cluster telemetry observability pipeline and embedded interactive OpenAPI/Swagger documentation inside the Go Web Portal (`portal/`). This gives central operators/administrators high-signal diagnostics (`healthy`, `degraded`, `error`, active user headcount, queue depth, and subsystem health) without exposing student identity leaks, without risking kernel D-state I/O hangs, and without conflating intended single-GPU batch yield states (ADR 0003) with cluster failure.

## Scope & Non-goals
- **In scope:**
  - Lightweight unauthenticated Kubelet probe: `GET /healthz` returning instant 200 OK `{"status":"ok"}` with zero external network or disk I/O.
  - Authenticated admin telemetry endpoint: `GET /api/v1/telemetry` protected by pre-shared Bearer token (`TELEMETRY_TOKEN`).
  - Thread-safe in-memory telemetry cache with 15–30s TTL to prevent hammering cluster control planes.
  - Subsystem network probes with strict 1.5s deadlines:
    - vLLM: `http://vllm-service.services.svc.cluster.local:8000/health` (ClusterIP).
    - MLflow: `http://mlflow.services.svc.cluster.local:5000/health` (ClusterIP).
    - Slurm: via `slurmclient` or HTTP ping to `slurmrestd:6820`.
    - Storage: Fast non-blocking mount check via `/proc/mounts` and directory stat.
  - ADR 0003 single-GPU yield awareness: if vLLM is unreachable but Slurm has running jobs on `batch-gpu`, vLLM status is `"yielded_for_batch"` and overall cluster status remains `"healthy"`.
  - Interactive OpenAPI / Swagger UI:
    - Code annotations using `swaggo/swag`.
    - Mount `echo-swagger` at `GET /swagger/*`.
    - Exclude internal unauthenticated control routes (`/api/internal/*`) from public docs.
- **Non-goals:**
  - Headlamp / Kubernetes Dashboard deployment (deferred to sysadmin infrastructure unit WP16 to prevent RBAC privilege leaks).
  - Public unauthenticated disclosure of student UIDs or queue depths.
  - Heavy Prometheus server or OpenTelemetry collector installation.

## Constraints and decisions to respect
- [ADR 0001: Two-Path Workload Execution Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0001-two-path-workload-execution.md)
- [ADR 0002: Storage and UID/GID Isolation Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- [ADR 0004: Central Services Architecture](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0004-central-services-architecture.md)

## Implementation Plan (Bundled for Gate A+B)
1. **Telemetry Engine (`portal/telemetry.go`):**
   - Define data structs: `TelemetryResponse`, `WorkloadMetrics`, `ServiceHealthMap`.
   - Implement `TelemetryScraper` with `sync.RWMutex`, TTL cache (e.g. 15s), and non-blocking evaluation.
   - Implement `checkStorage()` using `/proc/mounts` reading + `os.Stat` with timeout.
   - Implement `checkServices()` with isolated `http.Client{Timeout: 1500 * time.Millisecond}`.
   - Implement ADR 0003 reconciliation with running `batch-gpu` jobs.
2. **Handlers & Routing (`portal/handlers.go`, `portal/main.go`):**
   - Register `GET /healthz` (public, instant 200).
   - Register `GET /api/v1/telemetry` with Bearer auth middleware (`TELEMETRY_TOKEN`).
   - Register `GET /swagger/*` with `echo-swagger`.
3. **OpenAPI / Swagger Generation:**
   - Add `swaggo/swag` annotations across `main.go`, `handlers.go`, `telemetry.go`.
   - Run `swag init -g main.go -d . -o docs` to generate `portal/docs/swagger.json`.
4. **Verification & Testing (Gate C):**
   - Unit tests in `portal/telemetry_test.go` covering cache TTL, Bearer auth rejection, happy path, and ADR 0003 batch yield handling.

## Acceptance criteria
1. **Liveness Probe (Instant Happy Path):**
   - Given a running portal instance,
   - When an unauthenticated client requests `GET /healthz`,
   - Then the response is `200 OK` with body `{"status":"ok"}` in < 5ms with zero outbound network calls.
2. **Admin Telemetry Authentication Enforcement:**
   - Given the portal configured with `TELEMETRY_TOKEN="supersecret"`,
   - When a request is made to `GET /api/v1/telemetry` without a token or with an invalid token,
   - Then the response is `401 Unauthorized`.
3. **Admin Telemetry Valid Response (Happy Path):**
   - Given a request to `GET /api/v1/telemetry` with `Authorization: Bearer supersecret`,
   - When all central services are responding,
   - Then the response is `200 OK` with JSON containing `status: "healthy"`, active user counts, queue metrics, and service statuses (`vllm`, `mlflow`, `slurm`, `storage`).
4. **ADR 0003 Batch Yield Boundary Case:**
   - Given `vllm-service` is stopped/unreachable (HTTP connection refused),
   - But Slurm reports a running job on partition `batch-gpu`,
   - When `GET /api/v1/telemetry` evaluates system status,
   - Then `services.vllm` is reported as `"yielded_for_batch"` and root `status` remains `"healthy"`.
5. **Interactive Swagger UI Availability:**
   - Given the portal is running,
   - When a browser accesses `GET /swagger/index.html`,
   - Then Swagger UI HTML is served, OpenAPI JSON is reachable at `/swagger/doc.json`, and `/api/internal/*` routes are excluded from the documentation.

## Bolt Log
- 2026-11-09: Gate A+B approved. Adversarial audit completed.
- 2026-11-09: Gate C locked tests written in portal/telemetry_test.go covering 5 acceptance criteria (Liveness, Admin Bearer auth, Happy path, ADR 0003 Batch GPU yield, Swagger doc.json).
- 2026-11-09: Implementation completed.
- 2026-11-09: Adversarial result audit completed (pro subagent). Remediated 4 findings: (1) fail-closed auth on unconfigured token, (2) detached probe context to protect cache from client cancellation, (3) Slurm POSIX root token minting, (4) probe execution outside mutex lock. All 8 unit tests pass with -race. Ready for merge.
