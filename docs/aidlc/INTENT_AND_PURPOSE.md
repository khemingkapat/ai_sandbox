# Intent and Purpose: AI-Driven Development Life Cycle (AI-DLC)

## Who we are

A solo developer and Lead Architect (Khem) paired with an interactive coding agent and Co-Architect (Antigravity) building `ai_sandbox`. Together, the human and agent form the entire engineering unit.

## Core intent

- **Decision-maker vs. Executor:** Shift human effort from babysitting implementation to making architectural decisions, resolving trade-offs, and approving verifiable work at explicit gates.
- **Zero-Amnesia Continuity:** Keep repository context concise and structured so any fresh agent session can resume work immediately from `docs/aidlc/` without relying on chat history.
- **Small, Verifiable Bolts:** Execute work in bounded units (sized from a few hours to a day) that end in a deterministic pass/fail against locked tests.
- **Architectural Traceability:** Record *why* key system boundaries and trade-offs were chosen (`docs/aidlc/decisions/`), not just what the code currently does.

## How we adapt AI-DLC for a solo systems project

- **Inception → Construction → Operations:** Each phase passes structured, high-signal context to the next:
  1. **Inception & Plan (Gate A+B):** Define what "done" means (happy path, failure/boundary case, and integration contract) and the exact file plan before writing code.
  2. **Construction (Gate C → Implement → Gate D):** Lock automated tests or live cluster verification probes first (Gate C), implement autonomously within bounded retries, and review the final bolt summary (Gate D).
  3. **Operations:** Update living context (`UNITS.md`, `PROJECT_CONTEXT.md`) and feed completed unit records into formal milestone deliverables (`docs/reports/`).
- **GitHub Epics ↔ Repo Bolts:** High-level work packages and milestone roadmaps live in GitHub Issues and GitHub Project #6; concrete 1-day implementation bolts live in `docs/aidlc/units/`.
- **AI Proposes, Human Validates:** The agent challenges assumptions, proposes designs, and batches clarifying questions; Khem holds final authority at every gate.

## What we deliberately do NOT do

- **No multi-person ceremony:** Team rituals (Mob Elaboration / Mob Construction) are replaced by direct, high-signal Q&A and gate approvals between Khem and Antigravity.
- **No upfront waterfall specs:** Detailed unit specifications in `docs/aidlc/units/` are created **just in time** when a bolt begins.
- **No unchecked autonomy:** The agent works autonomously *only* inside an approved bolt against locked Gate C tests, and must stop and escalate after 3 failed attempts.
- **No documentation bloat:** Every file in `docs/aidlc/` is capped at roughly one page. If a document is not actively read or maintained, it gets deleted.

## What healthy operation looks like

Fewer agent attempts per bolt, zero unapproved scope creep, regressions caught automatically by Stage 1 (code) and Stage 2 (live cluster) tests, effortless compilation of supervisor milestone reports, and instant session continuity.
