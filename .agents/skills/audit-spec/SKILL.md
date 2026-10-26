---
name: audit-spec
description: >
  Audits an architectural design or specification before implementation.
  Spawns an independent Auditor subagent using a 'pro' model to attack the design
  for boundary violations, over-engineering, bloat, and conceptual misalignment.
---

# Audit Spec Skill

You are conducting a pre-implementation architectural audit. Your goal is to eliminate "Yes-Man" bias by running an adversarial design review with an independent `pro` model before implementation or modifying cluster resources.

## Inputs

The user will provide:
- A draft **design spec**, architectural proposal, or work package plan.
- Relevant reference documents (e.g., [`docs/TECH_STACK_DECISION.md`](file:///home/khemi/workspace/ai_sandbox/docs/TECH_STACK_DECISION.md), [`docs/ENVIRONMENT_ASSESSMENT.md`](file:///home/khemi/workspace/ai_sandbox/docs/ENVIRONMENT_ASSESSMENT.md)).

---

## Step 1: Prepare the Audit Context

Extract the core architectural assumptions:
1. **Components Involved:** Which services, controllers, or nodes are being touched?
2. **Data Flow Path:** How do bytes, network packets, and API calls flow between components?
3. **New Dependencies:** Does this add new images, daemons, packages, or database schemas?

---

## Step 2: Spawn the Auditor Subagent (`Model: pro`)

Define and invoke the Auditor subagent using the `pro` model tier:

- **Role:** `Principal Platform Architect & Foundation Auditor`
- **Model:** `pro`
- **System Prompt / Task Brief:**
  Instruct the auditor to ruthlessly critique the draft design against **4 Foundation Pillars**:
  1. **3-Tier Boundary Integrity:** Does the design strictly isolate `slurm` (control plane), `services` (shared AI tools), and `workload` (untrusted student pods)? Are components taking on responsibilities that belong elsewhere?
  2. **Anti-Bloat & Simplicity:** Is this the simplest structural way to solve the problem? Are we adding custom code/sidecars where native Traefik, Kubernetes, or Slurm features already exist?
  3. **Tech Stack Consistency:** Does it adhere to locked-in decisions in [`docs/TECH_STACK_DECISION.md`](file:///home/khemi/workspace/ai_sandbox/docs/TECH_STACK_DECISION.md) (pre-baked images, read-only cache mounts, stateless portal)?
  4. **Clarity & Mental Model:** Is the data flow explained in concrete computer engineering terms (sockets, processes, files) so the Lead Architect (Khem) can make a confident decision?

---

## Step 3: Ping-Pong Reconciliation (1–2 Turns)

1. Receive the Auditor's critique.
2. Address each critique:
   - If the Auditor caught a boundary leak, bloat, or anti-pattern: **adopt the simpler/safer approach**.
   - If the Auditor made an impractical recommendation based on missing context: **rebut with physical cluster constraints**.
3. Synthesize the final hardened specification.

---

## Step 4: Output Format

Present the final reconciled architecture to the user in this structure:

```markdown
## 🏛️ Architectural Audit: [Feature / Work Package Name]

### 1. Plain-English Mental Model & Data Path
[Step-by-step physical flow using concrete CS fundamentals: client -> gateway -> auth -> backend -> hardware. No buzzwords.]

### 2. What Changed During Audit (Ping-Pong Diff)
- **Critique:** [What the Auditor pushed back on (e.g., unnecessary proxy logic in Go)]
- **Adjustment:** [How we simplified or corrected the architecture (e.g., delegated to Traefik ForwardAuth)]

### 3. Component Responsibility Matrix
| Component | Tier / Namespace | Responsibility | What It Must NOT Do |
| :--- | :--- | :--- | :--- |
| [e.g. Traefik] | `slurm` | Ingress routing & rate limiting | Must not parse internal JWT payloads |
| [e.g. vLLM] | `services` | GPU tensor compute & token streaming | Must not manage user auth or quotas |

### 4. Decisions for Khem
- **Decision 1:** [Clear binary choice or trade-off for Khem to approve]
```

## Constraints
- **Brief and Straight to the Point:** High-signal bullet points only. No essay filler.
- **Do NOT write implementation code in this skill:** Focus strictly on system design, boundaries, and trade-offs. Implementation happens after Khem approves the audited spec.
