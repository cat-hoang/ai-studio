# Autotask Troubleshooting Guide

## VPN or internal connectivity problems

**Symptom:** Autotask cannot reach PAVE, ediprod, Crikey, or other internal services.

**What to check:**

1. Verify the WTG VPN is connected
2. Confirm the configured hosts are reachable from your machine
3. Re-run the action after connectivity is restored

Autotask depends on VPN-backed services for startable polling, ediprod access, and build artifact downloads.

---

## Dashboard not loading

**Symptom:** `http://localhost:3210` does not open or shows a blank/error page.

**What to check:**

1. Verify Node.js is installed
2. Check whether port `3210` is already in use
3. Start (or restart) the dashboard server via PM2:

   ~~~powershell
   # First-time start
   pm2 start dashboard/ecosystem.config.js

   # Subsequent restarts (e.g. after pulling server.js changes)
   pm2 restart autotask-dashboard

   # Check status
   pm2 list

   # Tail live logs
   pm2 logs autotask-dashboard
   ~~~

   If PM2 is not installed: `npm install -g pm2` then `pm2 start dashboard/ecosystem.config.js`.

4. Read the console output for startup errors

---

## Poller shows Error, Stale, or Disabled

**Symptom:** The Mail Poller, Teams Poller, or Startable Poller card is no longer healthy.

**What the states mean:**

- **Healthy**: running normally
- **Polling**: request currently in flight
- **Error**: last attempt failed
- **Stale**: timer is still active but the poller has not advanced recently
- **Idle**: timer exists but the poller is not actively running
- **Disabled**: missing prerequisites or disabled path

**What to do:**

1. Read the poller card detail text first
2. Fix the underlying issue
3. Click **Revive** to restart that poller in place

Typical causes:

- **Mail Poller**: Graph auth expired, SMTP config wrong, mail folder wrong
- **Teams Poller**: Teams chat auth expired, `teams_chat_target_*` config wrong, command polling disabled, direct chat target not found
- **Startable Poller**: VPN down, `buffer_board_url` wrong, PAVE unavailable, board/staff config wrong

---

## Startable column is empty or missing expected jobs

**Symptom:** You expected startable work, but the dashboard shows none or fewer jobs than expected.

Current startable behavior is stricter than a raw board snapshot. Autotask:

1. uses **BM OData** as the primary source; falls back to **PAVE API** when BM OData returns nothing (requires `buffer_board_url` pointing to a running PAVE instance)
2. filters out hard-excluded task types
3. filters out capability-only review tasks with no staff code (for example `CBC`, `CBG`, `CR`, `REV`)
4. removes jobs that are already tracked in waiting, running, completed, or failed
5. may hide never-auto tasks if **Hide Never Auto** is enabled in the UI

**What to check:**

1. Confirm `staff_code`, `board_name`, and `buffer_board_url`
2. Confirm the task is actually startable in PAVE
3. Check whether the task is a review task with no staff assignment
4. Check whether the job is already in one of Autotask's other columns
5. Toggle **Show Never Auto** if you previously hid those cards

If the Startable Poller shows a warning such as **"PAVE API fallback skipped: PAVE portal not running"**, this is normal when the PAVE buffer board is not running locally. BM OData is the primary source; the PAVE fallback fires only when BM OData returns no results. The warning is informational.

---

## Running workers not visible after server.js update

**Symptom:** You started a worker but no Running card appears in the dashboard, even though `temp\state.json` contains the worker entry.

**Cause:** The dashboard server process loaded the old code before `dashboard/server.js` was last changed. The running process still uses the old `STATE_PATH` — typically the root `state.json` — while the PowerShell tools write to `temp\state.json`. The two files diverge silently.

**Diagnosis:**

1. Check the ETag from `/api/state` matches `temp\state.json` — not the root file:

   ~~~powershell
   # Server's ETag
   (Invoke-WebRequest -Uri "http://localhost:3210/api/state" -UseBasicParsing).Headers['ETag']

   # temp\state.json mtime in ms (should match ETag)
   node -e "console.log(require('fs').statSync('temp/state.json').mtimeMs)"
   ~~~

2. Check when the server process started versus when `server.js` was last committed:

   ~~~powershell
   (Get-Process -Id (Get-NetTCPConnection -LocalPort 3210 -State Listen).OwningProcess).StartTime
   git --no-pager log --oneline -3 -- dashboard/server.js
   ~~~

   If the server started before the last `server.js` commit, the running process has stale code.

**Fix:** Restart the server. It will log the resolved state path on startup:

~~~text
State file: C:\BS\autotask\temp\state.json
~~~

Restart command:

~~~powershell
pm2 restart autotask-dashboard
~~~

> **Rule of thumb:** always restart the dashboard server after pulling or committing changes to `dashboard/server.js`.

---

## Worker appears stale or stuck

**Symptom:** A worker stops making visible progress, or the attention strip marks it as stale.

Autotask marks a worker stale when its heartbeat has not updated for longer than `worker_stale_grace_ms` (default 30 minutes).

**What to check:**

1. Look at the worker's Windows Terminal tab for errors or prompts
2. Check the dashboard card activity and phase
3. Inspect the worker entry in `state.json` for `lastHeartbeatAt`, `activityStatus`, `activityMessage`, and `error`
4. If the worker is paused, use **Resume**
5. If the worker has failed, use **Retry**

---

## Worker is waiting for input

**Symptom:** A worker is in `awaiting-user-input`.

**Ways to answer:**

1. Click **Provide Input** on the dashboard card
2. Use the dashboard command bar:

   ~~~text
   reply WI00975129 Use option A
   ~~~

   or:

   ~~~text
   answer WI00975129 Use option A
   ~~~

3. Reply to the paired email and keep the subject unchanged
4. Send a Teams command if Teams direct chat polling is enabled:

   ~~~text
   autotask: reply WI00975129 Use option A
   ~~~

If your answer does not arrive, check the Mail Poller or Teams Poller status and the relevant authentication path.

---

## Cleanup did not delete the workspace

**Symptom:** You clicked Cleanup or ran `cleanup`, but the workspace folder still exists.

**This is expected.**

Current cleanup behavior removes the job from Autotask state and **preserves the workspace folder on disk**.

Autotask keeps the workspace so you do not lose:

- local branches
- logs
- partial changes
- downloaded artifacts
- final reports

Delete the workspace manually only when you are sure you no longer need it.

---

## You still see an old cleanup-blocked warning

**Symptom:** The dashboard still shows a cleanup-blocked warning from an older run.

This usually means the state still contains a legacy `cleanupBlockedReason` from before cleanup behavior was simplified.

**What to do:**

1. Try Cleanup again from the current dashboard
2. Refresh the dashboard
3. If the warning persists and the workspace is no longer needed, remove the stale state record and delete the folder manually after closing file locks

---

## Can I lock my computer while Autotask is running?

**Short answer:** yes, usually.

Autotask runs in your logged-in user session and workers are launched as Windows Terminal tabs. Locking the screen usually allows existing work to continue.

**What is not safe for unattended work:**

- sleep
- hibernate
- sign-out
- reboot
- VPN loss
- network loss

If you want Autotask to keep running while you are away, lock the machine but keep it awake.

---

## Worker tab fails to launch

**Symptom:** Start, Resume, or Retry fails before the worker starts.

**What to check:**

1. `wt.exe` is installed and available
2. Your selected CLI is installed and authenticated:
   - `claude`
   - `copilot`
3. `worker_cli` is set correctly in `config.local.yaml`
4. The workspace path and prompt file still exist

Autotask launches workers through `tools\launch-autotask-worker.ps1`, so Windows Terminal and the target CLI must both be available.

---

## Email replies or command emails are not being processed

**Symptom:** You replied by email or sent a structured command email, but Autotask did nothing.

**What to check:**

1. The dashboard server is running
2. The Mail Poller is healthy
3. Microsoft Graph auth is still valid
4. The polled mail folder is correct
5. For structured command emails:
   - `email_command_intake_enabled: true`
   - sender is allowlisted by `email_command_allowed_senders`
   - subject starts with `email_command_subject_prefix`
   - the first non-empty line is the command text

Supported structured email commands currently include:

- `help`
- `status`
- `queue`
- `start`
- `resume`
- `retry`
- `cleanup`
- `reply`
- `answer`
- `notes`
- `setnotes`

`never-auto` and `allow-auto` are dashboard-only commands.

---

## Teams replies or direct Teams commands do not work

**Symptom:** You sent a direct Teams command such as `autotask: status`, or tried to answer a worker through Teams, but Autotask did nothing.

**What to check:**

1. `teams_chat_enabled: true`
2. `teams_chat_command_polling_enabled: true`
3. `teams_chat_target_mode` and `teams_chat_target` resolve to the chat you expect
4. The dashboard server is running
5. The **Teams Poller** card is healthy
6. Your Teams message begins with the configured prefix, such as:

   ~~~text
   autotask:
   ~~~

7. Local Teams auth has not expired

If you are intentionally using webhook-only Teams mode, direct Teams replies still will not work. In that case use:

1. the dashboard
2. email replies
3. a Workflow or Power Automate bridge that converts Teams messages into structured email

---

## GitHub or CLI authentication expired

**Symptom:** Git push, PR creation, or CLI-based operations fail unexpectedly.

**What to check:**

1. Refresh GitHub auth if needed
2. Re-authenticate the active CLI if prompted
3. If `worker_cli: auto`, confirm Autotask resolved the CLI you expect

For dashboard/email-driven commands, launch failures are often authentication failures underneath.

---

## edi CLI returns authentication error

**Symptom:** `edi workitem get` (or any `edi` command) returns `Authentication failed. Please run 'edi login' to re-authenticate.`

**Before escalating to the user:**

The edi CLI stores its token on disk. Auth errors in Autotask workers are almost always caused by **stale shell environment** in a long-running PowerShell session — not an actually expired token.

1. **Do NOT immediately tell the user to run `edi login`.**
2. Open a fresh PowerShell session (new `powershell` tool call) and retry the exact same command.
3. If it works in the fresh session → proceed. The old shell was stale.
4. Only ask the user to run `edi login` if the command fails in multiple fresh sessions.

**Why this happens:** Copilot CLI tool sessions can persist for extended periods. The edi CLI's token cache on disk gets refreshed in the background, but an old shell process may have a diverged environment or cached state that causes a spurious auth failure.

---

## Crikey artifact download or reuse problems

**Symptom:** Build preparation fails, or a worker behaves as though artifacts are stale.

**What to check:**

1. VPN connectivity
2. NTLM credentials path
3. Access to `https://crikey.wtg.zone`
4. Whether the cached artifact should be deleted and re-downloaded

The shared cache is under `artifacts-cache`, not inside each workspace.

---

## Build still fails after artifact refresh

**Symptom:** Compilation or verification still fails even after artifacts were refreshed.

**What to check:**

1. Whether the failure is actually related to the intended change
2. Whether the target branch has incompatible upstream changes
3. Whether the worker picked the right repo set and workspace mode
4. The worker's final report and recorded build/test scope

---

## Where to look next

For more detail, see:

- `docs/user-guide.md`
- `docs/email-guide.md`
- `docs/teams-guide.md`
