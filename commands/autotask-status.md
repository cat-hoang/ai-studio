---
description: "Show Autotask orchestrator status"
---

# Autotask Status

Display the current status of the Autotask orchestrator, including waiting queue and active workers.

## Step 1: Read State

Read `temp/state.json`. If the file does not exist, report "No Autotask state found. Run /autotask-start to begin." and stop.

## Step 2: Read Config

Read `config.yaml` and `config.local.yaml` (merged) to get the `dashboard_port`.

## Step 3: Display Status

Present the following formatted output:

### Header
```
=== Autotask Status ===
Date: {today's date}
Dashboard: http://localhost:{dashboard_port}
```

### Waiting Queue

If there are items in `waitingQueue`, display a table:

| Job Number | Task Type | Description | Queued At | Source |
|-----------|-----------|-------------|-----------|--------|

If the waiting queue is empty, show: "Waiting Queue: (empty)"

### Workers

If there are items in `workers`, display a table:

| Job Number | Task Type | Zone | Status | Phase | Model | Branch | Duration | Sub-agents | PRs |
|-----------|-----------|------|--------|-------|-------|--------|----------|------------|-----|

- **Duration**: Calculate from `startedAt` to now (or `completedAt` if finished). Display as "Xh Ym".
- **Sub-agents**: Count of sub-agent entries for this worker.
- **PRs**: List PR numbers as links, or "(none)" if empty.
- Color-code status mentally: running = active, completed = done, failed = error, paused = suspended.

If there are no workers, show: "Workers: (none)"

### Summary Line
```
Summary: {N} waiting | {N} running | {N} completed | {N} failed | {N} paused
```

## Step 4: Offer Actions

After displaying the status, prompt the user:
```
Jump to worker tab? Enter job number or 'dash' for dashboard:
```

Wait for user input.

## Step 5: Handle User Action

- **If user enters an issue ID**: Attempt to focus the Windows Terminal tab for that worker. Use `wt.exe -w 0 focus-tab` and try to find the tab by title matching (the tab title was set to "{issueId} {taskType}" when spawned). If the tab cannot be found, report "Could not find terminal tab for {issueId}."

- **If user enters 'dash'**: Open the dashboard in the default browser:
  ```
  start http://localhost:{dashboard_port}
  ```

- **If user presses Enter or types 'q'**: Exit the status view.

