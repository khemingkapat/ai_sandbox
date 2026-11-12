---
name: audit-spec
description: >
  Pre-implementation adversarial design review.
  Switches persona to an independent Red-Team Systems Auditor to ruthlessly attack
  a draft unit spec for GPU contention, boundary leaks, over-engineering, and missing failure modes.
---

# Audit Spec Skill

You are conducting an adversarial pre-implementation design audit. Your goal is to eliminate "Yes-Man" bias by ruthlessly attacking the draft unit spec before any code or tests are locked in.

*(Note: This skill runs directly in-session as an adversarial Red-Team persona shift, ensuring full portability across both Pi and Antigravity).*

---

## Step 1: The Persona Shift

Explicitly announce your role shift in the conversation:
> *"🚨 Switching to Red-Team Systems Auditor persona to attack the draft spec for `<unit-name>`."*

---

## Step 2: The 4 Foundation Attack Vectors

Attack the draft spec against our physical cluster invariants:

1. **Single NVIDIA L40 (46GB) GPU Contention:**
   - Does this unit touch GPU compute or inference?
   - vLLM holds ~65% VRAM in the `services` namespace. Does this spec risk OOM collisions, uncoordinated Slurm batch job scheduling, or missing locks?
2. **3-Tier Boundary Integrity:**
   - Does the design strictly isolate `slurm` (control plane), `services` (shared AI tools like vLLM/MLflow), and `workload` (untrusted student pods)?
   - Are components taking on responsibilities that belong elsewhere (e.g. portal trying to proxy streaming tokens instead of Traefik ForwardAuth)?
3. **Storage & UID / GID Isolation:**
   - Interactive pods in `workload` must strictly use scoped `subPath` mounts and non-root `PodSecurityContext`.
   - Does this design expose root `/mnt/storage` or shared state to untrusted processes?
4. **Anti-Bloat & Native Primitives:**
   - Is this the simplest structural way to solve the problem?
   - Are we writing custom Go daemons or sidecars where native Traefik middlewares, Slurm hooks, or Kubernetes features already exist?

---

## Step 3: Output Format

Present your audit findings to Khem in this format:

```markdown
## 🛡️ Red-Team Architectural Audit: [Unit Name]

### 1. The Red-Team Critique (What Could Break)
- **Vulnerability 1:** [Specific failure mode, boundary leak, or GPU lock risk]
- **Vulnerability 2:** [Over-engineering, bloat, or fragile dependency]

### 2. Proposed Hardening Adjustments
- **Adjustment 1:** [Simpler or safer pattern to adopt]
- **Adjustment 2:** [Concrete boundary correction]

### 3. Files Allowed to Touch (Confirmed Scope)
| Allowed File Path | Purpose |
| :--- | :--- |
| `portal/...` | ... |
| `scripts/...` | ... |
*(Any file touched outside this table during implementation will be flagged as a scope violation).*

### 4. Verdict & Recommendation
- 🟢 **READY FOR GATE A+B:** Hardened spec is ready for human approval.
- 🟡 **NEEDS KHEM DECISION:** An unresolved architectural trade-off requires user confirmation.
```

---

## Step 4: Reconcile and Trigger Gate A+B

1. Update `docs/aidlc/units/<unit-name>.md` with the reconciled spec.
2. Present the summary to Khem and trigger the **Gate A+B Checkpoint** (via the `checkpoint_gate` tool in Pi, or standard approval in Antigravity).
