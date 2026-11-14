# 0007 — Self-Service Identity Resolution & Dynamic Project Provisioning

Date: 2026-11-14
Status: accepted
Extends: [ADR 0002 — Storage Isolation, Identity & UID Security](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md)

## Context
The AI Sandbox is designed as long-lived university infrastructure that must operate automatically with minimal sysadmin intervention across large student cohorts (hundreds to thousands of students and projects).

Previously, identity and project provisioning assumed a static, top-down model (`sacctmgr` as source of truth, or manual `useradd` / hardcoded `user<N>` prefixes in `portal/auth.go`). In practice:
1. **Authentication** comes from a Central University Portal that passes only a `student_id` inside a **signed JWT**.
2. **Projects are self-service:** Any student can log in, create a new project (e.g., `"Agent Harness"`), and invite other students by `student_id`. Thousands of projects may be created over time, with different students choosing identical display names.
3. **Storage & Topology:** `/mnt/storage` is a ~10TB **NFS** share mounted locally on `ai-control` (where the Portal runs) and across worker nodes.
4. **Slurm requirement:** Slurm accounting (`slurmdbd` / `sacctmgr`) still requires every user and project account association to exist in SlurmDBD before `sbatch` / `slurmrestd` will accept jobs.

## Decision
Adopt a **Portal-Driven Self-Service Provisioning** model where the Web Portal is the single entry point and source of truth, automatically synchronizing downstream Linux (`libnss-extrausers`) and Slurm (`slurmrestd`) state:

1. **Identity & Project State Store (Postgres 16, NOT SQLite on NFS):**
   - Store `users` (`student_id`, `uid`), `projects` (`project_id` slug, `display_name`, `gid`, `owner_student_id`), and `memberships` in a lightweight schema inside the existing Postgres 16 instance in the `services` namespace (or a local-disk PV on `ai-control`).
   - **Never** store SQLite on `/mnt/storage` (NFS) due to POSIX `fcntl` locking hazards.
   - UIDs (`2000+`) and GIDs (`10000+`) are monotonically allocated and **never reused**.

2. **Linux Layer (`libnss-extrausers` as Compiled Output):**
   - Retain `libnss-extrausers` per [ADR 0002](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/decisions/0002-storage-and-uid-isolation.md).
   - `/mnt/storage/common/etc/passwd` and `/mnt/storage/common/etc/group` are treated as deterministic, rebuildable projections of the Portal DB, written atomically under `flock` (removing the `user<N>` restriction in `portal/auth.go` and legacy `kubectl exec useradd` scripts).
   - Project directories `/mnt/storage/projects/<project-id>` are provisioned with `chmod 2770` and the project's GID.

3. **Slurm Accounting Layer (`slurmrestd` + Reconciler):**
   - On user creation, project creation, or member invite, the Portal provisions the corresponding Slurm user, account (`<project-id>`), and association via `slurmrestd` (`/slurmdb/v0.0.42/`).
   - A periodic idempotent reconciler loop ensures `extrausers` and SlurmDBD stay converged with the Portal DB even if `slurmrestd` temporarily restarts.

4. **Guardrails for Scale:**
   - Use unique internal project slugs (`p-<id>`) for Linux groups, NFS paths, and Slurm accounts while keeping friendly `display_name` values in the DB.
   - Enforce a per-student active project quota (e.g., max 5 projects) to prevent unbounded `/mnt/storage` growth.

## Alternatives Considered
1. **Top-Down `sacctmgr` → `extrausers` Sync:** Rejected because `sacctmgr` has no concept of project display names, ownership, or self-service invitations, and cannot handle thousands of student-created projects with colliding names.
2. **OpenLDAP + `sssd`:** Rejected due to high operational babysitting (TLS cert rotation, bind credentials, daemon debugging across K3s upgrades) and because SlurmDBD still requires separate association syncing.

## Consequences
- **Positive:** Zero manual `sacctmgr` or `useradd` administration; survives pod restarts and node scaling; self-healing via DB-to-cluster reconciliation; simple enough for future student maintainers.
- **Negative:** Relaxes the "100% stateless Portal" constraint in `PROJECT_CONTEXT.md` by adding small persistent tables in Postgres.
- **Open Checks for Implementation Unit (`WP05-B`):**
  1. Verify `POST /slurmdb/v0.0.42/accounts` and `/associations` behavior on live `slurmrestd`.
  2. Verify NFS `root_squash` behavior on `ai-control` when creating and `chown`-ing `/mnt/storage/projects/<project-id>`.
  3. Confirm exact signed JWT claims/public key format from the Central University Portal.
