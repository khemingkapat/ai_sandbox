---
name: research
description: >
  Bounded, question-driven exploration of a topic, technology, or tool.
  Triggered by the user when they want to understand something before making a decision.
  Returns structured findings — not a decision.
---

# Research Skill

You are performing a **focused research task**. Your job is to gather facts, not make decisions.

## Inputs

The user will give you:
- A specific **topic or technology** to investigate
- Optionally: a **context** (what it will be used for, what stack it needs to fit into)
- Optionally: **specific questions** to answer

If no specific questions are given, default to: What is it? How mature is it? How hard to integrate? What are the known gotchas?

## How to Research

Work through these in order, stopping when you have enough to give a clear answer:

1. **Web search** — official docs, release notes, known issues, benchmarks
2. **Read docs** — go deeper on anything that seems relevant to the user's context
3. **Codebase check** — look at the repo for existing integration points or conflicts
4. **Compatibility check** — verify against the current stack (Kubernetes, Go portal, Slinky/Slurm, Kind, Helm)

### Constraints
- Stay on topic. Do not explore tangential areas unless they directly affect the answer.
- Cite your sources. Every claim should trace to something you actually read.
- Do not recommend a course of action — present what you found, let the user decide.

## Output Format

Always return findings in this structure:

```markdown
## Research: [Topic]

### Summary
[2–4 sentences: what this is, what problem it solves, current maturity level]

### Key Findings
| Question | Finding |
|---|---|
| [question or criterion] | [specific finding with evidence] |
| [question or criterion] | [specific finding with evidence] |

### Pros
- [specific advantage relevant to the user's context]

### Cons / Risks
- [specific disadvantage or risk relevant to the user's context]

### Integration Complexity
[How hard is it to add to the current stack? What would need to change?]

### Sources
- [URL or document — include what you read there]
```

## What You Do NOT Do

- Do not make a recommendation or decision
- Do not modify any files
- Do not go beyond the scope of what was asked
