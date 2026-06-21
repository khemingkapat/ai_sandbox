---
name: track
description: >
  Reads the current project state dynamically from GitHub Projects and Issues,
  and gives a concise status briefing.
---

# Track Skill

You are running a **project status check**. Your job is to read the current state of the GitHub Project board and open PRs, and give the user a clear, honest picture — not a wall of text.

## Step 1: Read Workspace Configuration
Read `.agents/config.json` in the workspace root to retrieve the project details:
- Project Number: `github.project_number`
- Repository Owner: `github.owner`

## Step 2: What to Read

Run these queries in order:

```bash
# 1. Open PRs
gh pr list --state open

# 2. Issues in the project board
gh project item-list <project_number> --owner <owner> --format json
```

Also read the last few entries of `INCREMENT_LOG.md` (to see what was recently completed).

## Step 3: Parse and Compile Status
Process the project items JSON from `gh project item-list`. Extract:
- Backlog items (e.g. status "Todo" or "Backlog")
- In Progress items (e.g. status "In Progress" or issues containing the `jules` label)
- Done items (status "Done")

## Output Format

Keep it brief. The user wants to get oriented in under 30 seconds.

```markdown
## Project Status — [date]

### Recently Completed
- [WP#-N] Task title — merged [date] (or "nothing since last session")

### In Flight
- PR #[number]: [title] — [status: open / waiting for review]
- Issue #[number]: [title] — Jules working on this

### Project Board Status
| WP | Name | Status |
|---|---|---|
| WP1 | [name] | ✅ Done |
| WP2 | [name] | 🔄 In Progress |
| WP3 | [name] | ⬜ Todo |
```

## Key Status Mapping
- ✅ Done (completed issues/PRs)
- 🔄 In Progress (issues with `jules` label or in "In Progress" column)
- ⬜ Todo / Backlog (issues without `jules` label or in "Todo" column)

## What You Do NOT Do
- Do not read or rely on `WORK_PACKAGES.md` — GitHub Project is the source of truth.
- Do not make decisions — you present state, the user decides what to work on next.
- Do not update any state files.
