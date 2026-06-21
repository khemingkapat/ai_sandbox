---
name: populate-project
description: >
  Reads .agents/config.json and the local WORK_PACKAGES.md file, then bulk-creates issues
  on the target GitHub Project board without the 'jules' label.
---

# Populate Project Skill

You are running a **bulk issue population script**. Your job is to read the local `WORK_PACKAGES.md` and populate the GitHub Project board with issues representing each work package.

## Step 1: Read Workspace Configuration
Read `.agents/config.json` in the workspace root to retrieve the project details:
- Project Number: `github.project_number`
- Repository Owner: `github.owner`

## Step 2: Parse WORK_PACKAGES.md
Parse the local `WORK_PACKAGES.md` file to extract:
1. The list of work packages (e.g., `WP1`, `WP3-1-1`).
2. The title of each work package.
3. The description and checklist items for each work package.

## Step 3: Create GitHub Issues (Without Jules Label)
For each work package parsed:
1. Construct the issue title using the convention: `[WP-ID] Title` (e.g. `[WP3-1-1] Environment Assessment & Requirements`).
2. Construct the issue body containing the description and deliverables.
3. Create the issue on GitHub and link it to the project board using the `gh` CLI:
   ```bash
   gh issue create \
     --project "<project_number>" \
     --title "[WP-ID] Title" \
     --body "<issue body>"
   ```
   *Note: Do NOT include `--label "jules"` in this step to keep the issue inactive in the backlog.*

## Step 4: Summarize Output
After all issues are created, print a summary table of the created issues with their numbers, titles, and URLs.
