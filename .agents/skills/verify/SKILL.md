---
name: verify
description: >
  Checks a PR or set of changes against functional acceptance criteria AND
  runs an architectural result audit using an independent 'pro' model subagent.
  Triggered when the user wants to assess whether an implementation is ready to merge.
---

# Verify Skill

You are performing a two-tier review of an implementation:
1. **Functional QA:** Do the build, lint, and acceptance tests pass?
2. **Architectural Result Audit (with `pro` Auditor):** Did the implementation introduce silent bloat, boundary leaks, or technical debt?

## Inputs

The user will provide:
- A **PR number** or a description of the changes/branch to verify.
- The **spec** or **GitHub Issue** to check against (or you'll find it from the PR).

---

## Step 1: Get the Spec & Changes

1. Run `gh pr view <number>` to find the linked Issue.
2. Run `gh issue view <number>` to get the spec and acceptance criteria.
3. Run `gh pr diff <number>` (or `git diff`) to inspect all changed files.

---

## Step 2: Functional Verification

Work through the mechanical and functional checks:
```bash
# Build check
go build ./...

# Lint check
go vet ./...

# Infrastructure verification (if applicable)
./scripts/verify-infrastructure.sh
```
Confirm each acceptance criterion from the spec passes.

---

## Step 3: Scope Check

Verify the PR didn't touch files it shouldn't have:
- Read "Files NOT to Touch" from the Issue.
- Flag any out-of-scope edits.

---

## Step 4: Architectural Result Audit (`Model: pro`)

Spawn an Auditor subagent using `Model: pro` to inspect the full diff against [`docs/TECH_STACK_DECISION.md`](file:///home/khemi/workspace/ai_sandbox/docs/TECH_STACK_DECISION.md):

- **Role:** `Principal Systems Integrator & Result Auditor`
- **Model:** `pro`
- **Audit Focus:**
  1. **Boundary Integrity:** Did the code cross the 3-tier boundary? *(e.g. Workload pod directly contacting internal database, portal attempting to proxy raw vLLM streaming responses).*
  2. **Hidden Bloat & Runtime Hacks:** Did the PR introduce runtime `pip install`, dynamic image builds, unapproved external libraries, or redundant sidecars?
  3. **Architectural Drift:** Does the code take short-term shortcuts that contradict our foundational stack decisions?

Capture the Auditor's verdict:
- 🟢 **CLEAN:** Adheres strictly to system architecture and boundaries.
- 🟡 **WARNING:** Works functionally, but introduces minor architectural debt to address.
- 🔴 **BLOCKING VIOLATION:** Violates core boundaries (security leak, unapproved service coupling, or severe bloat).

---

## Step 5: Log Check

- Confirm [`INCREMENT_LOG.md`](file:///home/khemi/workspace/ai_sandbox/docs/INCREMENT_LOG.md) has a new entry at the top following the standard format.

---

## Output Format

Present your verification to the user in this structure:

```markdown
## 🔍 Verification & Audit: PR #[number] — [PR title]

**Spec:** Issue #[number]  
**Functional Verdict:** PASS / NEEDS REVISION  
**Architectural Verdict:** 🟢 CLEAN / 🟡 DEBT WARNING / 🔴 BLOCKING VIOLATION

### 1. Functional QA Check
| Criterion | Status | Notes |
| :--- | :---: | :--- |
| Build passes (`go build ./...`) | ✅ / ❌ | |
| Lint clean (`go vet ./...`) | ✅ / ❌ | |
| [Functional criteria from spec] | ✅ / ❌ | |
| No out-of-scope file edits | ✅ / ❌ | [list violations] |
| INCREMENT_LOG.md updated | ✅ / ❌ | |

### 2. Architectural Result Audit (pro Model Review)
- **Boundary Integrity:** [Clean / Details on boundary leak]
- **Bloat & Dependency Check:** [Zero new bloat / Flagged runtime dependencies]
- **Stack Alignment:** [Matches TECH_STACK_DECISION.md / Notes on shortcuts]

### 3. Issues & Required Actions
[List any functional bugs or architectural changes required before merge. If clean: "None — ready to merge."]
```

## Constraints
- **Brief and Straight to the Point:** High-signal bullet points. Avoid essay filler.
- Do not merge PRs — that is always the user's call.
- Do not request changes for personal style preferences — only spec failures and architectural boundary violations.
