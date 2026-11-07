# Working Agreement (rules for the agent and me)

This is a lightweight, solo adaptation of AI-DLC. Follow it for every unit of work. It combines spec-driven development (to decide *what* and *why*) with test-driven development (to verify *whether it works*).

## Core principles

1. **Read context first.** At the start of every session, read `docs/aidlc/PROJECT_CONTEXT.md`, `UNITS.md`, and the relevant unit spec and decision records. Don't rely on chat memory.
2. **GitHub WP (Epics) ↔ Repo Units (1-Day Bolts):** High-level roadmap and milestone tracking live in GitHub Issues & GitHub Project #6. Inside the repo, each work package is broken down into small, 1-day code bolts in `docs/aidlc/units/`.
3. **Ask, then build (Gate A+B).** For any new unit, ask clarifying questions and propose a 1-page spec + implementation plan. Don't write production code or modify cluster manifests until I approve.
4. **Anti-"False Affirmation" rule:** Every unit spec must define: (a) primary happy path, (b) failure/boundary rejection case, and (c) integration verification with existing services so we avoid the 50% rework tax.
5. **Dual-Path Testing (Gate C):**
   - **Stage 1 (Cloud fast checks):** `go test -race`, `golangci-lint`, `bash -n`, `kubeconform`.
   - **Stage 2 (In-Cluster hardware verification):** Locked verification scripts (`scripts/verify-*.sh` or `test-student-golden-path.sh`) run on the live cluster (concurrency = 1 to protect the single NVIDIA L40 GPU).
   Approved Gate C tests/probes are locked; the agent must never weaken, skip, or delete them.
6. **Stop rule (3-Strike escalation):** If the same failure happens 3 times, stop and ask with hypothesis and options. Do not spiral.
7. **Keep context true (Gate D):** Finishing a bolt includes updating the unit's Bolt Log in `docs/aidlc/units/<unit>.md`, flipping status in `UNITS.md`, and updating decisions if boundaries changed.

## The cycle for each unit

### Phase 1: Inception & Plan (bundled per unit)

- Agent drafts a 1-page unit file `docs/aidlc/units/<unit-name>.md` using the template:
  - **What & Why (Spec):** intent, scope, non-goals, constraints, concrete acceptance criteria (Given/When/Then).
  - **Anti-"False Affirmation" check:** Includes happy path, boundary failure case, and integration contract.
  - **How (Plan):** approach, exact files to touch, risks, and open questions.
- *(Optional)* For units touching core cluster boundaries or security, agent runs the `audit-spec` (`pro` subagent) skill to stress-test the plan before presenting it.
- Agent asks me clarifying questions in one batch.
- **Gate A+B (me):** I answer questions and approve the combined Spec + Plan in one step. No production code or cluster changes happen before this gate.

### Phase 2: Construction (the bolt)

1. **Tests / Verification Probes first:**
   - For **Go portal / code logic**, agent writes automated unit tests (`go test`) derived from the acceptance criteria.
   - For **Kubernetes / Slurm / Infrastructure**, agent writes or updates an empirical verification script (`scripts/verify-<unit>.sh` or specific assertion probes) that tests the live cluster state against the acceptance criteria.
   - Agent confirms the tests/probes fail for the right reason (or accurately detect the unbuilt state) and stops.
   - **Gate C (me):** I review and approve the tests/probes. Approved tests are **locked**.
2. **Implement:**
   - Agent works autonomously until the locked tests/probes pass on the live cluster.
   - It may add helper unit tests, but it must **not edit, weaken, delete, or skip locked Gate C tests** without asking me.
3. **Bolt summary & verification:**
   - Agent runs final verification (plus the `verify` skill if needed) and reports what changed, test results, assumptions made, decisions that need me, and docs updated.
   - **Gate D (me):** Quick review, then accept or send back.

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
