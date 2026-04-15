---
description: "Reopen a completed or suspended Ratatosk task to continue recording time"
---

# Ratatosk Continue

Reopen a completed or suspended task so work and time can continue being recorded.

## Arguments

- `$WI` — Work item number (e.g. WI00992034). Required.
- `--task <seq>` — Task sequence number (e.g. 441). Required.
- `--elapsed <time>` — Optional. Elapsed time already recorded (e.g. `2h:50m`). Used as comment in the ediProd note.

## Step 1: Parse Arguments

Extract `$WI`, `--task <seq>`, and `--elapsed <time>` from the invocation.
If `$WI` or `--task` is missing, stop and print usage:
```
Usage: /ratatosk-continue WI00000000 --task 441 [--elapsed 2h:50m]
```

## Step 2: Read State

Read `temp/state.json`. If the file does not exist, print a warning:
```
Warning: temp/state.json not found. Proceeding with ediProd-only continuation.
```

## Step 3: Look Up Task in ediProd

Run:
```
edi task get <seq>
```
to retrieve the task record. If the task is not found, stop with an error.

Print the task summary:
```
Task: <seq> | <type> | <description>
Status: <status>
```

## Step 4: Append Continuation Note to ediProd

Run:
```
edi task notes append "<task-guid>" --content "[<staff>] Continuing: <timestamp> | Elapsed so far: <elapsed>"
```
Where `<timestamp>` is the current local date/time in `YYYY-MM-DD HH:mm` format, and `<elapsed>` is the value from `--elapsed` (or `"unknown"` if not provided).

## Step 5: Update temp/state.json (if it exists)

Find the matching worker entry in `workers` by `jobNumber` matching `$WI` and `taskSequence` matching `--task`.

If the worker entry exists:
- Set `status` to `"running"` (or `"in_progress"`)
- Update `resumedAt` to current ISO timestamp
- Preserve existing `startedAt` and `completedAt` for time continuity calculation

If the worker entry does not exist, insert a new minimal entry:
```json
{
  "jobNumber": "<WI>",
  "taskSequence": <seq>,
  "status": "running",
  "startedAt": null,
  "resumedAt": "<now>",
  "phase": "continuing",
  "branch": ""
}
```

Write the updated `temp/state.json`.

## Step 6: Set Worker Activity

Run:
```
tools\set-ratatosk-worker-activity.ps1 -TaskSequence <seq> -Status "implementing" -Detail "Continuing task <seq>"
```
If the script fails with "Worker not found", ignore the error and continue.

## Step 7: Report

Print:
```
✓ Task <seq> (<WI>) is now marked as continuing.
  ediProd note appended: "[<staff>] Continuing: <timestamp>"
  Elapsed so far: <elapsed>
  
Resume working. Use /ratatosk-wrapup when done.
```

---

**Note**: This command does not call `edi task start` (forbidden per Ratatosk policy). It only appends a note and updates local state to resume time tracking. The task remains in SUS status in ediProd; the human closes tasks manually.
