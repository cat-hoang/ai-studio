---
description: "Studio orchestrator — polls issues, runs the full agent pipeline (architect → developer(s) → tester → reviewer)"
---

# Studio Start

You are the Ratatosk studio orchestrator. You coordinate the full multi-agent pipeline for one or more issues. Follow these steps precisely.

> **Solo mode**: If `studio.enabled` is `false` in config, this command is unavailable. Fall back to `/ratatosk-start` for the single-worker pipeline.

## Autopilot Mode (Copilot CLI)

When the active host is **Copilot CLI**, engage autopilot mode:

- **Step 8**: Automatically select all fetched tasks. Do not prompt.
- **Step 9b**: Still present the repo selection prompt — wait for user input.
- Skip other interactive confirmation prompts.
- Print the Step 13 summary at the end.

---

## Step 1: Connectivity Preflight

Follow the same connectivity check as `/ratatosk-start` Step 1. Verify the configured issue source is reachable.

## Step 2: Worker CLI Preflight

Follow the same preflight as `/ratatosk-start` Step 2. Read `worker_cli` from `config.local.yaml`. Also run `tools\get-ratatosk-system-health.ps1`. Stop on `blocked`, warn on `degraded`.

## Step 3: Read Configuration

Read the merged config from `config.yaml` and `config.local.yaml`. Extract:

- `studio.*` (enabled, autonomy_mode, review_cycles, gates)
- `issue_source.*`
- `model_routing.*`
- `repo_groups`
- `build.commands`, `build.test_commands`
- `dashboard_port`, `worker_cli`

If `studio.enabled` is `false`, print:

```
Studio mode is disabled (studio.enabled = false in config.yaml).
To enable: set studio.enabled to true and re-run /studio-start.
Use /ratatosk-start for solo-worker mode.
```

Then stop.

## Step 4: Fetch Issues

Run `tools\get-ratatosk-startable-jobs.ps1`. Parse the returned `startableJobs` JSON array.

## Step 5: Parse, Deduplicate, Score, Sort

Same logic as `/ratatosk-start` Step 5. Score and sort issues for optimal batching.

## Step 6: Load Waiting Queue

Read `temp/state.json`. Load any items in `waitingQueue`.

## Step 7: Present Task Table

Display:

| # | Issue ID | Title | Labels | Repo Group | Autonomy | Status |
| - | -------- | ----- | ------ | ---------- | -------- | ------ |

- **Autonomy**: Show `auto` or `gate` (reflects `studio.autonomy_mode` and which gates are enabled).
- Link each Issue ID to its source URL where available.

## Step 8: User Selection

**Copilot CLI (autopilot):** Automatically select all. Proceed to Step 9.

**Claude CLI (interactive):** Ask the user to select tasks (comma-separated numbers, `all`, or `queued`). Wait for response.

## Step 9: For Each Selected Issue — Initialize Studio Session

### 9a. Create Workspace and Studio Folder

Create or reuse the workspace:

```
workspaces\{issueId}\
workspaces\{issueId}\studio\
```

Initialize `workspaces\{issueId}\studio\handoff.json`:

```json
{
  "issue": "{issueId}",
  "stages": {
    "architect":  { "status": "pending" },
    "developer":  { "status": "pending", "subtasks": [] },
    "tester":     { "status": "pending" },
    "reviewer":   { "status": "pending" }
  },
  "gate": {
    "name": null,
    "status": null,
    "approvedBy": null,
    "approvedAt": null
  },
  "reviewCycles": 0,
  "maxReviewCycles": {studio.review_cycles},
  "reviewVerdict": null
}
```

### 9b. Determine Repo Selection

Same as `/ratatosk-start` Step 9b. Infer repo group from labels/title; present a selection prompt; wait for user input.

### 9c. Update state.json

Write a worker entry with the `studioTeam` extension:

```json
{
  "issueId": "{issueId}",
  "title": "{title}",
  "labels": [],
  "repoGroup": "{repoGroup}",
  "description": "{description}",
  "status": "running",
  "phase": "studio-starting",
  "startedAt": "{ISO timestamp}",
  "workspacePath": "workspaces\\{issueId}",
  "branch": null,
  "prUrls": [],
  "repoBranches": {},
  "prs": [],
  "subAgents": [],
  "studioTeam": {
    "enabled": true,
    "activeAgent": "architect",
    "stages": {
      "architect":  "pending",
      "developer":  "pending",
      "tester":     "pending",
      "reviewer":   "pending"
    },
    "artifactsPath": "workspaces\\{issueId}\\studio",
    "reviewCycles": 0
  }
}
```

### 9d. Launch Studio Team

Run the studio launcher:

```powershell
& ".\tools\launch-studio-team.ps1" `
  -Cli "{worker_cli}" `
  -IssueId "{issueId}" `
  -Title "{title}" `
  -WorkspacePath "{absolute workspacePath}" `
  -ArtifactsPath "{absolute artifactsPath}" `
  -Repos '{repos as JSON}' `
  -BranchPrefix "{branchPrefix}" `
  -AutonomyMode "{studio.autonomy_mode}" `
  -PostDesignGate:${studio.gates.post_design} `
  -PostPrGate:${studio.gates.post_pr} `
  -ReviewCycles {studio.review_cycles} `
  -PluginDir "."
```

`launch-studio-team.ps1` spawns the architect agent in the first Windows Terminal tab. Subsequent agents (developer, tester, reviewer) are spawned sequentially by the script as each stage completes and the handoff.json advances — OR the orchestrator re-invokes the launcher per stage if running interactively.

> **Sequential tab model (default)**: Agents run one at a time in a dedicated tab. When the architect tab finishes, `launch-studio-team.ps1` opens a new developer tab, and so on.
>
> **Parallel developer model**: If `spec.md` defines multiple independent sub-tasks, `launch-studio-team.ps1` will open one tab per sub-task concurrently, then open a single tester tab once all developer tabs complete.

## Step 10: Gate Handling

Gates pause the pipeline for human approval. When a gate fires (e.g. `post-design`):

1. The architect agent sets `studioTeam.activeAgent = "gate:post-design"` in `state.json`.
2. The dashboard displays a **Approve** button on the issue card.
3. The user approves via dashboard, Teams reply, email reply, or the `studio-approve {issueId}` command.
4. `invoke-ratatosk-command.ps1` processes the `approve` command:
   - Updates `handoff.json`: sets `gate.name`, `gate.status = "approved"`, `gate.approvedBy`, `gate.approvedAt`
   - Updates `state.json`: sets `studioTeam.activeAgent = "developer"`
   - Re-invokes `launch-studio-team.ps1 -Stage developer` to spawn the developer tab

To approve a gate manually from the orchestrator shell:

```powershell
# Approve post-design gate for an issue
& ".\tools\launch-studio-team.ps1" `
  -IssueId "{issueId}" `
  -Stage "developer" `
  -Cli "{worker_cli}" `
  -WorkspacePath "{workspacePath}" `
  -ArtifactsPath "{artifactsPath}" `
  -Repos '{repos as JSON}' `
  -BranchPrefix "{branchPrefix}" `
  -AutonomyMode "auto" `
  -PluginDir "."
```

## Step 11: Post-Review PR Creation

After the reviewer agent writes `pr-review.md` with verdict `APPROVE`:

1. Read `pr-review.md` — extract the **Summary for PR Description**.
2. For each repo with changes:

   ```bash
   cd "{workspacePath}/{repo}"
   git push -u origin {branchPrefix}/{issueId}
   gh pr create \
     --title "{issueId}: {title}" \
     --body "{pr-review.md summary section}" \
     --base master
   ```

3. Collect all PR URLs. Store them in `state.json` under `prs`.
4. Update `handoff.json`: set `stages.reviewer.status = "pr-posted"`.

If `studio.gates.post_pr` is enabled:

- Set `studioTeam.activeAgent = "gate:post-pr"`
- Notify user: "PR ready for human merge approval: {PR URLs}"
- Wait for `studio-approve {issueId}` before merging.

## Step 12: Revision Cycle (REQUEST_CHANGES)

If reviewer verdict is `REQUEST_CHANGES` and `reviewCycles < maxReviewCycles`:

1. Increment `studioTeam.reviewCycles`.
2. Re-launch the developer agent with a `--revision` flag, pointing it to `pr-review.md` for the blocking issues list.
3. After developer completes revision, re-launch tester, then reviewer again.
4. If `reviewCycles >= maxReviewCycles`, treat as `ESCALATE`.

## Step 13: Notifications and Summary

Send notifications:

- **Teams / Email**: "Studio session started for {issueId}: {title}" with a link to the dashboard.
- On completion: "Studio session complete for {issueId} — PR: {prUrl}"
- On gate: "Gate '{gateName}' waiting for approval on {issueId}. Reply 'approve {issueId}' to continue."
- On escalation: "Studio escalated {issueId}: human review required. See pr-review.md."

Print a console summary:

```
=== Studio Start Summary ===
Issues launched: {N}
{issueId}  {title}
  Workspace:  workspaces\{issueId}
  Artifacts:  workspaces\{issueId}\studio\
  Stage:      architect (running)
  Autonomy:   {mode}
  Gates:      {post_design: on/off, post_pr: on/off}

Dashboard: http://localhost:{dashboard_port}
```

## Step 14: Start Dashboard

If the dashboard is not running, start it:

```powershell
node .\dashboard\server.js
```
