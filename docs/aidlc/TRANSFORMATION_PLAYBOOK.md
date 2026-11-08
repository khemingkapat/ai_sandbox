# Transformation & Legacy Remediation Playbook (Temporary)

> **Lifecycle Notice:** This document holds the **temporary transformation context** bridging our pre-AI-DLC repository state (frozen at git tag `pre-aidlc`) to our present AI-DLC workflow. Once legacy components are hardened and historical spec drafts are migrated into active units, **delete this file (`git rm docs/aidlc/TRANSFORMATION_PLAYBOOK.md`)**.

---

## 1. Why This Playbook Exists (Diagnosis of Pre-AI-DLC Work)

Work completed prior to the `pre-aidlc` tag (`WP01`–`WP11`, early `WP12`, and `WP17`) was developed under an earlier, loosely structured workflow that suffered from three recurring failure modes:

1. **Goal-Only Starts & "False Affirmation" Tests:** Features were often built directly from high-level goals without locked edge-case specifications, and verified with narrow happy-path tests that passed even when cluster integration boundaries were incomplete.
2. **The 50% Rework Tax:** Because shallow tests gave false confidence, defects in "completed" work surfaced only when the next feature tried to integrate with them—consuming half of each new sprint fixing old work.
3. **Documentation Drift:** Context was previously scattered across 42 markdown files (~724 KB, including `INCREMENT_LOG.md` and `WORK_PACKAGES.md`), causing silent drift between what the docs claimed and what the code actually did.

---

## 2. Legacy Remediation Protocol (How to Fix Broken Past Work)

When working on a new unit and discovering that a pre-AI-DLC component (`WP01`–`WP12`) is broken, incomplete, or suffering from a "false affirmation" test gap:

1. **Do NOT silently patch it inside an unrelated feature bolt.** Mixing legacy rework into a new feature bolt recreates the 50% rework loop and blurs scope.
2. **Pause and Isolate:** If the legacy bug blocks the current bolt, trigger the escalation rule in [`WORKING_AGREEMENT.md`](file:///home/khemi/workspace/ai_sandbox/docs/aidlc/WORKING_AGREEMENT.md) and propose a dedicated **Remediation Bolt** (`docs/aidlc/units/remediate-<component>.md`).
3. **Expose the False Affirmation at Gate C First:** Before fixing the legacy code or manifest, write the missing boundary/integration test in `portal/` or `scripts/verify-*.sh` that proves the failure deterministically. Lock that test at Gate C, then fix the implementation.

---

## 3. Historical Spec & Research Lookup (`pre-aidlc` Git Tag)

Prior to adopting AI-DLC, several upcoming capabilities already had researched specifications or design notes committed in the old `docs/` directory. Do not re-research them from scratch; pull them from the `pre-aidlc` tag during **Phase 1 (Inception)** when their unit begins:

| Target Unit | Historical File in `pre-aidlc` Tag | Retrieval Command | What to Extract |
| :--- | :--- | :--- | :--- |
| **WP13 (Slurm Telemetry)** | `docs/slurm_info_exchange_research.md` | `git show pre-aidlc:docs/slurm_info_exchange_research.md` | **Section 8:** Audited spec for Slurm epilog webhook (`scripts/slurm_epilog_webhook.sh`) + Portal in-memory ring buffer (`portal/telemetry.go`). |
| **WP14 (Qdrant & Starter Labs)** | `docs/WP3-1-14_STARTER_LABS_AND_VECTOR_DB.md` | `git show pre-aidlc:docs/WP3-1-14_STARTER_LABS_AND_VECTOR_DB.md` | Complete spec for Qdrant StatefulSet (`services` namespace), CNI egress policy, client image SDKs, and 5 starter `.ipynb` labs. |
| **WP12 (Portal Enhancements)** | `docs/WORK_PACKAGES.md` & `docs/INFERENCE_AUTHENTICATION_AND_QOS.md` | `git show pre-aidlc:docs/WORK_PACKAGES.md` | Remaining portal UI items (model picker/chat UI, GPU job submission UI) vs. already-implemented `portal/session_manager.go`. |
| **WP15 / WP16 (Guides & Runbooks)** | `docs/ONBOARDING_GUIDE.md` & `docs/BACKEND_VERIFICATION_RUNBOOK.md` | `git show pre-aidlc:docs/ONBOARDING_GUIDE.md` | Reusable command snippets and troubleshooting procedures for student and sysadmin guides. |

---

## 4. Exit Criteria (When to Delete This File)

Remove `TRANSFORMATION_PLAYBOOK.md` once:
- [ ] `WP13` and `WP14` historical specs have been converted into live units in `docs/aidlc/units/` and completed.
- [ ] `WP12` portal state has been reconciled and verified under Gate C/D tests.
- [ ] Any false-affirmation gaps uncovered in `WP01`–`WP11` during Milestone 4 integration have been remediated with locked tests.
