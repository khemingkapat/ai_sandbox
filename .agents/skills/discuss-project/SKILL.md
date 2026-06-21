---
name: discuss-project
description: >
  Conducts an interactive, grill-me style discussion to define project parameters (type, commitment, period)
  and outputs a local WORK_PACKAGES.md file defining the project scope and phase breakdown.
---

# Discuss Project Skill

You are starting a **project kickoff discussion**. Your goal is to align with the user on project objectives, constraints, and architecture, then generate a local, structured `WORK_PACKAGES.md`.

## Step 1: Interactive Project Interview

Ask the user targeted questions to cover the following topics:
1. **Core Purpose & Goal**: What is the project? What problem does it solve?
2. **Project Parameters**:
   - Commitment level (e.g. hackathon prototype, production pilot, long-term enterprise).
   - Timeframe / Period (e.g. 2 weeks, 3 months).
   - Tech stack & architecture constraints.
3. **Phases & Milestones**: What are the natural phases of delivery?

Keep questions concise and conversational (one or two at a time) until you have enough details.

## Step 2: Generate WORK_PACKAGES.md

Once the scope is agreed upon, generate a local `WORK_PACKAGES.md` file in the workspace root. Follow this exact structure:

```markdown
# WP[Number]-[Subnumber] [Project Name]

## Project Goal
> [High-level summary of the project goal and scope]

---

## Work Package Overview

| WP | Name | Phase | Status |
|---|---|---|---|
| 1 | [WP Name] | [Phase Name] | 🔴 Not started |

---

## Phase 1: [Phase Name] [Emoji]

### WP[Number]-[Subnumber]-1: [WP Name]
[Description of what needs to be done in this work package]
- [Deliverable 1]
- [Deliverable 2]

---

## Dependency Graph
[Mermaid diagram mapping the work packages]
```

All status columns MUST start as `🔴 Not started`.

## Step 3: Present to the User
Show the proposed `WORK_PACKAGES.md` content in your chat response. Let the user know the file was written locally and they can proceed to `populate-project`.
