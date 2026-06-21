---
name: design-spec
description: >
  Produces a concrete implementation specification after the user has made a design decision.
  Defines what to build, what files to touch, acceptance criteria, and boundaries.
  Triggered by the user after they've decided on an approach.
---

# Design Spec Skill

You are writing an **implementation specification**. The design decision has already been made by the user. Your job is to translate that decision into a precise, unambiguous blueprint that an implementer can follow without guessing.

## Inputs

The user will give you:
- The **feature or task** to specify
- The **design decision** already made (approach, technology, pattern)
- Optionally: context from a prior `compare` or `research` output

## Consistency Check (Do This First)

Before writing anything, verify against the existing codebase:

- Does this conflict with `values.yaml`, `kind-config.yaml`, or the portal code?
- Does this depend on something that isn't done yet (check `WORK_PACKAGES.md`)?
- Will this work in both local Kind dev AND the production HPC environment?
- Does this introduce new dependencies that affect other work packages?

Flag any conflicts clearly in the spec. Do not silently skip them.

## Output Format

Produce a spec document structured as:

```markdown
## Spec: [Feature / Task Name]

### Decision
[One sentence: what was decided and why — the "why" matters for the implementer]

### Scope
[One paragraph: what this spec covers and explicitly what it does NOT cover]

### Files to Create
| File | Purpose |
|---|---|
| `path/to/new/file` | [What it does, key contents] |

### Files to Modify
| File | Changes |
|---|---|
| `path/to/existing/file` | [Specific changes — not vague like "update this"] |

### Files NOT to Touch
| File | Reason |
|---|---|
| `values.yaml` | Helm config, requires physical cluster testing |
| `kind-config.yaml` | Cluster topology |
| [others] | [reason] |

### Acceptance Criteria
Every criterion must be **objectively testable**. No subjective language.

- [ ] [Specific build/lint check — e.g., `go build ./...` exits 0]
- [ ] [Specific functional test — e.g., `GET /api/health` returns 200]
- [ ] [Specific file/output check]
- [ ] No changes to files in "Files NOT to Touch"
- [ ] `INCREMENT_LOG.md` has a new entry

### Design Rationale
[2–4 sentences: why this approach over alternatives. Reference the compare/research output if applicable.]

### Open Questions
[Anything the implementer will need to decide that isn't resolved by this spec — or "None."]
```

## Quality Bar

Before presenting the spec, check:
- [ ] Every acceptance criterion is objectively pass/fail
- [ ] Every file path is full (not just a filename)
- [ ] The scope explicitly states what is out of scope
- [ ] No implementation details are left ambiguous

## What You Do NOT Do

- Do not re-open the design decision — the user has decided
- Do not write implementation code
- Do not create GitHub Issues (that's the `create-issue` skill)
