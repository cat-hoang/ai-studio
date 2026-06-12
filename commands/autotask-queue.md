---
description: "Add an issue to the Autotask waiting queue"
---

# Autotask Queue

Add an issue to the Autotask waiting queue for later processing.

**Usage:** `/autotask-queue GH-42` or `/autotask-queue GH-42 bugfix "Description here"`

## Step 1: Parse Arguments

Parse the provided arguments:
- **issueId** (required): The issue identifier (e.g., `GH-42`, `LIN-123`, `PROJ-456`)
- **taskType** (optional): The task type (e.g., `feature`, `bugfix`, `refactor`)
- **description** (optional): A human-readable description of the task

If the argument string contains only the issueId, proceed to Step 2. If taskType and/or description are also provided, skip to Step 3.

## Step 2: Look Up Missing Details

If only issueId was provided:
- Try to find the issue in the configured issue source (GitHub Issues, Linear, Jira, or file).
- Use `gh issue view {issueId}` for GitHub, or the appropriate adapter API for others.
- Extract taskType (infer from labels/type) and description from the response.
- If the lookup fails, warn the user but continue with taskType and description as "unknown".

## Step 3: Read State

Read `temp/state.json`. If the file does not exist, initialize it with:
```json
{
  "date": "{today's date ISO}",
  "waitingQueue": [],
  "workers": []
}
```

## Step 4: Check for Duplicates

Check if the issueId already exists in:
- `waitingQueue` array (already queued)
- `workers` array (already being worked on)

If a duplicate is found, warn the user:
- If in waitingQueue: "Warning: {issueId} is already in the waiting queue (queued at {queuedAt})."
- If in workers: "Warning: {issueId} already has an active worker (status: {status})."

Ask the user if they want to continue adding it anyway. If they decline, stop.

## Step 5: Add to Waiting Queue

Add the task to the `waitingQueue` array:
```json
{
  "issueId": "{issueId}",
  "taskType": "{taskType}",
  "description": "{description}",
  "queuedAt": "{ISO timestamp}",
  "queuedVia": "manual"
}
```

## Step 6: Write Updated State

Write the updated state back to `temp/state.json`.

## Step 7: Send Notification

Send a Teams notification using the queue-added template:
- Message: "Autotask: Queued {issueId} ({taskType}) - {description}"

## Step 8: Confirm

Print confirmation to the console:
```
Queued {issueId} ({taskType}). Run /autotask-start to spawn workers.
```

