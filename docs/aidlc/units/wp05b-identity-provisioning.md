# Unit: WP05-B — Self-Service Identity Resolution & Dynamic Project Provisioning

Status: done (Gate D verified)
Parent GitHub WP: #5
Exploratory? no

## Intent
Implement the **Portal-Driven Self-Service Provisioning** architecture defined in [ADR 0007](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0007-self-service-identity-and-project-provisioning.md) so the AI Sandbox operates automatically across large student cohorts without manual `sacctmgr` or `useradd` administration. The Web Portal (`portal/`) becomes the single source of truth backed by Postgres 16 (`mlflow-postgres` in the `services` namespace), authenticating students strictly via signed JWTs, allowing self-service project creation and team invitations, and compiling state deterministically to `/mnt/storage/common/etc/{passwd,group}` (under `flock`), `/mnt/storage/projects/<slug>` (`chmod 2770`), and `slurmrestd` (`/slurmdb/v0.0.42/`).

## Scope & Non-goals
- **In scope:**
  - **Postgres 16 Identity & Project Store (`portal/identity.go`, `portal/go.mod`, `portal/go.sum`):**
    - Persistent schema (`portal_users`, `portal_projects`, `portal_memberships`, `portal_id_counters`) inside Postgres 16 (`DATABASE_URL`, defaulting to `postgres://mlflow:mlflowpassword@mlflow-postgres.services.svc.cluster.local:5432/mlflow?sslmode=disable`, with `sqlite3` fallback in unit tests).
    - Monotonic, never-reused allocation of Linux UIDs (`>= 2000`) for new students and GIDs (`>= 10000`) for new projects.
    - First-class seeding of baseline accounts (`user1..user4` with UIDs `1001..1004` and `project1..project3` with GIDs `2001..2003`) so existing verification scripts and multi-user suites work through the unified pipeline without divergence.
  - **Strict Single-Path External JWT Authentication (`portal/auth.go`, `portal/handlers.go`, `portal/templates/login.html`):**
    - `POST /login` (and `GET /login?token=<jwt>`) strictly requires and verifies a signed external/University JWT (`jwt_token` signed with `UNIVERSITY_JWT_SECRET`, falling back to the cluster JWT key when unconfigured), extracting `student_id` (or `sub`).
    - Rejects unauthenticated, expired, or malformed JWTs and strictly validates `student_id` against `^[a-z0-9][a-z0-9._-]{0,31}$` (blocking POSIX `passwd` colon/newline injection and reserved names like `root`).
    - On first login, automatically provisions the student's UID and a personal default project (`p-<student_id>`, `chmod 2770`) if they have no project memberships.
    - `GET /login` provides a JWT token login form plus pre-signed demo JWT quick-fill buttons (`user1..user4`) so manual and automated testing use the exact same JWT verification code path.
  - **Self-Service Project & Team Invitation APIs + UI (`portal/identity.go`, `portal/handlers.go`, `portal/main.go`, `portal/templates/index.html`):**
    - `GET /api/projects`: Lists projects the authenticated student belongs to (slug, display name, GID, owner, members, active flag).
    - `POST /api/projects`: Creates a new project with a human-friendly `display_name` (1..64 printable chars), generates a unique immutable slug (`p-<short-id>`), enforces a per-student active owned project quota (`MAX_PROJECTS_PER_USER`, default `5`), allocates a monotonic `GID >= 10000`, and provisions `/mnt/storage/projects/<slug>` with `chmod 2770` and project GID ownership.
    - `POST /api/projects/:id/members`: Allows project members/owners to invite another student by `student_id` (pre-provisioning the invitee's `portal_users` record and UID if they haven't logged in yet) and syncs group membership.
    - `POST /api/projects/switch`: Switches the student's active project session cookie (`prj` claim) after verifying membership.
    - Lightweight UI bar in `portal/templates/index.html` for switching active projects, creating a new project, and inviting a teammate by `student_id`.
  - **Atomic `libnss-extrausers` Compiler & Setgid Directory Provisioner (`portal/identity.go`):**
    - Serializes all writes via `syscall.Flock` on `/mnt/storage/common/etc/.extrausers.lock`.
    - Compiles `/mnt/storage/common/etc/passwd` and `/mnt/storage/common/etc/group` deterministically from the DB store via atomic `tmp` write + `fsync` + `os.Rename`.
    - Creates `/mnt/storage/projects/<slug>` with `02770` (`os.ModeSetgid | 0770`) and `chown(uid, gid)`.
  - **`slurmrestd` Accounting Sync & Background Reconciler (`portal/identity.go`):**
    - Synchronizes accounts (`POST /slurmdb/v0.0.42/accounts`), users (`POST /slurmdb/v0.0.42/users`), and associations (`POST /slurmdb/v0.0.42/associations` with cluster `slurm_slurm` and default QoS list) using an admin Slurm JWT.
    - Runs an idempotent background reconciler ticker (`RECONCILE_INTERVAL_SEC`, default `60s`) so `extrausers`, project directories, and SlurmDBD self-heal if `slurmrestd` restarts.
  - **Kubernetes Manifests & NetworkPolicy (`k8s/portal-deployment.yaml`, `k8s/network-policies/allow-postgres-services-only.yaml`, `scripts/verify-wp05b.sh`):**
    - Update `allow-postgres-services-only.yaml` to permit TCP 5432 ingress ONLY from `app: hpc-portal` in the `slurm` namespace (explicitly keeping `slurm-worker-*` pods blocked).
    - Wire `DATABASE_URL` in `k8s/portal-deployment.yaml`.
- **Non-goals:**
  - OpenLDAP, SSSD, or Active Directory daemons (rejected in ADR 0002 & ADR 0007).
  - SQLite databases stored on `/mnt/storage` (NFS).
  - Full portal frontend redesign (deferred to `WP12`).

## Constraints and decisions to respect
- [ADR 0002: Storage Isolation, Identity & UID Security](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0007: Self-Service Identity Resolution & Dynamic Project Provisioning](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0007-self-service-identity-and-project-provisioning.md)
- **Resolved Strategic Decisions (Khem):**
  1. **State Store (Decision 1):** Use Postgres 16 (`mlflow-postgres` in `services` namespace) for production state, with `database/sql` abstraction so Stage 1 unit tests (`go test -race`) run fast in-memory.
  2. **Single-Path External JWT Auth (Decision 2):** Eliminate form-username auth divergence; `POST /login` strictly verifies signed JWTs (`jwt_token`), while `user1..user4` and `project1..project3` are seeded into Postgres and exposed as pre-signed JWT quick-select options on `login.html`.
  3. **REST APIs + Portal UI Controls (Decision 3):** Expose REST endpoints for project creation, member invitation, and project switching, and wire minimal UI controls in `index.html`.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp05b-identity-provisioning.md` | Unit specification and bolt log |
| `docs/aidlc/UNITS.md` | Update `WP05-B` unit status |
| `docs/aidlc/PROJECT_CONTEXT.md` | Reflect ADR 0007 Postgres identity state & WP05-B status |
| `docs/aidlc/decisions/0007-self-service-identity-and-project-provisioning.md` | Flip status from `proposed` to `accepted` |
| `portal/go.mod` | Add `github.com/lib/pq` Postgres driver |
| `portal/go.sum` | Go module checksums |
| `portal/identity.go` | Identity/Project DB store, UID/GID allocator, `flock` `extrausers` compiler, setgid dir provisioner, `slurmrestd` sync & reconciler, REST handlers |
| `portal/identity_test.go` | Locked Gate C unit & concurrency tests (`-race`) |
| `portal/auth.go` | University JWT verification (`verifyUniversityJWT`) & DB-backed access lookup |
| `portal/handlers.go` | Unified JWT `loginPage` / `loginAction` and `indexPage` project context |
| `portal/main.go` | Initialize `IdentityManager`, start reconciler, register `/api/projects*` routes |
| `portal/session_manager.go` | Ensure `resolveUserSecurityContext` resolves dynamic extrausers paths cleanly |
| `portal/templates/login.html` | Single-path signed JWT login form + demo JWT quick-select buttons |
| `portal/templates/index.html` | Active project switcher, create-project modal/bar, and member invite UI |
| `portal/docs/docs.go` | Regenerated Swagger docs |
| `portal/docs/swagger.json` | Regenerated Swagger JSON |
| `portal/docs/swagger.yaml` | Regenerated Swagger YAML |
| `k8s/portal-deployment.yaml` | Configure `DATABASE_URL` env var for `hpc-portal` |
| `k8s/network-policies/allow-postgres-services-only.yaml` | Allow TCP 5432 ingress from `slurm` namespace pod `app: hpc-portal` only |
| `scripts/verify-wp05b.sh` | Live cluster Gate C/D verification script for WP05-B |

## Implementation Plan (Bundled for Gate A+B)
1. **Database Schema & Monotonic Allocator (`portal/identity.go`):**
   - Create tables `portal_users (student_id PRIMARY KEY, uid INT UNIQUE, created_at)`, `portal_projects (project_id PRIMARY KEY, display_name TEXT, gid INT UNIQUE, owner_student_id TEXT, created_at)`, and `portal_memberships (project_id, student_id, PRIMARY KEY(project_id, student_id))`.
   - Seed `user1..user4` (UIDs `1001..1004`) and `project1..project3` (GIDs `2001..2003`) idempotently on startup.
   - Allocate new student UIDs monotonically starting at `max(2000, max(uid)+1)` and new project GIDs starting at `max(10000, max(gid)+1)` inside serialized DB transactions.
2. **Strict External JWT Login & Auto-Provisioning (`portal/auth.go`, `portal/handlers.go`):**
   - Implement `verifyUniversityJWT(tokenStr)` verifying HMAC-SHA256 signature (`UNIVERSITY_JWT_SECRET` or fallback cluster Slurm key) and extracting `student_id` / `sub`.
   - Validate `student_id` format (`^[a-z0-9][a-z0-9._-]{0,31}$`, not `root`).
   - On `POST /login` (or `GET /login?token=...`), verify `jwt_token`, call `identityManager.EnsureStudentProvisioned(studentID)` (which allocates UID >= 2000 and creates default project `p-<student_id>` if the user has no projects), select the requested or default project after verifying membership, and issue the session cookie.
3. **Self-Service Project & Invite APIs (`portal/identity.go`, `portal/main.go`):**
   - `GET /api/projects`: Return caller's projects and members.
   - `POST /api/projects`: Check active owned project count `< maxProjectsPerUser` (default 5); generate collision-free slug `p-<8-hex>`; allocate GID >= 10000; insert project & owner membership; trigger `SyncAll()`.
   - `POST /api/projects/:id/members`: Verify caller is a member/owner of `:id`; validate target `student_id`; upsert target student in `portal_users` (allocating UID >= 2000 if new); insert membership; trigger `SyncAll()`.
   - `POST /api/projects/switch`: Verify caller is a member of `project_id` and reissue session cookie for that project.
4. **Atomic `extrausers` Compiler, Setgid Directories & `slurmrestd` Reconciler (`portal/identity.go`):**
   - Acquire `syscall.Flock` on `<extrausersDir>/.extrausers.lock`.
   - Render deterministic `passwd` and `group` files from DB state, write to `.tmp`, `Sync()`, and `os.Rename()`.
   - Ensure `<projectsDir>/<project_id>` exists with `os.Chmod(..., os.ModeSetgid|0770)` (`2770`) and `os.Chown(..., ownerUID, projectGID)`.
   - Push accounts, users, and associations (`slurm_slurm` cluster) to `slurmrestd` `/slurmdb/v0.0.42/{accounts,users,associations}` and run background reconciler every `60s`.

## Acceptance criteria
1. **Happy Path (JWT Login, Monotonic UID/GID Provisioning & Self-Service Project/Invite):**
   - Given a signed University JWT for a new student `student_id: "stu_alice"`,
   - When `stu_alice` authenticates via `POST /login`, creates a project `"Agent Harness"` via `POST /api/projects`, and invites `"stu_bob"` via `POST /api/projects/:id/members`,
   - Then `stu_alice` and `stu_bob` receive distinct monotonic UIDs `>= 2000`, the project receives a unique slug `p-<id>` and GID `>= 10000`, `/mnt/storage/common/etc/passwd` and `group` atomically include both users and their project group membership, `/mnt/storage/projects/p-<id>` is created with mode `2770` (`drwxrws---`), and `slurmrestd` receives the user/account/association payloads.
2. **Failure/Boundary Rejection (Invalid JWT, Quota Exceeded, Injection & Unauthorized Invite):**
   - Given the Portal authentication and project endpoints,
   - When (a) `POST /login` receives an unsigned/tampered JWT or a `student_id` containing `:` / `\n` / `../` / `root`, (b) a student attempts to create a 6th project exceeding the 5-project quota (`MAX_PROJECTS_PER_USER=5`), or (c) a non-member attempts to invite a user or switch to another team's project,
   - Then the requests are rejected with `401 Unauthorized` / `400 Bad Request` / `429 Too Many Requests` / `403 Forbidden` respectively, and neither Postgres, `extrausers`, nor `/mnt/storage/projects` is mutated.
3. **Integration Contract (Seeded Demo Users, Concurrent `flock` Safety & Reconciler Convergence):**
   - Given seeded identities (`user1..user4`, `project1..project3`) and 20 concurrent self-service provisioning operations under `go test -race`,
   - When the `extrausers` compiler and `slurmrestd` reconciler execute concurrently,
   - Then zero data races or corrupted `passwd`/`group` lines occur, `user1..user4` retain UIDs `1001..1004` and `project1..project3` retain GIDs `2001..2003`, and `resolveUserSecurityContext()` resolves the newly provisioned student's UID, primary GID, and supplemental project GIDs for Kubernetes `PodSecurityContext`.

## Open questions
- None. All 3 strategic decisions resolved by Khem during Phase 1 Inception.

## Test / Verification plan (Locked at Gate C)
- **Stage 1 (Fast Checks):**
  - `cd portal && go test -v -race -run "TestIdentity|TestJWTLogin|TestProjectProvisioning|TestExtrausersCompiler|TestReconciler" ./...`
  - `cd portal && go vet ./... && golangci-lint run`
  - `bash -n scripts/verify-wp05b.sh`
- **Stage 2 (In-Cluster Hardware / Integration Verification):**
  - `bash scripts/verify-wp05b.sh` verifying live Postgres persistence in `services` namespace, CNI NetworkPolicy enforcement (portal allowed, slurm worker blocked from Postgres 5432), JWT login, self-service project creation & teammate invitation, `/mnt/storage/common/etc/{passwd,group}` projection, `/mnt/storage/projects/<slug>` `2770` permissions, and live `sacctmgr` / `slurmrestd` association convergence.

## Bolt log
- 2026-11-14: Phase 1 Inception (`analyze-gap`) completed; 3 strategic decisions confirmed by Khem (Postgres 16 store, strict single-path JWT login with seeded `user1..4`, and REST API + UI controls). Drafted unit spec and completed Red-Team `audit-spec` review on branch `feat/wp05b-identity-provisioning`.
- 2026-11-14: Gate C tests & probe locked (`17d4b90`). Fixed two auth bugs during live verification: (1) `portal/identity.go` (`postSlurmrestd`) now dynamically signs a root Slurm JWT via `makeSlurmToken("root", "root")` instead of sending the raw `jwt.key` secret from `SLURM_JWT`, and (2) `scripts/verify-wp05b.sh` Check 6 mints a real `scontrol token username=root` and asserts both HTTP `200` and `"pinged": "UP"`.
- 2026-11-14: Gate D empirical verification passed: `go test -v -race ./...` (22/22 tests), `go vet ./...`, `bash -n scripts/verify-wp05b.sh`, and live cluster probe `scripts/verify-wp05b.sh` (6/6 checks, receipt `.aidlc/runs/wp05b-verify.log`).