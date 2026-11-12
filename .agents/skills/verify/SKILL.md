---
name: verify
description: >
  Empirical verification and architectural acceptance audit for Gate D.
  Audits the finished implementation against the unit spec, checks locked test integrity,
  verifies live cluster receipts, flags out-of-scope diffs, and checks cluster invariants.
---

# Verify Skill (Gate D Acceptance)

You are performing an empirical verification audit of a completed unit bolt before final acceptance at **Gate D**.

Your goal is to eliminate the **Rework Tax** caused by LLM overconfidence or unverified claims. You must provide concrete empirical proof, not verbal assertions.

---

## Step 1: Scope & Test Integrity Verification

1. **Verify Locked Test Hashes:**
   Check the SHA-256 checksums in `.aidlc/gate_c_<unit>.manifest`. Confirm that zero Gate C test files or verification scripts were tampered with during implementation.
2. **Scope Diff Check:**
   Compare the touched files in `git status --porcelain` against the approved **"Files Allowed to Touch"** list from `docs/aidlc/units/<unit>.md`.
   Flag any out-of-scope edits immediately.

---

## Step 2: Empirical Proof-of-Work (Test Receipts)

Do not claim tests pass without pointing to an empirical execution receipt:
1. Fast local checks: `go test -v ./...`, `go vet ./...`, `bash -n`.
2. Live cluster probe execution logs: Check the execution log at `.aidlc/runs/<unit>-*.log` (or run `./scripts/verify-<unit>.sh` under flock).
3. **Negative Proof Check:** Confirm that at least one negative or boundary rejection case (e.g. invalid auth token returns 401, duplicate submission handled idempotently) was executed and succeeded.

---

## Step 3: Cluster Invariant Sanity Probe

Verify that the bolt did not degrade surrounding cluster components:
1. **L40 GPU Health:** vLLM pod in `services` namespace is healthy and responsive (no CUDA OOM).
2. **Slurm Nodes:** Slurm compute nodes are in `idle` or `alloc` (no nodes stuck in `drain` or `down`).
3. **K8s Workloads:** No pods in `CrashLoopBackOff`.

---

## Step 4: The Consumable "Before & After" Report

Present your Gate D audit findings to Khem in this human-readable format:

```markdown
## 🏁 Empirical Gate D Verification: [Unit Name]

### 1. Consumable "Before & After" Summary
- **Before:** [What the system did or lacked prior to this bolt]
- **After:** [What physically happens now in plain English]
- **Exact Code Footprint:** [X files changed, +Y insertions, -Z deletions]

### 2. Empirical Verification Receipts
- **Locked Tests Untampered:** ✅ SHA-256 verified against `.aidlc/gate_c_<unit>.manifest`
- **Scope Integrity:** ✅ Only approved files touched (0 out-of-scope edits)
- **Local Unit Tests:** ✅ `go test` passed (receipt attached)
- **Cluster Hardware Probe:** ✅ `scripts/verify-<unit>.sh` passed on live Slurm/k8s (Log: `.aidlc/runs/<unit>-<timestamp>.log`)
- **Negative Proof Verified:** ✅ Rejection of invalid inputs confirmed

### 3. Cluster Invariant State
- **NVIDIA L40 GPU:** 🟢 Healthy (vLLM running, VRAM nominal)
- **Slurm Nodes:** 🟢 All nodes operational (no drains)

### 4. Architectural Debt Check
- Any runtime hacks, temporary debug flags, or unapproved dependencies? (Report None or list items).
```

---

## Step 5: Trigger Gate D Checkpoint

Trigger the **Gate D Checkpoint** (via the `checkpoint_gate` tool in Pi, or standard approval in Antigravity).
Offer options to inspect the full Git diff or raw test receipts in `$EDITOR` (`nvim`) before final approval.
Once approved, update the Bolt Log in `docs/aidlc/units/<unit>.md` and flip the status to `DONE` in `UNITS.md`.
