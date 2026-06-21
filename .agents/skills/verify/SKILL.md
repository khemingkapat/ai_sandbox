---
name: verify
description: >
  Checks a PR or set of changes against a specification and acceptance criteria.
  Triggered by the user when they want to assess whether a Jules PR is ready to merge.
---

# Verify Skill

You are performing a **structured QA check**. Your job is to give the user a clear, honest verdict on whether the implementation meets the spec.

## Inputs

The user will give you:
- A **PR number** or a description of the changes to verify
- The **spec** or **GitHub Issue** to check against (or you'll find it from the PR)

## Step 1: Get the Spec

If not provided directly:
1. Run `gh pr view <number>` to find the linked Issue
2. Run `gh issue view <number>` to get the spec and acceptance criteria

## Step 2: Check Each Criterion

Work through the acceptance criteria one by one:

```bash
# Build check
go build ./...

# Lint check
go vet ./...

# Infrastructure verification (if applicable)
./scripts/verify-infrastructure.sh
```

For each functional criterion, read the relevant code and confirm it does what the spec says.

## Step 3: Scope Check

Verify the PR didn't touch files it shouldn't have:
- Read "Files NOT to Touch" from the Issue
- Run `gh pr diff <number>` or check the changed files list
- Flag any out-of-scope edits

## Step 4: Log Check

- Confirm `INCREMENT_LOG.md` has a new entry at the top
- Entry should follow the existing format in the file

## Output Format

```markdown
## QA Check: PR #[number] — [PR title]

**Spec:** Issue #[number]

| Criterion | Status | Notes |
|---|---|---|
| Build passes (`go build ./...`) | ✅ / ❌ | |
| Lint clean (`go vet ./...`) | ✅ / ❌ | |
| [Functional criterion from spec] | ✅ / ❌ | |
| [Functional criterion from spec] | ✅ / ❌ | |
| No out-of-scope file edits | ✅ / ❌ | [list any violations] |
| INCREMENT_LOG.md updated | ✅ / ❌ | |

**Verdict:** PASS / NEEDS REVISION

### Issues Found
[If NEEDS REVISION: list each problem with enough detail for the implementer to fix it]
[If PASS: "None — ready to merge."]

### Architecture Notes
[Optional: anything worth flagging for the user's architecture awareness, even if not a blocker]
```

## What You Do NOT Do

- Do not merge PRs — that's always the user's call
- Do not make architecture decisions
- Do not request changes for style preferences — only spec violations and objective failures
- Do not block low-risk, clearly-correct changes with excessive process
