---
description: "Start Autotask task orchestrator - fetch tasks, pick, spawn workers"
---

# Autotask Start

You are the Autotask orchestrator. Follow these steps precisely to fetch tasks, let the user pick, and spawn workers.

## Autopilot Mode (Copilot CLI)

When the active host is **Copilot CLI**, engage autopilot mode immediately and run all steps autonomously without asking for user input:

- **Step 8**: Automatically select all fetched tasks (treat as `all`). If the waiting queue has items, also include them. Do not prompt the user.
- **Step 9b**: Still present the repo selection prompt — wait for the user to choose which repos to clone before proceeding. This avoids polluting workspaces with unrelated repos.
- Skip all other interactive confirmation prompts and proceed through every step end-to-end.
- At the end, print the Step 12 summary so the user can review what was launched.

## Step 1: Connectivity Preflight

Verify the configured issue source is reachable:

- Read `issue_source.adapter` from config to determine which service to check.
- For `github_issues`: confirm the GitHub API (`api.github.com`) is reachable.
- For `linear`: confirm `api.linear.app` is reachable.
- For `jira`: confirm the configured `base_url` host is reachable.
- For `file`: confirm the configured file path exists.
- If the check fails, surface a warning (do not hard-stop unless the adapter is required to function).

## Step 2: Worker CLI Preflight

Read `config.local.yaml` to determine `worker_cli`. If the key is absent, default to `claude`.

Also run `tools\get-autotask-system-health.ps1` and inspect the returned readiness snapshot before launching any workers. If it returns `blocked`, stop and show the blocking reasons. If it returns `degraded`, continue only after surfacing the warnings clearly to the user.

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

Extract key values: `issue_source.adapter`, `repo_groups`, `dashboard_port`, `worker_cli`, notification settings, and any other relevant fields.

## Step 4: Fetch Issues

Run `tools\get-autotask-startable-jobs.ps1` (no extra arguments needed — it reads adapter config internally). This script calls `bun tools/query-issue-source.ts` for the configured adapter and returns a `startableJobs` JSON array. Parse the returned JSON.

## Step 5: Parse, Deduplicate, Score, Sort

- Parse the result set into a unified task format with fields: `issueId`, `title`, `labels`, `repoGroup`, `description`, `source` (adapter name).
- Deduplicate by `issueId`.
- For each task, derive lightweight batching hints before presenting it:
  - probable repo group / repo family from task labels, title, and any known repo metadata
  - expected workspace cost (for example reuse existing workspace, light clone, heavy clone)
  - likely completion value (for example label priority, retries, existing PRs, manual queue bias)
  - overlap bonus when multiple candidate tasks appear to share the same repo group
- Compute a launch score from those hints and sort by launch score, using priority/label as a tiebreaker.

## Step 6: Load Waiting Queue

Read `temp/state.json`. If it exists, load any items in the `waitingQueue` array. These are tasks previously queued via `/autotask-queue`.

## Step 7: Present Task Table

Display a formatted table to the user with these columns:

| # | Issue ID | Title | Labels | Repo Group | Description | Source | Batch Hint | Status |
| - | -------- | ----- | ------ | ---------- | ----------- | ------ | ---------- | ------ |

- Number each row sequentially starting from 1.
- For items that are already in the waiting queue, show "(queued)" in the Status column.
- For items from the fresh fetch, leave Status blank.
- In **Batch Hint**, show a short summary such as repo group, workspace cost, overlap count, and launch score so the operator can quickly pick adjacent work that amortizes workspace setup.
- Link each Issue ID to its source URL (e.g. `https://github.com/{owner}/{repo}/issues/{number}` for GitHub Issues) when available.

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

If the job already has one or more PR links recorded in state, inspect those PRs first and reuse their remote head branches per repo instead of creating a fresh local feature branch.

### 9b. Determine Repo Selection

Determine the narrowest repo set that is safe to launch:

- First prefer any repo metadata already recorded on the queued task (for example `repoGroup` / `repos`).
- Otherwise infer the most likely repo group from `config.repo_groups` using the issue labels, title, and description.
- Fall back to `default_repos` only when no repo-group match is strong enough.

**Present a repo selection prompt before proceeding (both Copilot and Claude CLI).** Show the inferred repo list and offer these options:

```
Repos inferred for {issueId}:
  1. {repo1}
  2. {repo2}
  ...

Clone options:
  A  – Clone all inferred repos above  [default]
  1,2,... – Clone only selected repos (comma-separated numbers)
```

Wait for the user's response. Interpret the input as follows:

- **`A` or blank / Enter**: clone all inferred repos
- **Comma-separated numbers** (e.g. `1,3`): clone only the listed repos; remaining inferred repos are excluded

Record the resolved repo list and repo group in state so later retries and dashboard actions can reuse the same decision.

### 9c. Update State

Write a worker entry to `temp/state.json` under the `workers` array:

```json
{
  "issueId": "{issueId}",
  "title": "{title}",
  "labels": [],
  "repoGroup": "{repoGroup}",
  "description": "{description}",
  "status": "running",
  "phase": "starting",
  "startedAt": "{ISO timestamp}",
  "workspacePath": "workspaces\\{issueId}",
  "branch": null,
  "prUrls": [],
  "repoBranches": {},
  "prs": [],
  "subAgents": []
}
```

Store Autotask-managed paths in `temp/state.json` relative to the repository root (for example `workspaces\GH-123`). Use the fully resolved `workspacePath` variable only when launching tools that require a filesystem path.

### 9d. Write Prompt File and Spawn Windows Terminal Tab

First, write a prompt file to the workspace:

```path
{workspacePath}/.autotask-prompt.md
```

With contents:

```markdown
You are Autotask Task Worker for {issueId}.
Read your full instructions from `..\..\agents\task-worker.md`.
Your workspace is {workspacePath}.
Your issue ID is {issueId}, title is "{title}", labels are {labels}.
repos: {repos as JSON array — e.g. [{"name":"my-repo","path":"{workspacePath}\\my-repo","remoteName":"origin"}]}
Keep the existing terminal tab title exactly as launched. Do not rename the terminal tab or set an application title.
Publish your live activity via `..\..\tools\set-autotask-worker-activity.ps1` using granular statuses such as starting, workspace-verify, syncing, planning, thinking, researching, triaging, designing, implementing, coding, building, validating, testing, documenting, reviewing, creating-pr, waiting-review, awaiting-user-input, input-received, retrying, blocked, completed, and failed. Update it often whenever your actual work changes.
If you need a user decision, use `..\..\tools\request-autotask-user-input.ps1` and then wait with `..\..\tools\wait-for-autotask-user-input.ps1`.
When you finish or fail, do not stop silently. Run `..\..\tools\finalize-autotask-worker.ps1` so Autotask always captures a final report, updates temp/state.json, and sends the completion or failure report.
Begin work immediately.
```

Then spawn the terminal tab using the shared worker launcher:

```powershell
& ".\tools\launch-autotask-worker.ps1" `
  -Cli "{worker_cli}" `
  -IssueId "{issueId}" `
  -Title "{title}" `
  -WorkspacePath "{workspacePath}" `
  -PromptFile "{workspacePath}\.autotask-prompt.md" `
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

- **Teams**: Use the notification template to send: "Autotask: {N} tasks started" with a list of issue IDs and titles.
- **Email**: Send the same summary via email notification.

## Step 12: Print Summary

Print a summary to the console:

- Number of workers spawned
- List of issue IDs and their workspace paths
- Dashboard URL
- Any warnings or issues encountered
