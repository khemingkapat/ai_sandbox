# Unit: WP12-B — One-Click Lab Launcher & Read-Only Curriculum Mount

Status: tests-locked (Gate C)
Parent GitHub WP: #12
Exploratory? no
Depends on: WP12-A, WP05-B

## Intent
Provide a single deep-link endpoint (`GET /launch?lab=<relpath>`) and Portal Labs UI (`GET /api/labs`, `POST /api/labs/clone`) that drops a student straight from an LMS or the Sandbox Portal into a live JupyterLab session with the central curriculum mounted **read-only** (`/mnt/storage/projects/<project>/labs`), while allowing `instructor`/`admin` roles to author labs read-write and students to clone any lab into a writable `my_labs/` workspace.

## Scope & Non-goals
- **In scope:**
  - **Central Curriculum Directory (`scripts/init-storage.sh`):**
    - Create `/mnt/storage/labs/` (`chown -R 0:2999`, `chmod 2775` on dirs, `0664` on files) and seed canonical starter notebooks from `templates/projects/project1/starter_labs/`.
  - **Role-Based `labs` Mount & Session Reuse (`portal/session_manager.go`, `portal/handlers.go`):**
    - Update `CreateSession` to accept `role string` (normalized via `RoleLevel(role)`):
      - Mount `subPath: "labs"` at `/mnt/storage/projects/<project>/labs`:
        - `ReadOnly: true` when `RoleLevel(role) < 2` (`student`).
        - `ReadOnly: false` + append GID `2999` to `PodSecurityContext.SupplementalGroups` when `RoleLevel(role) >= 2` (`instructor`, `admin`).
      - Label pods with `role: <normalizedRole>`.
    - Add `FindActiveSession(ctx, username, project, appID, role)` + per-`(user, project)` `sync.Mutex` guard to reuse existing `Running`/`Pending` JupyterLab pods and prevent duplicate spawns on double-clicks.
  - **Lab Discovery, Safe Path Validation, Deep-Link & Clone (`portal/labs.go`, `portal/main.go`):**
    - Safe relative-path resolver (`resolveLabPath`) supporting **both** flat `.ipynb` files (`01_hello_sandbox.ipynb`) and nested module folders (`week01/lab01.ipynb`) via `filepath.Clean`, `.ipynb` suffix check, and `filepath.EvalSymlinks` prefix containment inside `LABS_DIR` (default `/mnt/storage/labs`). Rejects `..`, absolute paths, symlinks escaping root, and non-`.ipynb` targets with `400 Bad Request`.
    - `GET /api/labs`: Dynamically walks `LABS_DIR` and returns JSON list of available `.ipynb` labs (relative path, display title, folder/module, size).
    - `GET /launch?lab=<relpath>`: Validates `lab`, finds or spawns a CPU-only `jupyterlab` pod for the user's active project + role, synchronously polls `http://svc-<sessionID>.workload.svc.cluster.local:8888<basePath>/api` (using `c.Request().Context()` + 20s timeout, 500ms interval, 2s per-probe timeout), and responds `302 Found` to `/<username>/jupyterlab/<sessionID>/lab/tree/labs/<relpath>` (or `504 Gateway Timeout` if not ready in 20s).
    - `POST /api/labs/clone`: Copies the target `.ipynb` (or its parent module folder if nested) into `/mnt/storage/projects/<active_project>/my_labs/` (non-clobbering: appends `_YYYYMMDD_HHMMSS` if target exists), sets `chown` to the user's resolved `(uid, gid)` and `0664`/`2770` permissions, and returns the cloned relative path + `/launch?lab=...&workspace=my_labs` or JupyterLab path.
  - **Portal UI & Local Mock LMS (`portal/templates/index.html`, `scripts/mock-lms.py`):**
    - Add a **"Curriculum Labs"** card section in `portal/templates/index.html` fetching `GET /api/labs` with **Open (RO)** (`/launch?lab=...`) and **Clone to My Workspace** (`POST /api/labs/clone`) buttons.
    - Add a standalone, local-machine-only dev script `scripts/mock-lms.py` (stdlib Python, zero external deps, `http://localhost:9090`) that mints dev HS256 JWTs for preset personas (`student1`, `instructor1`, `admin1`) and links to `/api/auth/sso?token=<JWT>&redirect=/launch?lab=...` to demo the end-to-end LMS handoff without deploying any mock auth into Kubernetes.
- **Non-goals:**
  - Authoring the 10 real LMS curriculum notebooks (separate content unit after WP12-B).
  - Per-course ACLs or multi-tenant lab catalogs (all authenticated users see the same `/mnt/storage/labs/` catalog for now).
  - Pre-warming idle pods per student or GPU allocation for `/launch` sessions (CPU-only interactive pods only).

## Constraints and decisions to respect
- [ADR 0001: Two-Path Workload Execution](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0001-two-path-workload-execution.md)
- [ADR 0002: Storage and UID/GID Isolation](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)
- [ADR 0003: Single L40 GPU Sharing and QoS](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0003-single-l40-gpu-sharing-and-qos.md)
- [WP12-A: Unified JWT v1.2.0 & 3-Tier RBAC](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/units/wp12a-unified-jwt-rbac.md)
- [WP14-B: Pre-Baked Client SDKs & 5 Starter Curriculum Labs](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/units/wp14b.md)

## Implementation Plan (Bundled for Gate A+B)
- **Approach:**
  1. Extend `SessionManager.CreateSession` with `role` to attach the scoped `subPath: "labs"` mount at `/mnt/storage/projects/<project>/labs` (visible inside JupyterLab's `--notebook-dir`) and add `2999` supplemental GID for `instructor`/`admin` pods.
  2. Add `FindActiveSession` + per-`(user, project)` launch mutex in `SessionManager` so repeated `/launch` calls reuse the existing pod without race conditions.
  3. Implement `portal/labs.go` containing `resolveLabPath`, `handleListLabs`, `handleLaunchLab`, and `handleCloneLab` (with `chown` to resolved student UID/GID on cloned files). Register routes under the `UnifiedJWTMiddleware`-protected `ui` group in `portal/main.go`.
  4. Add the Curriculum Labs card to `portal/templates/index.html` and add `scripts/mock-lms.py` for local browser demos.
  5. Update `scripts/init-storage.sh` to seed `/mnt/storage/labs/` (`0:2999`, `2775`) and write `scripts/verify-lab-launcher.sh` for Stage 2 cluster verification.
- **Risks / Edge cases:**
  - **Root-owned cloned files:** Portal runs as UID 0; `POST /api/labs/clone` must `os.Chown` created `my_labs/` dirs and copied files to the student's dynamic `(uid, gid)` from `resolveUserSecurityContext` so the student pod can save edits.
  - **Mount shadowing:** Mounting `labs` at `projects/<project>/labs` would hide anything written there, so clones strictly target `projects/<project>/my_labs/`.
  - **Double-click race:** Two concurrent `GET /launch` requests for the same cold student could spawn duplicate pods; mitigated by a per-`(user, project)` mutex.
  - **Client disconnect during 20s poll:** Readiness loop binds to `c.Request().Context()` so cancelled browser requests abort immediately.

## Files Allowed to Touch
| Allowed File Path | Purpose |
| :--- | :--- |
| `docs/aidlc/units/wp12b-one-click-lab-launcher.md` | Unit spec & Bolt log |
| `docs/aidlc/UNITS.md` | Status tracking |
| `portal/session_manager.go` | Role-aware `labs` `subPath` mount, GID `2999` for staff, `FindActiveSession` & launch mutex |
| `portal/session_manager_test.go` | Locked unit tests asserting `ReadOnly` flag, GID `2999`, and pod reuse per role |
| `portal/labs.go` | `resolveLabPath`, `GET /api/labs`, `GET /launch`, `POST /api/labs/clone` |
| `portal/labs_test.go` | Locked unit tests for path traversal, symlink escape, flat/nested labs, clone, and `/launch` redirect |
| `portal/handlers.go` | Pass normalized user `role` into `sessionManager.CreateSession` at existing interactive submit site |
| `portal/main.go` | Register `GET /api/labs`, `GET /launch`, `POST /api/labs/clone` under authenticated `ui` group |
| `portal/templates/index.html` | Add "Curriculum Labs" card (list, Open RO, Clone to `my_labs/`) |
| `scripts/init-storage.sh` | Seed `/mnt/storage/labs/` (`0:2999`, `2775`) from `templates/projects/project1/starter_labs/` |
| `scripts/mock-lms.py` | Local-machine-only makeshift LMS demo server (`localhost:9090`, HS256 SSO redirect) |
| `scripts/verify-lab-launcher.sh` | Stage 2 live cluster verification probe |

## Acceptance criteria
1. **Happy Path (Student Deep-Link, Pod Reuse & Read-Only Mount):**
   - Given a `student` with a valid `sandbox_token` hitting `GET /launch?lab=01_hello_sandbox.ipynb`,
   - When `portal` spawns (or reuses) their CPU-only `jupyterlab` pod,
   - Then the pod mounts `subPath: "labs"` at `/mnt/storage/projects/<project>/labs` with `ReadOnly: true` (and does NOT include GID `2999`), and `GET /launch` redirects `302` to `/<username>/jupyterlab/<sessionID>/lab/tree/labs/01_hello_sandbox.ipynb`.
   - When the student hits `GET /launch?lab=02_data_processing_polars.ipynb` again while that pod is running, the existing `sessionID` is reused without spawning a second pod.
2. **Failure/Boundary Rejection (Path Traversal, Symlink Escape & Write Isolation):**
   - Given `?lab=../../etc/passwd`, `?lab=/etc/passwd`, or `?lab=01_hello_sandbox.txt` (non-`.ipynb`), `GET /launch` and `POST /api/labs/clone` return `400 Bad Request`.
   - Given a symlink inside `LABS_DIR` pointing outside `LABS_DIR`, `resolveLabPath` rejects it with `400 Bad Request`.
   - Given a `student` pod attempting to write to `/mnt/storage/projects/<project>/labs/test.txt`, the kernel rejects with `EROFS`.
   - Given an `instructor` or `admin` pod, `subPath: "labs"` is mounted `ReadOnly: false` with supplemental GID `2999`, and writes to `/mnt/storage/projects/<project>/labs/` succeed.
3. **Integration Contract (Dynamic Discovery & Clone to Writable `my_labs/`):**
   - Given flat `.ipynb` files and nested module notebooks (`week01/lab.ipynb`) in `/mnt/storage/labs/`, `GET /api/labs` returns both dynamically.
   - When a student calls `POST /api/labs/clone` with `lab=01_hello_sandbox.ipynb`, the file is copied to `/mnt/storage/projects/<active_project>/my_labs/01_hello_sandbox.ipynb` (non-clobbering on repeat clone) with the student's resolved `uid:gid` ownership, and is writable from inside the student's pod.

## Open questions
- Resolved: 1A (`labs/` RO mount, `my_labs/` writable clone target), 2A (`0:2999`, `2775` + GID `2999` for staff), 3A (20s synchronous readiness poll), safe relative paths for flat + nested labs, Portal Labs card + local `scripts/mock-lms.py`.

## Test / Verification plan (Locked at Gate C)
- Stage 1: `cd portal && go test -v -race ./... && go vet ./... && golangci-lint run && bash -n ../scripts/init-storage.sh ../scripts/verify-lab-launcher.sh && python3 -m py_compile ../scripts/mock-lms.py`
- Stage 2: `bash scripts/verify-lab-launcher.sh`

## Bolt log (Updated at Gate D)
- Pending implementation.
