---
description: "Add a task/work item to the Ratatosk waiting queue"
---

# Ratatosk Queue

Add a task to the Ratatosk waiting queue for later processing.

**Usage:** `/ratatosk-queue WI00975129` or `/ratatosk-queue WI00975129 CDF "Description here"`

## Step 1: Parse Arguments

Parse the provided arguments:
- **jobNumber** (required): The work item / job number (e.g., `WI00975129`)
- **taskType** (optional): The task type code (e.g., `CDF`, `EDI`, `MAP`)
- **description** (optional): A human-readable description of the task

If the argument string contains only the job number, proceed to Step 2. If taskType and/or description are also provided, skip to Step 3.

## Step 2: Look Up Missing Details

If only jobNumber was provided:
- Determine the job type from the prefix (WI → workitem, CS → incident).
- Run `edi workitem get {jobNumber}` (for WI) or `edi cs get {jobNumber}` (for CS) to retrieve the job details.
- Then run `edi task list {jobNumber}` to retrieve the workflow tasks.
- Extract the taskType and description from the response.
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

Check if the jobNumber already exists in:
- `waitingQueue` array (already queued)
- `workers` array (already being worked on)

If a duplicate is found, warn the user:
- If in waitingQueue: "Warning: {jobNumber} is already in the waiting queue (queued at {queuedAt})."
- If in workers: "Warning: {jobNumber} already has an active worker (status: {status})."

Ask the user if they want to continue adding it anyway. If they decline, stop.

## Step 5: Add to Waiting Queue

Add the task to the `waitingQueue` array:
```json
{
  "jobNumber": "{jobNumber}",
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
- Message: "Ratatosk: Queued {jobNumber} ({taskType}) - {description}"

## Step 8: Confirm

Print confirmation to the console:
```
Queued {jobNumber} ({taskType}). Run /ratatosk-start to spawn workers.
```

