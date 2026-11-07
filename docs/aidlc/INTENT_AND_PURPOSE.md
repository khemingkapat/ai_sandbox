# Intent and Purpose: Why this project adopts AI-DLC

## Who this is

A solo developer (Khem) working with a coding agent (Antigravity) on `ai_sandbox`. There is no team, so the agent and I are the whole "mob."

## Where I am now

- I've used coding agents mostly for **implementation and testing**, working in loosely planned increments that follow the current plan and situation.
- That worked while the project was small. The project has now **grown substantially**, and some work feels like a **never-ending loop**: the agent and I go around the same problem repeatedly without converging.
- I've only learned the basic concepts of AI-DLC so far, and I want to adopt it in a way that fits a solo project, not copy a team ritual.

## Diagnosis (repo survey evidence)

The loops come from these causes, which AI-DLC is designed to address:

1. **"Done" is vague & "False Affirmation" tests:** Starting from high-level goals without concrete specs, building only the happy path, and running narrow surface tests that pass. Hardware/cluster edge cases (GPU time-slicing, NFS `subPath` mounts, Traefik ForwardAuth headers) cause repeated post-merge breakage.
2. **The 50% Rework Tax:** Discovering in the *next* sprint that previously "finished" features weren't properly integrated, consuming half of every new sprint fixing old work.
3. **Context bloat & competing sources of truth:** `docs/` grew to 42 markdown files (~724 KB). Multiple files recorded conflicting versions of reality (`WORK_PACKAGES.md`, `INCREMENT_LOG.md`, individual spec files). New agent sessions made assumptions that drifted from earlier decisions.
4. **Units of work too big or fuzzy:** Work packages spanned multiple days, mixing infrastructure, container builds, security policies, and application code.
5. **No stop rule:** When an attempt failed, the agent kept retrying endlessly instead of stopping after 3 attempts to re-examine the constraint or spec.

## Intent (what I want)

- Move my effort from **babysitting implementation** to **making decisions and approving work**.
- Make the project **resumable by a fresh agent session** from the repo alone.
- Replace open-ended loops with **small, verifiable bolts** that end in a clear pass/fail.
- Keep a record of **why** decisions were made, not only what the code does.

## Purpose of adopting AI-DLC specifically

- **Inception → Construction → Operations** as phases, with each phase passing richer context to the next.
- **GitHub Issues/Project (Epics) ↔ Repo Units (1-day bolts):** High-level roadmap lives on GitHub; concrete 1-day execution bolts live in `docs/aidlc/units/`.
- **The AI proposes and asks; I validate:** The agent drafts specs/plans, asks clarifying questions in batches, and implements only after Gate A+B approval.
- **Persistent context:** Standard 1-page files carry decisions between sessions.
- **Verification at every step:** Dual-path testing (cloud static/unit tests + in-cluster hardware verification probes) derived from acceptance criteria.

## What I'm deliberately NOT doing

- Not adopting team rituals (Mob Elaboration/Mob Construction) as formal meetings. For me they become short Q&A and approval exchanges with the agent.
- Not rewriting the whole project or writing specs for everything up front. Detail is added **just in time, per unit**.
- Not going fully hands-off. The agent can work autonomously **inside a bolt, against approved tests**, but I stay in the loop at the gates defined in the working agreement.
- Not producing heavy documentation. Docs stay short (~1 page max) and are updated as part of finishing a bolt, or they get deleted.

## Project facts

- **What the project does:** **AI Sandbox** is a turnkey AI engineering platform for students. It provides a single web portal to launch browser-based interactive workspaces (JupyterLab, VS Code, Bash) and submit batch GPU/CPU jobs (Slurm + Apptainer), connected to shared central services (vLLM inference, MLflow experiment tracking, curated datasets/models, and planned Qdrant vector search).
- **Main components:**
  1. **Web Portal (`portal/`):** Go 1.24 + Echo service managing user login, HMAC Bearer tokens, dynamic Kubernetes interactive session Pods (`workload` namespace), and Slurm batch job dispatch (`sbatch`).
  2. **Compute & Orchestration (`k8s/`, `helm/`):** Multi-node K3s cluster on Proxmox (with 1x NVIDIA L40 46GB GPU; Kind supported for local dev) running SchedMD **Slinky** (`slurm-operator`, `slurmctld`, `slurmd` NodeSets, `slurmdbd` + MariaDB) and **Traefik** ingress with ForwardAuth.
  3. **Central AI Services (`k8s/`, `services` namespace):** **vLLM** (`v0.31.0` serving Qwen 3.5 / Qwen 2.5 / Gemma 4 with rate-limiting), **MLflow** (Gunicorn WSGI + PostgreSQL 16 + proxied artifacts), in-cluster **OCI Registry** (`registry:2`), and planned **Qdrant** vector DB.
  4. **Shared Storage (`storage/` → `/mnt/storage`):** Host/NFS storage isolated via Kubernetes `subPath` mounts (`projects/<team>`, `scratch`, read-only `datasets`, `models`, and `common/etc`).
- **Stack and test tooling:**
  - **Portal:** Go 1.24 (`go test ./...`, `golangci-lint`).
  - **Cluster & Services:** Empirical bash/Python verification suites in `scripts/` (`test-student-golden-path.sh`, `verify-llm.sh`, `verify-mlflow.sh`, `verify-security.sh`, `verify-isolation.sh`, `verify-storage.sh`, `verify-backend-complete.sh`).
  - **Agent & Rules:** Google Antigravity (`AGENTS.md` and specialized `pro` subagent skills `audit-spec` and `verify` in `.agents/`).
- **Fixed decisions not to revisit:**
  1. **Two-path workload execution:** Interactive sessions run as native Kubernetes OCI Pods (`workload` namespace); Batch jobs run via Slurm `sbatch` + Apptainer `.sif`.
  2. **Zero LDAP/SSSD:** Container UID/GID identity uses `libnss-extrausers` (`/var/lib/extrausers` mounted read-only from `/mnt/storage/common/etc`) plus non-root `PodSecurityContext` (`mode 2770` + `umask 0002` for project directories).
  3. **Scoped `subPath` VFS isolation:** Student pods only mount their specific project `subPath` and approved shared folders — never the root `/mnt/storage` volume.
  4. **Single-L40 (46GB) GPU sharing:** Time-slicing (`replicas: 4`) for concurrent interactive/vLLM (`0.65` VRAM cap), with scripted vLLM scale-down when exclusive Slurm `batch-gpu` jobs run.
  5. **Interactive Pair Engineering:** Direct execution by Khem + Antigravity on the live cluster (asynchronous cloud agent Jules is retired).

## Success looks like

In a few bolts I should see: fewer agent attempts per task, less rework after "done," fewer surprises at review, regressions caught by tests, and a fresh session that can pick up the work without me re-explaining the project.
