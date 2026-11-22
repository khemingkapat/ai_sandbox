# Unit: WP12-A — Unified JWT v1.2.0, SSO Bridge & 3-Tier RBAC

Status: done (Gate D)
Parent GitHub WP: #12
Exploratory? no

## Intent
Align `portal/` authentication and authorization with the **CPE Sandboxes Unified JWT Authentication Specification v1.2.0** (`sandbox_token` cookie, RS256 JWKS/PEM + HS256 dev fallback, `iss`/`aud` validation, `/api/auth/sso` bridge) and enforce 3-tier role-based access control (`student`, `ta`/`instructor`, `admin`) plus strict cross-tenant isolation on `/:user/:app`.

## Scope & Non-goals
- **In scope:**
  - **Unified JWT Verifier (`portal/auth_unified.go` or `portal/auth.go`):**
    - Support **RS256** via JWKS URL (`JWT_JWKS_URL`, cached in-memory with TTL + `kid` refresh on miss) or mounted PEM (`JWT_PUBLIC_KEY_PATH` / `JWT_PUBLIC_KEY`), and **HS256** via `JWT_SECRET` / `UNIVERSITY_JWT_SECRET` for dev.
    - Validate mandatory claims: `iss`, `sub`, `aud` (`"cpe-sandbox"` or `"cpe-ai-sandbox"`), `iat`, `exp`.
    - Extract `student_id` (fallback `sub`), `tenant_id` (fallback `student_id`), `role` (default `"student"`; map `"ta"` and `"instructor"` to instructor tier, `"admin"` to admin tier), `name`, `email`.
    - Ignore optional `quota_tier` / `profile` / `allowed_features` safely for scheduling (Slurm fairshare & K8s limits govern compute).
  - **Dual Cookie & SSO Bridge (`portal/handlers.go`, `portal/main.go`):**
    - Read `sandbox_token` cookie (Option A: shared parent domain) or `Authorization: Bearer <JWT>` header (CLI/API).
    - Implement `GET /api/auth/sso?token=<JWT>&redirect=<path>` and `POST /api/auth/sso` (Option B): verify token, provision student via `WP05-B`, set `sandbox_token` cookie (`HttpOnly`, `SameSite=Lax`, `Path=/`, configurable `COOKIE_DOMAIN` & `COOKIE_SECURE`), and `302` redirect (sanitizing `redirect` to relative paths only to prevent open-redirect).
    - Keep internal `session` cookie (or project context) strictly for active Slurm `prj` switching so `portal` never attempts to re-sign the IdP's `sandbox_token`.
  - **Tenant Isolation & 3-Tier RBAC (`portal/main.go`, `portal/rbac.go`):**
    - Protect `/:user/:app` proxy group with JWT middleware + tenant check (`sub == :user` unless `role == admin`), returning `403 Forbidden` (`X-Denial-Reason: cross-tenant-isolation`) on mismatch.
    - Add `RequireRole("instructor")` (allows `ta`, `instructor`, `admin`) and `RequireRole("admin")` (allows `admin` only).
    - Add `/admin` and `/api/admin/*` routes gated by `RequireRole("admin")` (exposing cluster telemetry/incidents and central service status).
  - **Traefik ForwardAuth Alignment (`k8s/traefik-security-configmap.yaml`, optional `GET /api/auth/verify`):**
    - Provide `/api/auth/verify` for Traefik ForwardAuth (returns `200` with `X-User-Id`/`X-User-Role`, `302` to Learning Portal login for `Accept: text/html`, `401` for API/WS, `403` for cross-tenant).
- **Non-goals:**
  - Implementing dynamic `quota_tier` GPU/CPU scheduling (explicitly deferred; Slurm fairshare handles GPU QoS).
  - Building full Kubernetes/storage mutation UI in `/admin` (only RBAC gate + read-only status/telemetry in this bolt).

## Constraints and decisions to respect
- [CPE Sandboxes: Unified JWT Authentication Specification v1.2.0](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/PROJECT_CONTEXT.md)
- [ADR 0002: Storage and UID/GID Isolation](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0007: Self-Service Identity & Project Provisioning](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0007-self-service-identity-and-project-provisioning.md)

## Implementation Plan (Bundled for Gate A+B)
- **Approach:**
  1. **Unified JWT Verifier (`portal/auth.go` / `portal/auth_unified.go`):** Parse and validate incoming JWTs using either RS256 (via in-memory cached JWKS with TTL or PEM key) or HS256 (dev fallback). Verify mandatory claims (`iss`, `sub`, `aud` in `cpe-sandbox` or `cpe-ai-sandbox`, `iat`, `exp`). Extract normalized claims into `UnifiedUserContext` (`StudentID`, `TenantID`, `Role`, `Name`, `Email`).
  2. **SSO Bridge & Auth Middleware (`portal/handlers.go`, `portal/main.go`):**
     - Provide `GET /api/auth/sso?token=<JWT>&redirect=<path>` and `POST /api/auth/sso`: verify JWT, call `identityManager.EnsureStudentProvisioned(studentID)`, set `sandbox_token` cookie (`HttpOnly`, `SameSite=Lax`, `Path=/`), and return `302` redirect to sanitized relative path.
     - Support auth lookup from `sandbox_token` cookie, fallback to `session` cookie (for backward compatibility), or `Authorization: Bearer <JWT>` header.
     - Provide `/api/auth/verify` for Traefik ForwardAuth: returns `200 OK` with `X-User-Id` and `X-User-Role` headers, `302` to login if `Accept: text/html`, `401` for API/WS, and `403` for cross-tenant violations.
  3. **3-Tier RBAC & Tenant Isolation (`portal/rbac.go`, `portal/main.go`):**
     - Enforce tenant isolation middleware on `/:user/:app`: check that authenticated `StudentID == :user` unless role is `admin`. If mismatch, respond with `403 Forbidden` (`X-Denial-Reason: cross-tenant-isolation`).
     - Gated routes: `RequireRole("instructor")` for instructor/admin tier, `RequireRole("admin")` for `/admin` and `/api/admin/*` status endpoints.
- **Files to touch:**
  - `portal/auth.go`: RS256/HS256 validation, JWKS caching, and unified claim extraction.
  - `portal/rbac.go`: Role checking middlewares and cross-tenant isolation guard.
  - `portal/handlers.go`: SSO bridge (`/api/auth/sso`), ForwardAuth endpoint (`/api/auth/verify`), and admin status handler.
  - `portal/main.go`: Route registration, middleware pipeline wiring on UI and `/:user/:app`.
  - `portal/auth_unified_test.go`: Gate C unit tests.
  - `k8s/traefik-security-configmap.yaml`: Traefik ForwardAuth route integration if needed.
  - `scripts/verify-unified-jwt.sh`: Live cluster Stage 2 verification probe.
- **Risks / Edge cases:**
  - *Open Redirect:* Attacker passes `?redirect=https://evil.com` or `//evil.com` to `/api/auth/sso`. Mitigate with strict relative URL sanitization (must begin with `/`, must not begin with `//`, reject backslashes and scheme prefixes).
  - *JWKS Network Outages:* Downstream IdP downtime shouldn't immediately fail all auth. Mitigate with cached JWKS keys + TTL.
  - *Cookie Re-signing:* Portal must never re-sign IdP `sandbox_token`. Project context switching uses an internal session or project token.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp12a-unified-jwt-rbac.md` | Unit spec & Bolt log |
| `docs/aidlc/UNITS.md` | Status tracking |
| `portal/auth.go` | RS256 (JWKS/PEM) + HS256 JWT verification & claim extraction |
| `portal/rbac.go` | 3-tier role middleware & cross-tenant isolation guard |
| `portal/handlers.go` | `/api/auth/sso`, `/api/auth/verify`, `/admin` handlers |
| `portal/main.go` | Wire `sandbox_token` auth, RBAC groups, and `/:user/:app` tenant guard |
| `portal/auth_unified_test.go` | Locked Gate C unit tests (RS256, HS256, `aud`/`iss`, SSO, RBAC, tenant isolation) |
| `k8s/traefik-security-configmap.yaml` | ForwardAuth / cookie headers if needed |
| `scripts/verify-unified-jwt.sh` | Stage 2 live cluster ForwardAuth & RBAC verification probe |

## Acceptance criteria
1. **Happy Path (RS256 + HS256 & SSO Bridge):**
   - Given a valid RS256 (or HS256 in dev) JWT with `iss`, `sub`, `aud: "cpe-ai-sandbox"`, `role: "student"`,
   - When the browser hits `GET /api/auth/sso?token=<JWT>&redirect=/`,
   - Then `portal` verifies the signature, provisions the student, sets `sandbox_token` (`HttpOnly`, `SameSite=Lax`, `Path=/`), and returns `302` to `/`.
2. **Failure/Boundary Rejection (Bad `aud`, Expired, Open Redirect, Cross-Tenant, Role Escalation):**
   - Given a JWT with wrong `aud` or expired `exp`, `/api/auth/sso` returns `401`.
   - Given `?redirect=https://evil.com`, `/api/auth/sso` rejects or strips to `/`.
   - Given Student A (`sub: "65070501111"`) requesting `/65070502222/jupyter/lab`, `portal` returns `403 Forbidden` with `X-Denial-Reason: cross-tenant-isolation`.
   - Given `role: "student"` or `role: "instructor"` requesting `/api/admin/status`, `portal` returns `403 Forbidden`; `role: "admin"` returns `200 OK`.
3. **Integration Contract (Traefik ForwardAuth & Existing Tests):**
   - `cd portal && go test -v -race ./...` passes without breaking existing `WP05-B` or `WP13` tests.

## Test / Verification plan (Locked at Gate C)
- Stage 1: `cd portal && go test -v -race ./... && go vet ./... && golangci-lint run`
- Stage 2: `bash scripts/verify-unified-jwt.sh`

## Bolt log (Updated at Gate D)
- 2026-11-22: Completed Unit WP12-A implementation.
  - Implemented `UnifiedJWTVerifier` in `portal/auth.go` supporting RS256 (JWKS with in-memory TTL caching and KID lookup, PEM public key) and HS256 dev fallback. Validates mandatory claims (`iss`, `sub`, `aud: cpe-ai-sandbox | cpe-sandbox`, `iat`, `exp`) and normalizes claims (`student_id`, `tenant_id`, `role: student|instructor|admin`).
  - Added SSO bridge handlers in `portal/handlers.go`: `GET /api/auth/sso?token=...&redirect=...` and `POST /api/auth/sso` with relative URL sanitization preventing open redirects, student provisioning via `WP05-B`, and `sandbox_token` cookie issuance.
  - Added Traefik ForwardAuth endpoint `GET /api/auth/verify` returning `200 OK` with `X-User-Id` and `X-User-Role` headers, `302` redirect to `/login` for browser `Accept: text/html`, and `401` for API clients.
  - Added 3-tier RBAC (`RequireRole("instructor")`, `RequireRole("admin")`) and `/api/admin/status` endpoint.
  - Added `TenantIsolationMiddleware()` on `/:user/:app` proxy routes enforcing `student_id == :user` unless role is `admin`, returning `403 Forbidden` with `X-Denial-Reason: cross-tenant-isolation` on mismatch.
  - Verified with locked Gate C tests (`portal/auth_unified_test.go`) passing with `-race` (6/6 test groups) and live cluster probe (`scripts/verify-unified-jwt.sh`) (6/6 checks passed).
