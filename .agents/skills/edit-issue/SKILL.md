---
name: edit-issue
description: >
  Finds a preloaded work package issue, handles optional sub-issue breakdown, updates the description
  with the concrete implementation specification, and adds the 'jules' label to trigger the Jules workflow.
---

# Edit Issue Skill

You are preparing a **Jules handoff Issue** by updating an existing backlog issue or breaking it down into sub-issues. Your job is to take a spec (from `design-spec` or provided by the user), check if it should be split into smaller sub-tasks, create and link sub-issues if needed, and apply the `jules` label to activate the workflow on the targeted task.

## Inputs

The user will give you:
- A **spec** (output of `design-spec`, or a description of the task)
- The **work package ID** (e.g., WP6 or WP3-1-1)

---

## Step 1: Find the Existing Issue
Search for the preloaded issue matching the work package ID:
```bash
gh issue list --search "[WP-ID]" --state open --limit 1
```
Note the parent issue number.

---

## Step 2: Determine if Sub-Issues are Needed
Review the spec against the parent issue:
* **Single Task:** If the spec describes one focused implementation task, proceed directly to **Step 4** (Drafting/Updating the issue).
* **Multi-Task:** If the spec contains multiple independent components (e.g., setting up a layout and writing a separate test suite, or modifying portal code and adding configuration), ask the user if they want to break it down into sub-issues.

---

## Step 3: Create Sub-Issues (If Requested)
If the user wants to split the task:
1. Define the sub-task IDs and titles (e.g., `[WP3-1-7-1] Create storage layout script` and `[WP3-1-7-2] Create isolation verification tests`).
2. Create each sub-issue on GitHub, linking it to the project board. Do **NOT** add the `jules` label:
   ```bash
   gh issue create \
     --project "AI Sandbox" \
     --title "[WP-ID-Sub] Sub-task Title" \
     --body "Sub-task details. Parent Issue: #<parent-number>"
   ```
3. Update the Parent Issue's description to list the sub-issues and their links for tracking.
4. Ask the user which sub-issue they want to trigger Jules on first, then proceed to **Step 4** targeting that sub-issue.

---

## Step 4: Draft the Issue Update
**Always** read `references/jules_handoff_template.md` before writing the issue body.
1. Fill in the template using the spec as input for the target issue (either the parent issue or the selected sub-issue).
2. Title format: `[WP-ID] Verb What` (e.g., `[WP3-1-7-1] Create storage layout script`).
3. Acceptance criteria must be objectively testable (e.g., shell script exits 0, creates directory X).

---

## Step 5: Show Draft to User
Present the full updated issue body as a markdown block. Ask: **"Ready to update this issue and trigger Jules?"**
Do **not** execute the update until the user confirms.

---

## Step 6: Update the Issue & Trigger Jules
On user approval, edit the issue to update its body and apply the `jules` label:
```bash
# Save the body draft to a temporary file, then update:
gh issue edit <issue-number> \
  --body-file /path/to/draft.md \
  --add-label "jules"
```

Confirm the update by reporting its number, URL, and the fact that Jules has been triggered.
