---
description: "Start Ratatosk task orchestrator - fetch tasks, pick, spawn workers"
---

# Ratatosk Start

You are the Ratatosk orchestrator. Follow these steps precisely to fetch tasks, let the user pick, and spawn workers.

## Autopilot Mode (Copilot CLI)

When the active host is **Copilot CLI**, engage autopilot mode immediately and run all steps autonomously without asking for user input:

- **Step 8**: Automatically select all fetched tasks (treat as `all`). If the waiting queue has items, also include them. Do not prompt the user.
- **Step 9b**: Still present the repo selection prompt — wait for the user to choose which repos to clone before proceeding. This avoids polluting workspaces with unrelated repos.
- Skip all other interactive confirmation prompts and proceed through every step end-to-end.
- At the end, print the Step 12 summary so the user can review what was launched.

## Step 1: VPN Preflight

Run the vpn-preflight skill to verify connectivity:

- Resolve `crikey.wtg.zone` via DNS
- Perform an HTTPS connectivity check against it
- If preflight fails, stop and report the issue. Do not proceed without VPN.

## Step 2: Worker CLI Preflight

Read `config.local.yaml` to determine `worker_cli`. If the key is absent, default to `claude`.

Also run `tools\get-ratatosk-system-health.ps1` and inspect the returned readiness snapshot before launching any workers. If it returns `blocked`, stop and show the blocking reasons. If it returns `degraded`, continue only after surfacing the warnings clearly to the user.

- **If `worker_cli` is `auto`**:
  - If the active host is Copilot, resolve worker CLI to `copilot`.
  - If the active host is Claude, resolve worker CLI to `claude`.
  - If the host is ambiguous, prefer `claude` for backward compatibility.

- **If `worker_cli` is `claude`**:
  - Run `gh auth token` and read `~/.claude/settings.json`.
  - Compare the current `GITHUB_PERSONAL_ACCESS_TOKEN` value in `env` with the output of `gh auth token`.
  - If they differ, update `~/.claude/settings.json` with the fresh token.

- **If `worker_cli` is `copilot`**:
  - Run `copilot --version` to verify the CLI is installed.
  - Do **not** edit `~/.claude/settings.json` in this mode.
  - If Copilot is not authenticated when it launches, stop and tell the user to run `copilot login`.

## Step 3: Read Configuration

Read the merged configuration from two files:

- `config.yaml` (base config)
- `config.local.yaml` (local overrides, merged on top)

Extract key values: `buffer_board_url`, `staff_code`, `product_repo_mapping`, `dashboard_port`, `worker_cli`, notification settings, and any other relevant fields.

## Step 4: Fetch Tasks (in parallel)

Fetch tasks from two sources simultaneously:

a. **Buffer Board**: Use WebFetch to retrieve the buffer board URL from config (`buffer_board_url`). Parse the response to extract task entries.

b. **EDI Prod Staff Tickets**: Run `tools\get-ratatosk-startable-jobs.ps1` with the `boardName` and `staffCode` from config. This script queries the PAVE buffer board API and falls back to `edi workitem list` when the board is unavailable. Parse the returned startable jobs JSON.

## Step 5: Parse, Merge, Deduplicate, Score, Sort

- Parse both result sets into a unified task format with fields: jobNumber, taskSequence, taskType, zone, description, source (buffer-board or ediprod).
- Preserve the actual workflow task sequence number from the source system whenever it is available.
- Deduplicate by job number. If the same job appears in both sources, prefer the buffer board entry but note both sources.
- For each task, derive lightweight batching hints before presenting it:
  - probable repo group / repo family from task text, task type, and any known repo metadata
  - expected workspace cost (for example reuse existing workspace, light clone, heavy clone)
  - likely completion value (for example zone priority, retries, existing PRs, manual queue bias)
  - overlap bonus when multiple candidate tasks appear to share the same repo group
- Compute a launch score from those hints and sort by launch score first, then zone / sequence as a tiebreaker.

## Step 5a: Refresh ediProd Startable Cache

After merging and normalising in Step 5, write the ediProd-sourced entries to the shared poller cache so the dashboard can reuse them without making a separate `edi` CLI call:

```
artifacts-cache/ediprod-startable-cache.json
```

Format (must match what the startable poller reads):

```json
{
  "fetchedAt": "<ISO timestamp>",
  "startableJobs": [ ...normalised ediProd entries... ]
}
```

Only include entries whose `source` is `ediprod`. Skip buffer-board entries. Create `artifacts-cache/` if it does not exist. This is a best-effort write — if it fails, log a warning and continue.

## Step 6: Load Waiting Queue

Read `temp/state.json`. If it exists, load any items in the `waitingQueue` array. These are tasks previously queued via `/ratatosk-queue`.

## Step 7: Present Task Table

Display a formatted table to the user with these columns:

| # | Job Number | Task Seq | Task Type | Zone | Description | Source | Batch Hint | Status |
| - | ---------- | -------- | --------- | ---- | ----------- | ------ | ---------- | ------ |

- Number each row sequentially starting from 1.
- For items that are already in the waiting queue, show "(queued)" in the Status column.
- For items from the fresh fetch, leave Status blank.
- In **Batch Hint**, show a short summary such as repo group, workspace cost, overlap count, and launch score so the operator can quickly pick adjacent work that amortizes workspace setup.
- When you can resolve the job GUID from ediProd details (for example from `ediprod:///IWorkItem/{guid}/...`, `ediprod:///IIncidentRequest/{guid}/...`, or `ediprod:///IWorkProject/{guid}/...` attached-document URLs), prefer the HTTPS Session Broker link format:
   `https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/WorkItem/{guid}?lang=en-gb`
   `https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/SupportIncident/{guid}?lang=en-gb`
   `https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/Project/{guid}?lang=en-gb`
- If the GUID is not yet known, show plain text rather than an `edient:` link.

## Step 8: User Selection

**Copilot CLI (autopilot):** Automatically select all tasks in the table. Skip this prompt entirely and proceed to Step 9.

**Claude CLI (interactive):** Ask the user to select tasks. Accepted inputs:

- Comma-separated numbers (e.g., `1,3,5`)
- `all` to select every task in the table
- `queued` to select only the items already in the waiting queue

Wait for the user's response before proceeding.

## Step 9: Spawn Workers

For each selected task, perform the following:

### 9a. Create/Reuse Workspace

Use the workspace-manager skill to create or reuse a workspace directory under `.\workspaces\`. The workspace name should incorporate the job number.

If the job already has one or more PR links recorded in state, inspect those PRs first and reuse their remote head branches per repo instead of creating a fresh local <staff_code> branch.

### 9b. Determine Product and Repo Selection

Determine the narrowest repo set that is safe to launch:

- First prefer any repo metadata already recorded on the queued task (for example `repoGroup` / `repos`).
- Otherwise infer the most likely product repo group from `config.product_repo_mapping` using the task type, summary, and description.
- Fall back to `default_repos` only when no repo-group match is strong enough.

**Present a repo selection prompt before proceeding (both Copilot and Claude CLI).** Show the inferred repo list and offer these options:

```
Repos inferred for {jobNumber}:
  1. {repo1}
  2. {repo2}
  ...

Clone options:
  A  – Clone all inferred repos above  [default]
  N  – Skip cloning — work read-only against existing source paths
  1,2,... – Clone only selected repos (comma-separated numbers)
```

Wait for the user's response. Interpret the input as follows:

- **`A` or blank / Enter**: clone all inferred repos (standard `clone` mode)
- **`N`**: set `workspaceMode = reference`; no repos will be cloned; the worker will read source files from `git_source_root` paths in `.ratatosk/repo-paths.json`
- **Comma-separated numbers** (e.g. `1,3`): clone only the listed repos; remaining inferred repos are excluded; mode stays `clone`

Record the resolved repo list, repo group, and `workspaceMode` in state so later retries and dashboard actions can reuse the same decision.

### 9c. Prime CargoWise Bin (if needed)

If the product includes CargoWise, run the crikey-build-artifacts skill to prime the `Bin/` directory in the workspace.

That skill must reuse the shared artifact cache from the merged `artifacts_cache` config setting, resolved relative to the Ratatosk repo root. Do not download Crikey zips into a workspace-local `.ratatosk\artifacts` folder.

### 9d. Update State

Write a worker entry to `temp/state.json` under the `workers` array:

```json
{
  "jobNumber": "{jobNumber}",
  "taskSequence": "{taskSequence}",
  "taskType": "{taskType}",
  "zone": "{zone}",
  "description": "{description}",
  "status": "running",
  "phase": "starting",
  "startedAt": "{ISO timestamp}",
  "workspacePath": "workspaces\\{jobNumber}",
  "branch": null,
  "prUrls": [],
  "repoBranches": {},
  "prs": [],
  "subAgents": []
}
```

Store Ratatosk-managed paths in `temp/state.json` relative to the repository root (for example `workspaces\WI00992034`). Use the fully resolved `workspacePath` variable only when launching tools that require a filesystem path.

### 9e. Write Prompt File and Spawn Windows Terminal Tab

First, write a prompt file to the workspace:

```path
{workspacePath}/.ratatosk-prompt.md
```

With contents:

```markdown
You are Ratatosk Task Worker for {jobNumber} ({taskType}).
Read your full instructions from `..\..\agents\task-worker.md`.
Your workspace is {workspacePath}.
Your job number is {jobNumber}, task sequence is {taskSequence}, task type is {taskType}, zone is {zone}.
workspaceMode: {workspaceMode}
repos: {repos as JSON array — e.g. [{"name":"Glow","path":"{workspacePath}\\Glow","remoteName":"origin"}]}
Keep the existing terminal tab title exactly as launched. Do not rename the terminal tab or set an application title.
Publish your live activity via `..\..\tools\set-ratatosk-worker-activity.ps1` using granular statuses such as starting, workspace-verify, syncing, planning, thinking, researching, triaging, designing, implementing, coding, building, validating, testing, documenting, reviewing, creating-pr, waiting-review, awaiting-user-input, input-received, retrying, blocked, completed, and failed. Update it often whenever your actual work changes.
If you need a user decision, use `..\..\tools\request-ratatosk-user-input.ps1` and then wait with `..\..\tools\wait-for-ratatosk-user-input.ps1`.
When you finish or fail, do not stop silently. Run `..\..\tools\finalize-ratatosk-worker.ps1` so Ratatosk always captures a final report, updates temp/state.json, and sends the completion or failure report.
Begin work immediately.
```

Then spawn the terminal tab using the shared worker launcher:

```powershell
& ".\tools\launch-ratatosk-worker.ps1" `
  -Cli "{worker_cli}" `
  -JobNumber "{jobNumber}" `
  -TaskType "{taskType}" `
  -Zone {zone} `
  -WorkspacePath "{workspacePath}" `
  -PromptFile "{workspacePath}\.ratatosk-prompt.md" `
  -PluginDir "."
```

Note: The launcher script keeps the playbook shared by handling the CLI-specific invocation details for `claude` and `copilot`.
The launcher also prefixes the tab title with a small static ASCII status icon (for example `[>]` for active coding work). Keep that title unchanged after launch.

## Step 10: Start Dashboard

Check if the dashboard server is already running (check for the process or the port). If not running, start it:

```powershell
node .\dashboard\server.js &
```

## Step 11: Send Notifications

Send notifications about the spawned tasks:

- **Teams**: Use the notification template to send: "Ratatosk: {N} tasks started" with a list of job numbers and task types.
- **Email**: Send the same summary via email notification.

## Step 12: Print Summary

Print a summary to the console:

- Number of workers spawned
- List of job numbers and their workspace paths
- Dashboard URL
- Any warnings or issues encountered
