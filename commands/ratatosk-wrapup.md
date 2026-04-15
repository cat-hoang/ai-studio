---
description: "End-of-day wrapup - verify PRs, save context, pause work safely, send summary"
---

# Ratatosk Wrapup

End-of-day procedure: verify PRs, save in-progress work, pause work safely, and send a daily summary.

## Step 1: Read State

Read `temp/state.json`. If the file does not exist or has no workers, report "No Ratatosk state found. Nothing to wrap up." and stop.

## Step 2: Process Workers by Status

Iterate through all workers in `temp/state.json` and handle each based on its current status.

### Completed Workers

For each worker with status "completed":

1. **Verify PRs**: For each PR URL in the worker's `prs` array, run `gh pr view {prUrl}` to confirm:
   - The PR exists
   - The PR is in "open" or "merged" state
   - Log any PRs that are closed/missing as warnings

2. **Keep Workspace Intact**: Do not clean up the workspace automatically. A completed task does not mean the whole work item is finished.

### Running Workers (still in progress)

For each worker with status "running":

1. **Save Work in Progress**: In the worker's workspace directory, run:
   ```
   cd {workspacePath} && git add -A && git commit -m "WIP: end-of-day save"
   ```
   If there are no changes to commit, that is fine -- skip the commit.

2. **Update State**: Set the worker's status to "paused" in `temp/state.json`.

### Failed Workers

For each worker with status "failed":

1. **Log Error Details**: Read any error information from the worker's state (error field, last phase, etc.).

## Step 3: Build Daily Summary

Compile a daily summary with the following sections:

### Tasks Completed
For each completed worker:
- Issue ID and task type
- PR links with status (open/merged)
- Brief completion note

### Tasks In Progress (Paused)
For each paused worker:
- Issue ID and task type
- Current phase
- Branch name
- Brief context of remaining work

### Tasks Failed
For each failed worker:
- Issue ID and task type
- Error summary
- Phase where failure occurred

### Statistics
- Total tasks processed today
- Completed count
- In-progress (paused) count
- Failed count
- Total PRs created
- Total PRs merged

## Step 4: Send Teams Notification

Send the daily summary via Teams using the daily-summary template. The message should include:
- Date
- Completion statistics
- List of completed tasks with PR links
- List of paused tasks with current phase
- List of failed tasks with error summaries

## Step 5: Send Email Report

Send the daily summary via Email using the daily-report template. The email should contain the full detailed summary from Step 4 in a well-formatted layout.

## Step 6: Print Summary to Console

Display the full daily summary to the console so the user can review it.

## Step 7: Update State

Update `temp/state.json`:
- Set the `date` field to today's date
- Keep completed, paused, and failed task records in state unless the user explicitly runs cleanup
- Ensure paused and failed workers remain available for the next session
- Write the updated state back to disk

