# AI-DLC Templates

Copy these into `docs/aidlc/` as needed. Keep each filled-in document to about a page.

---

## A. `PROJECT_CONTEXT.md` (project-level inception, living doc)

```markdown
# Project Context: <project name>

Last updated: <date>

## Purpose
What the project is for and who it serves. 2–4 sentences.

## Major capabilities
- <capability> — status: done | partial | planned
- ...

## Architecture as it stands
Short description of the main components and how they interact.
Link to decision records for the "why".

## Key constraints
Tech stack, performance/security/budget limits, things that must not change.

## Conventions
How to run tests, lint, build. Naming and structure conventions worth knowing.

## Known problem areas
Areas that are fragile, looping, under-tested, or poorly understood.

## Open questions
Things unresolved that affect upcoming work.
```

---

## B. `UNITS.md` (units of work and status)

```markdown
# Units of Work

| # | Unit | Parent GitHub WP | Capability it serves | Status | Notes / dependencies |
|---|------|------------------|----------------------|--------|----------------------|
| 1 | <name> | #XX | <capability> | in-progress | <what is being built> |
| 2 | <name> | #XX | <capability> | planned | depends on #1 |

Status values: done | in-progress | looping/stuck | planned | exploratory

## Next up
The unit we're working on next and why it was chosen.
```

A unit should be small enough to finish in hours to about a day, and deliver one verifiable capability. If it's bigger, split it.

---

## C. `units/<unit-name>.md` (unit spec + plan, approved at Gate A+B)

```markdown
# Unit: <name>

Status: draft | approved (Gate A+B) | tests-locked (Gate C) | done (Gate D)
Parent GitHub WP: #XX
Exploratory? yes/no

## Intent
Why this unit exists, in 1–3 sentences.

## Scope & Non-goals
- **In scope:** What is included.
- **Non-goals:** What is explicitly excluded.

## Constraints and decisions to respect
Links to relevant decision records and project constraints.

## Implementation Plan (Bundled for Gate A+B)
- **Approach:** Brief plain-English mental model of how it works.
- **Files to touch:** Exact files to create/modify.
- **Risks / Edge cases:** Hardware, network, or state risks.

## Acceptance criteria
Concrete, testable examples. Must include happy path, failure/boundary case, and integration check.

1. Given <state>, when <action>, then <observable result>.
2. ...

## Open questions
Questions for me, with answers recorded here once resolved.

## Test / Verification plan (Locked at Gate C)
- Stage 1 (Cloud fast checks): `go test`, `bash -n`, etc.
- Stage 2 (In-Cluster hardware checks): `scripts/verify-*.sh` probes.

## Bolt log (Updated at Gate D)
- <date>: <what was done, result, assumptions, decisions needed>
```

---

## D. `decisions/NNNN-title.md` (decision record)

```markdown
# NNNN — <decision title>

Date: <date>
Status: proposed | accepted | superseded by NNNN

## Context
What problem or situation prompted this.

## Decision
What we chose.

## Alternatives considered
Briefly, and why they were rejected.

## Consequences
What this makes easier or harder. What would trigger revisiting it.
```

---

## E. Bolt summary (agent reports at Gate D)

```markdown
# Bolt summary: <unit> — <date>

## What changed
Files and behavior, briefly.

## Verification
Tests run, results, anything not covered.

## Assumptions made
Anything the agent assumed that I should confirm.

## Decisions needed from me
Open items, with options and a recommendation.

## Docs updated
Which of PROJECT_CONTEXT / UNITS / unit spec / decisions changed.

## Escalations during this bolt
Where the agent stopped and why, if it did.
```
