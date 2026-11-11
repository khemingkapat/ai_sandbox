# Working Agreement (rules for the agent and me)

This is a lightweight, solo adaptation of AI-DLC. Follow it for every unit of work. It combines spec-driven development (to decide *what* and *why*) with test-driven development (to verify *whether it works*).

## Core principles

1. **Read context first.** At the start of every session, read `docs/aidlc/PROJECT_CONTEXT.md`, `UNITS.md`, and the relevant unit spec and decision records. Don't rely on chat memory.
2. **GitHub WP (Epics) ↔ Repo Units (1-Day Bolts):** High-level roadmap and milestone tracking live in GitHub Issues & GitHub Project #6. Inside the repo, each work package is broken down into small, 1-day code bolts in `docs/aidlc/units/` on dedicated feature branches (`feat/<unit-name>`).
3. **Fine-Grained Commit Granularity:** On feature branches, commit in incremental, logical milestones rather than one monolithic commit at the end:
   - Commit 1: Spec & Inception (`docs/aidlc/units/<unit>.md` approved at Gate A+B)
   - Commit 2: Locked Gate C tests (`*_test.go` or verification probes)
   - Commit 3: Production implementation satisfying the locked tests
   - Commit 4: Scripts, manifests, docs, and Bolt Log closure at Gate D
4. **Ask, then build (Gate A+B).** For any new unit, use `analyze-gap` to explain the mental model and physical data path in plain English, resolve 2-3 strategic decisions, draft the 1-page spec + plan, and run `audit-spec` (Red-Team Auditor). Don't write production code or modify cluster manifests until I approve.
4. **Comprehensive Criteria Rule:** Every unit spec must define: (a) primary happy path, (b) at least one failure/boundary rejection case (negative proof), and (c) integration verification with existing services.
5. **Dual-Path Testing (Gate C):**
   - **Stage 1 (Cloud fast checks):** `go test -race`, `golangci-lint`, `bash -n`, `kubeconform`.
   - **Stage 2 (In-Cluster hardware verification):** Locked verification scripts (`scripts/verify-*.sh` or `test-student-golden-path.sh`) run on the live cluster (concurrency = 1 to protect the single NVIDIA L40 GPU).
   Approved Gate C tests/probes are locked via SHA-256 manifest; the harness interceptor enforces that test files cannot be modified during construction.
6. **Tiered Model Strategy:**
   - **Phase 1 (Inception & Audit):** Use reasoning flagship `gemini-argon` for deep architectural stress testing, edge case detection, and boundary validation.
   - **Phase 2 & 3 (Test Locking & Construction):** Use daily workhorse `gemini-flash` (free AI Studio first, with LiteLLM automatic spillover to Vertex AI credits on rate limits) for token-efficient, fast test writing and implementation loops.
   - **Phase 4 (Gate D Acceptance):** Use `gemini-flash` for empirical verification and log inspection.
7. **Stop rule (3-Strike escalation):** If the same failure happens 3 times, stop and ask with hypothesis and options. Do not spiral.
8. **Keep context true (Gate D):** Finishing a bolt requires empirical proof (untampered tests, scope check, live cluster run receipts, cluster invariants), updating the unit's Bolt Log in `docs/aidlc/units/<unit>.md`, flipping status in `UNITS.md`, and updating decisions if boundaries changed. *(When auditing or remediating legacy components built prior to AI-DLC adoption, follow [`TRANSFORMATION_PLAYBOOK.md`](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/TRANSFORMATION_PLAYBOOK.md)).*

## The cycle for each unit

### Phase 1: Inception & Plan (bundled per unit)

- **Model:** `gemini-argon` (flagship reasoning).
- Agent runs `analyze-gap` to explain the concept in plain English, map the physical data path, verify live cluster state, and ask 2-3 strategic decisions.
- Agent drafts a 1-page unit file `docs/aidlc/units/<unit-name>.md` using the template:
  - **What & Why (Spec):** intent, scope, non-goals, constraints, concrete acceptance criteria (Given/When/Then).
  - **Anti-"False Affirmation" check:** Includes happy path, boundary failure case, and integration contract.
  - **Scope Protection:** Explicit list of "Files Allowed to Touch".
  - **How (Plan):** approach, exact files to touch, risks, and open questions.
- Agent runs `audit-spec` (adversarial Red-Team persona) to stress-test the plan against L40 GPU contention, 3-tier boundaries, and UID storage isolation.
- **Gate A+B (me):** Interactive checkpoint via `checkpoint_gate`. Option to review/edit spec in `$EDITOR` (`nvim`). Approves combined Spec + Plan before any code or tests are locked.

### Phase 2: Construction (the bolt)

- **Model:** `gemini-flash` (daily workhorse).
1. **Tests / Verification Probes first:**
   - For **Go portal / code logic**, agent writes automated unit tests (`go test`) derived from acceptance criteria.
   - For **Kubernetes / Slurm / Infrastructure**, agent writes or updates verification probes (`scripts/verify-<unit>.sh`).
   - Agent confirms tests fail for the right reason (not syntax/import bugs) and provides negative proof.
   - **Gate C (me):** Interactive checkpoint via `lock_tests`. Generates SHA-256 hash manifest. Harness interceptor activates to block any file edits to locked tests.
2. **Implement:**
   - Agent works autonomously until locked tests pass.
   - Harness blocks any write/edit to locked tests.
   - Cluster verification executes via `run_test_probe` (flock-protected, running in a live Herdr split pane with zero LLM polling).
3. **Bolt summary & empirical verification:**
   - Agent runs `verify` skill: attaches test execution receipts, checks untampered test hashes, verifies 0 out-of-scope edits, and confirms L40 GPU and Slurm cluster invariants.
   - **Gate D (me):** Interactive checkpoint via `checkpoint_gate`. Option to inspect raw receipts and git diff in `$EDITOR` (`nvim`). Accept bolt and flip status in `UNITS.md`.

### Phase 3: Operations / feedback

- After merge or live cluster use, note what was learned: bugs, surprises, spec gaps.
- Update `UNITS.md` status and `PROJECT_CONTEXT.md` if the picture changed.
- New needs become new units, not extra scope on the finished one.

## Escalation (the anti-loop rule)

Stop and ask me instead of continuing when any of these happen:

- The same failure or approach has been tried **3 times** without progress.
- A fix would require changing an approved test or the acceptance criteria.
- The work needs a decision outside the unit spec (architecture, dependencies, data model, public interfaces).
- Two requirements appear to conflict.
- The bolt is clearly bigger than expected.

When escalating, report: what you tried, what you observed, your best hypothesis, and 2–3 options with a recommendation. Then wait.

**Looping is a signal that the spec or context is wrong.** Our response is to fix the spec or context file, then restart the bolt, not to prompt harder.

## Boundaries for autonomy

**Agent decides alone:** implementation details inside the approved plan, refactors within the unit's files, naming, internal helper tests.

**Agent must ask:** new dependencies, schema/API changes, changes outside the unit's scope, deleting or rewriting existing behavior, anything that touches a recorded decision in `docs/aidlc/decisions/`.

**Autonomy expands over time** only when the checklist metrics show the process is working (see `ADOPTION_CHECKLIST.md`).

## Decision records

When a non-trivial architectural decision is made, add `docs/aidlc/decisions/NNNN-title.md` (short 1-page; template in `TEMPLATES.md`). Don't contradict an existing record without asking me.

## Writing style for docs

Short, concrete, current. A page per unit is plenty. If a doc isn't being read or kept current, propose deleting it.

## Project-specific notes

- **Test command(s):**
  - **Go Portal (`portal/`):** `cd portal && go test -v ./...`
  - **End-to-End Student Golden Path:** `bash scripts/test-student-golden-path.sh`
  - **Component Verification Suites:**
    - LLM Inference & QoS: `bash scripts/verify-llm.sh`
    - MLflow Tracking: `bash scripts/verify-mlflow.sh`
    - Network & Security Baseline: `bash scripts/verify-security.sh` and `bash scripts/verify-isolation.sh`
    - Shared Storage & Permissions: `bash scripts/verify-storage.sh`
    - Slinky / Slurm Infrastructure: `bash scripts/verify-infrastructure.sh`
- **Lint/format/type-check commands:**
  - **Go Portal:** `cd portal && go vet ./... && golangci-lint run`
- **Areas needing extra care:**
  - **Single NVIDIA L40 (46GB) GPU contention:** vLLM holds ~65% VRAM in `services` namespace; exclusive batch GPU jobs in Slurm (`batch-gpu`) require coordinated vLLM scale-down or time-slicing respect.
  - **Storage & UID/GID isolation:** Interactive pods in `workload` namespace must strictly use scoped `subPath` mounts and non-root `PodSecurityContext` (never expose root `/mnt/storage` or `/mnt/storage/mlflow` to student pods).
  - **Traefik ForwardAuth & NetworkPolicies:** Any new service in `services` namespace requires explicit CNI egress rules from `workload` and Traefik middleware wiring.
