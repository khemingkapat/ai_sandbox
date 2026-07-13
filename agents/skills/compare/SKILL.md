---
name: compare
description: >
  Side-by-side evaluation of 2+ competing options.
  Spawns parallel Researcher subagents for each option, then compiles a comparison table.
  Triggered by the user when they need to pick between approaches.
---

# Compare Skill

You are running a **structured comparison**. Your job is to evaluate options fairly and present the tradeoffs clearly so the user can make an informed decision.

## Inputs

The user will give you:
- **2 or more options** to compare (technologies, approaches, designs)
- Optionally: **evaluation criteria** to use
- Optionally: **context** (stack constraints, priorities, scale)

If no criteria are given, use sensible defaults: fit for purpose, integration complexity, operational burden, community/maturity, performance.

## Step 1: Define the Research Brief

Before spawning anything, define:
1. The **shared evaluation criteria** all options will be judged on (same criteria for all)
2. The **context paragraph** each Researcher needs (stack, constraints, what "good" looks like)
3. The **specific question** for each option (same question pattern, different subject)

## Step 2: Spawn Parallel Researchers

Read [.agents/agents/researcher/agent.json](file:///home/khemi/workspace/ai_sandbox/.agents/agents/researcher/agent.json) to get the authoritative Researcher configuration, then:

1. Call `define_subagent` with those parameters
2. Call `invoke_subagent` — one instance **per option**, all at the same time (parallel)
3. Each Researcher gets: option name, evaluation criteria, context, output format requirement

Wait for all Researchers to report back before proceeding.

## Step 3: Compile Comparison

Merge all Researcher outputs into a single comparison table:

```markdown
## Comparison: [Option A] vs [Option B] (vs ...)

### Context
[One sentence: what decision this comparison is for]

### Comparison Table
| Criterion | [Option A] | [Option B] |
|---|---|---|
| [criterion 1] | ... | ... |
| [criterion 2] | ... | ... |
| Integration complexity | ... | ... |
| Operational burden | ... | ... |
| Maturity / community | ... | ... |

### Summary
- **[Option A]:** [2-sentence characterization]
- **[Option B]:** [2-sentence characterization]

### Recommendation
[Which option fits best for this context, and the single most important reason why]

> Final decision is yours.
```

## What You Do NOT Do

- Do not make the decision for the user — present a recommendation but respect their choice
- Do not skip the parallel Researcher step for non-trivial comparisons
- Do not add unsolicited options beyond what the user asked to compare
- Do not modify any files
