# Adoption Checklist

These criteria are a practical synthesis of AI-DLC's principles, adapted for a solo project. They are not an official standard. Review after each bolt. Start with the **Starter three**, then widen.

## Starter three (do these first)

- [ ] Every unit has written acceptance criteria before code starts.
- [ ] Tests derived from those criteria are written and approved by me before implementation.
- [ ] The agent has a stuck rule and follows it (stop and ask after 3 failed attempts).

## Process criteria

**Inception & Plan (Bundled Gate A+B)**
- [ ] Unit spec has intent, scope, non-goals, concrete acceptance criteria, and the implementation plan (files to touch + risks).
- [ ] The agent asked clarifying questions in one batch and my answers are written in the spec.
- [ ] I explicitly approved the combined Spec + Plan (**Gate A+B**).

**Persistent context**
- [ ] A fresh agent session can understand the project from `docs/aidlc/` without me re-explaining.
- [ ] Decisions and their reasons are recorded in `decisions/`.
- [ ] Spot-check: `PROJECT_CONTEXT.md` and `UNITS.md` match the current code and cluster state.

**Construction**
- [ ] Bolt targets one unit and finishes within about a day.
- [ ] Spec + Plan approved (**Gate A+B**), failing tests / cluster probes locked (**Gate C**), final result reviewed (**Gate D**).
- [ ] Locked Gate C tests/probes were not edited, weakened, or skipped without asking me.
- [ ] Bolt summary lists assumptions and open decisions.

**Escalation**
- [ ] When stuck, the agent stopped with what it tried, a hypothesis, and options.
- [ ] After a loop, we fixed the spec or context instead of just re-prompting.

## Outcome metrics (track per bolt; trend matters)

| Bolt | Unit | Agent attempts / loops | Rework after "done" | Regressions | "I didn't ask for that" surprises | My time: approving vs fixing |
|------|------|------------------------|---------------------|-------------|-----------------------------------|------------------------------|
|      |      |                        |                     |             |                                   |                              |

Healthy trends: attempts falling, rework falling, regressions rare and caught by tests, surprises falling, time mostly spent approving.

## Self-test

1. Could a fresh agent tell what the project is meant to do and why, from the repo alone?
2. For my last finished unit, can I point to the approved criteria and the tests that prove them?
3. When the agent last got stuck, did it stop and ask or spiral?
4. Did my time go to decisions rather than babysitting?

## Warning signs of going through the motions

- Specs written once and never updated.
- Tests written after code, or edited until they pass.
- I approve plans without reading them.
- Bolts keep growing into multi-day efforts.
- Context files are long and nobody (including the agent) uses them.
- Loops continue, now with more paperwork.

## When to widen the agent's autonomy

Consider it only after several bolts where: loops and rework dropped, regressions were caught by tests, and Gate D reviews rarely surfaced surprises. Widen one boundary at a time (for example, let the agent skip Gate B for low-risk units) and watch the metrics.
