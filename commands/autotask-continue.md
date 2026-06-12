---
description: "Resume a paused or continuing Autotask task and record that work is continuing"
---

# Autotask Continue

Resume a paused task so work can continue from where it left off.

## Arguments

- `$issueId` — Issue identifier (e.g. `GH-42`, `LIN-123`). Required.
- `--elapsed <time>` — Optional. Elapsed time already recorded (e.g. `2h:50m`). Included in the resume note.

## Step 1: Parse Arguments

Extract `$issueId` and `--elapsed <time>` from the invocation.
If `$issueId` is missing, stop and print usage:
```
Usage: /autotask-continue <issue-id> [--elapsed 2h:50m]
```

## Step 2: Read State

Read `temp/state.json`. If the file does not exist, print a warning and stop.

## Step 3: Update temp/state.json

Find the matching worker entry in `workers` by `issueId`.

If the worker entry exists:
- Set `status` to `"running"`
- Update `resumedAt` to current ISO timestamp
- Preserve existing `startedAt` for duration continuity

If no matching worker entry exists, insert a new minimal entry:
```json
{
  "issueId": "<issueId>",
  "status": "running",
  "startedAt": null,
  "resumedAt": "<now>",
  "phase": "continuing",
  "branch": ""
}
```

Write the updated `temp/state.json`.

## Step 4: Set Worker Activity

Run:
```
tools\set-autotask-worker-activity.ps1 -IssueId <issueId> -ActivityStatus "implementing" -Description "Continuing task"
```
If the script fails with "Worker not found", ignore the error and continue.

## Step 5: Report

Print:
```
✓ Issue <issueId> is now marked as continuing.
  Elapsed so far: <elapsed>
  
Resume working. Use /autotask-wrapup when done.
```

