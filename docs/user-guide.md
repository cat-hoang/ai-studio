# Ratatosk User Guide

## Overview

Ratatosk is a local orchestrator for WiseTech work items. It watches for startable work, keeps a queue of jobs, launches autonomous AI workers in dedicated workspaces, and gives you a local dashboard for oversight and control.

The shared core is generic. Your local configuration and any matching domain plugins decide which repos, instructions, and helper resources Ratatosk uses for a given task.

At a high level, Ratatosk does five things:

1. Polls for startable work from your configured buffer board source
2. Tracks queued, running, completed, and failed jobs in `state.json`
3. Launches one worker per job or task sequence in its own Windows Terminal tab
4. Exposes a dashboard at `http://localhost:3210`
5. Sends notifications and routes human replies back to workers

## Core concepts

### Orchestrator

The orchestrator is the shared control plane. It owns:

- `state.json` for queue and worker state
- the dashboard server
- the email poller
- the startable-jobs poller
- automatic launch decisions when autonomy mode is enabled

### Workers

Each worker is an AI session dedicated to one job and, when known, one task sequence. Workers run in a dedicated workspace under your configured `workspace_root` and publish live activity back to Ratatosk.

Workers are launched in **Windows Terminal tabs** and keep the tab title fixed so Ratatosk can find the tab again later.

### Startable poller

The startable poller refreshes the **Startable** column in the dashboard. It uses **BM OData** as its primary source (via a fast TypeScript script) and automatically falls back to the **PAVE API** when BM OData returns nothing. Neither path spends AI requests.

### Dashboard

The dashboard is the main operator surface. It shows poller health, autonomy state, queue and worker columns, attention items, command entry, and startable work.

### Notifications and replies

Ratatosk supports:

- **Dashboard** for immediate local control
- **Email** for asynchronous replies and structured commands
- **Teams** for notifications, and optionally direct-chat commands

Teams can still run in the old notify-only webhook mode, but it can now also use a direct Teams chat plus a Teams command poller when `teams_chat_enabled: true`.

## Installation and setup

### Prerequisites

- **Node.js** (v18 or later)
- **Git**
- **Windows Terminal** (`wt.exe`)
- **Claude Code CLI** and/or **GitHub Copilot CLI**
- **VPN access** for internal services such as PAVE, ediprod, and Crikey

### First-time setup

Run the installer from the Ratatosk repository root:

~~~powershell
.\setup\install.ps1
~~~

The installer verifies prerequisites, creates local config scaffolding, prepares dashboard dependencies, and sets up Ratatosk for your current CLI environment.

The most important local settings live in `config.local.yaml`:

- `staff_code`
- `board_name`
- `worker_cli`
- `workspace_root`
- `git_source_root`
- notification settings such as `teams_chat_*` and SMTP values (incoming webhook deprecated)

## Usage options and economics

Ratatosk can be orchestrated from either **GitHub Copilot CLI** or **Claude Code CLI**.

### Option A — GitHub Copilot CLI (most economical)

1. Open a terminal in the Ratatosk folder.
2. Start Copilot with the GPT-5 mini model (0× premium requests for the orchestrator):
   ```
   copilot -i --model gpt-5-mini --plugin-dir .
   ```
3. Tell Copilot: **"start ratatosk server"**
4. Subsequent task agents launch with Copilot CLI.
5. Each task agent (e.g. Sonnet 4.6) normally consumes **1 premium request**. Running the orchestrator on GPT-5 mini costs 0 premium requests.

### Option B — Claude Code CLI

1. Open a terminal in the Ratatosk folder.
2. Start Claude Code: `claude`
3. Tell Claude: **"start ratatosk server"**
4. Subsequent task agents launch with Claude Code.
5. Token spend per task varies with task complexity.

**Tip:** Copilot CLI + GPT-5 mini is the most economical orchestrator. Use Claude Code when task complexity demands stronger reasoning.

## Daily workflow

### Start of day

Run:

~~~text
/ratatosk-start
~~~

Ratatosk will:

1. Read your configuration
2. Check connectivity prerequisites such as VPN-backed services
3. Fetch candidate work from your configured board/source
4. Let you choose which tasks to launch
5. Ask how to prepare the workspace repo set
6. Start one worker tab per selected task
7. Start the dashboard server if it is not already running

When Ratatosk infers a repo set, it offers these workspace choices:

- **`A`** or blank: clone all inferred repos
- **`N`**: reference mode, no clone, work read-only against configured source paths
- **`1,3`** style selection: clone only the chosen repos

Ratatosk records that choice so retries and resumes can reuse the same workspace strategy.

### During the day

Use either:

~~~text
/ratatosk-status
~~~

or the dashboard:

~~~text
http://localhost:3210
~~~

Typical day-to-day actions are:

- queueing a task for later
- starting a queued or startable task
- pausing and resuming work
- replying to worker questions
- reviewing PR links and worker summaries
- nudging pollers with **Revive**
- changing autonomy mode or worker budget

### End of day

Run:

~~~text
/ratatosk-wrapup
~~~

Wrap-up verifies PRs, pauses running work safely, writes end-of-day context, and sends the daily summary. It **does not automatically delete workspaces**.

### Locking your computer

Locking the screen is generally fine. Existing Ratatosk processes and worker tabs usually keep running because they stay in your logged-in session.

What stops Ratatosk is **sleep, hibernate, sign-out, reboot, VPN loss, or network loss**. If you want Ratatosk to keep working while you are away, lock the machine but keep it awake.

## Command channels

Ratatosk has three operator command channels:

1. **Slash commands** for high-level workflows
2. **Dashboard manual command bar** for exact job/task control
3. **Structured command emails** for asynchronous remote control
4. **Direct Teams chat commands** when Teams chat polling is enabled

These channels do **not** all support the same command set, so the sections below call that out explicitly.

### Slash commands

| Command | Purpose |
| ------- | ------- |
| `/ratatosk-start` | Fetch work, choose tasks, and spawn workers |
| `/ratatosk-status` | Show current queue and worker state |
| `/ratatosk-queue WI00975129` | Queue a job manually |
| `/ratatosk-queue WI00975129 CDF "Description here"` | Queue a job with explicit task type and description |
| `/ratatosk-wrapup` | Verify PRs, pause work safely, and send a summary |

Use slash commands for the main daily workflow. Use the dashboard/manual command bar when you need precise task-sequence control.

### Dashboard manual command bar

The **Commands** card in the dashboard accepts the following syntax. Click **Manual (?)** to open the built-in syntax table.

| Command | What it does |
| ------- | ------------ |
| `start <WI> [--task <seq>]` | Queue the job and immediately launch a worker |
| `queue <WI> [--task <seq>] [type] [desc]` | Add a job to the waiting queue without launching |
| `resume <WI> [--task <seq>]` | Resume a paused worker |
| `retry <WI> [--task <seq>]` | Retry a failed worker |
| `cleanup <WI> [--task <seq>]` | Remove the job from Ratatosk state and keep the workspace on disk |
| `status [WI] [--task <seq>]` | Show overall status, or a specific job when a job number is supplied |
| `notes <WI> --task <seq>` | Read ediProd task notes for the specified job/task |
| `never-auto <WI> --task <seq>` | Prevent that specific task from being auto-started |
| `allow-auto <WI> --task <seq>` | Remove the never-auto flag for that task |
| `help` | Show the supported command list |

Notes:

- `never-auto` and `allow-auto` are **per task**, so include `--task <seq>`.
- `start` bypasses auto-launch guardrails and launches immediately.
- `cleanup` removes the card from Ratatosk state but intentionally preserves the workspace folder for manual inspection.
- `notes` reads ediProd task notes. To edit notes, use the **Notes** button on a startable or waiting card (opens the Notes modal).
- Worker-reply commands exist, but they matter only when a worker explicitly opens a user-input request. See the input section or `docs/email-guide.md` if you need that path.

### Structured command emails

Structured email commands are available only when `email_command_intake_enabled: true`.

Email command intake supports this subset:

- `help`
- `status [WI] [--task <seq>]`
- `queue <WI> [--task <seq>] [type] [desc]`
- `start <WI> [--task <seq>]`
- `resume <WI> [--task <seq>]`
- `retry <WI> [--task <seq>]`
- `cleanup <WI> [--task <seq>]`
- `notes <WI> --task <seq>`
- `setnotes <WI> --task <seq> <content>`

Email command intake does **not** support:

- `never-auto`
- `allow-auto`

Use the dashboard command bar for those.

### Direct Teams chat commands

Direct Teams commands are available only when:

- `teams_chat_enabled: true`
- `teams_chat_command_polling_enabled: true`

The message must start with the configured prefix, which defaults to:

~~~text
ratatosk:
~~~

Examples:

- `ratatosk: status`
- `ratatosk: start WI00975129 --task 423`
- `ratatosk: retry WI00975129 --task 423`
- `ratatosk: cleanup WI00975129 --task 423`
- `ratatosk: reply WI00975129 Use option A`
- `ratatosk: notes WI00975129 --task 423`
- `ratatosk: setnotes WI00975129 --task 423 Your note content here`

Teams command polling uses the same Ratatosk command parser as the email path, so replies to workers can go through the same `reply` / `answer` syntax.
`never-auto` / `allow-auto` remain dashboard-only.

For `setnotes`, multi-line content is supported: send the command on one line and the note body on the following lines in the same Teams message.

## Dashboard guide

The dashboard lives at:

~~~text
http://localhost:3210
~~~

It auto-refreshes and keeps your local UI choices such as theme and command-help visibility.

### Top bar

The header shows:

- current date and connection status
- a **dark/light theme toggle**
- live health cards for the active pollers
- a **Commands** card with direct command entry
- an **Autonomy** card for mode and worker-budget control
- a **Needs Attention** strip for actionable problems

### Poller cards

Ratatosk currently surfaces:

- **Mail Poller**
- **Teams Poller** when Teams direct chat is configured
- **Startable Poller**

Poller health labels are:

- **Healthy**: running normally
- **Polling**: currently in flight
- **Error**: last attempt failed
- **Stale**: timer is active but the poller has not advanced recently
- **Idle**: timer exists but the poller is not actively running
- **Disabled**: missing prerequisites or intentionally unavailable

Use **Revive** to restart a poller in place after you fix the underlying issue.

### Autonomy card

The Autonomy card lets you change:

- `autonomy_mode`
- `max_concurrent_workers`

Current autonomy modes are:

- **`suggestions-only`**: Ratatosk shows startable work but does not launch automatically
- **`auto`**: Ratatosk automatically launches startable work while health and worker-budget guardrails allow it

The card also shows Ratatosk's current auto-launch state:

- **idle**
- **blocked**
- **launching**

### Needs Attention strip

The attention strip summarizes operator-facing problems such as:

- stale workers
- workers waiting for input
- workers in blocked state
- paused jobs that are good candidates to resume
- cleanup-blocked records from older state
- degraded integrations such as auth or poller failures

### Board columns

The main board is split into:

- **Startable**
- **Waiting Queue**
- **Running**
- **Completed**
- **Failed**

### Startable column

The Startable column shows startable work discovered by the startable poller.

Current behavior:

- primary source is **BM OData** (`bun tools/query-bm-startable.ts`); automatically falls back to **PAVE API** when BM OData returns nothing
- poll interval defaults to **30 seconds**
- jobs already tracked in waiting, running, completed, or failed are removed from the visible startable list
- excluded task types are filtered out
- tasks with no assigned staff but with a matching capability (from `staff_capabilities`) **are included** — these are unassigned tasks that you are eligible to pick up

Each startable card can show:

- **Queue** to add it to the waiting queue
- **Start Now** to launch immediately
- **Never Auto** / **Allow Auto** to control auto-launch eligibility
- **🚫 Never Auto** badge when a task has the never-auto flag set
- a task picker when a WI has multiple startable task sequences

The column header also includes **Hide Never Auto / Show Never Auto**. That toggle changes only what you see; it does not change the stored auto-start preference.

### Card details and actions

Cards can include:

- job number and task sequence
- task type and summary
- queue source or batch hint information
- current phase and activity
- elapsed duration
- sub-agent count
- user-input request details
- latest resolved input
- final report summary
- PR links for completed work
- error details for failed work

Common card actions:

- **Start** on waiting jobs
- **Resume** on paused jobs
- **Retry** on failed jobs
- **Jump to Tab** on running jobs
- **Provide Input** when a worker is waiting for a response
- **Notes** on startable and waiting cards — opens the ediProd task notes viewer/editor
- **Cleanup** on completed or failed jobs

Cleanup behavior is intentionally conservative: it removes the task from Ratatosk state and leaves the workspace on disk.

## Autonomy and startable polling

### Automatic launch rules

When `autonomy_mode: auto`, Ratatosk evaluates startable work continuously and tries to fill available worker slots.

Auto-launch is blocked when:

- overall system health is not ready
- `max_concurrent_workers` is already reached
- repo-family guardrails are saturated
- every visible candidate is marked **Never Auto**

Manual starts are different:

- **`Start Now`** in the dashboard
- **`start <WI> [--task <seq>]`** in the dashboard command bar
- supported start commands from structured email

These manual launches bypass the automatic guardrails.

### Startable poller behavior

The startable poller:

- uses BM OData as the primary source (`bun tools/query-bm-startable.ts`); falls back to **PAVE API** when BM OData returns nothing
- the BM OData path queries `P9Logs` for SRT events first, expanding the `Parent` task to filter server-side — only tasks that have become startable (SRT log) and are still in ASN status are returned
- fetches tasks assigned to your staff code **plus** unassigned tasks whose required capability matches any code in `staff_capabilities`
- capability Guids are resolved once per config-change and cached in `temp/staff-capability-guids.json`; the cache auto-refreshes when `staff_capabilities` codes change
- writes its result into Ratatosk's in-memory startable cache
- surfaces status and warnings in the dashboard
- triggers the autonomy evaluator after each successful refresh

Relevant config:

- `startable_jobs_polling_interval_ms` — refresh interval (default `30000` ms, 30 seconds)
- `startable_jobs_fetch_timeout_ms` — per-poll timeout
- `startable_jobs_fallback_on_empty` — if `true`, attempt PAVE API fallback when BM OData returns empty (otherwise the automatic fallback only fires when BM OData itself fails)
- `staff_capabilities`
- `excluded_task_types`

## Notifications and reply loops

### Dashboard replies

The dashboard is the fastest way to answer a worker when Ratatosk explicitly asks for input. In normal day-to-day use you may never need this path; it appears only when a worker raises a user-input request.

### Email replies

When a worker asks a question, Ratatosk can send an email with a request identifier in the subject. Reply to that email and keep the subject unchanged.

Email replies are asynchronous and depend on the email poller interval and Microsoft Graph access.

### Teams notifications

Teams is used for outbound notifications and, when Teams command polling is enabled, also for inbound commands:

- task started (includes work item title and task number)
- task completed (includes work item title)
- task failed
- user input needed
- queue added
- daily summary

If `teams_chat_command_polling_enabled: true`, you can also send `ratatosk:` prefixed commands directly in the configured chat. See `docs/teams-guide.md` for the full command list.

## Workspaces, cleanup, and lifecycle

### Workspaces

Each worker uses a dedicated workspace under `workspace_root`.

Ratatosk may:

- clone inferred repos
- clone only a selected subset
- run in reference mode against existing local repos

Ratatosk also keeps an `artifacts-cache` for shared build artifacts so repeated tasks can reuse previously downloaded assets.

### Worker launcher

Workers are launched through `tools\launch-ratatosk-worker.ps1`.

`worker_cli` supports:

- `auto`
- `claude`
- `copilot`

When `worker_cli: auto`, Ratatosk resolves the active CLI based on host environment and command availability.

### Cleanup

Current cleanup behavior is intentionally safe:

- dashboard **Cleanup** removes the task record from Ratatosk state
- command-based **cleanup** removes the task record from Ratatosk state
- workspaces are **preserved**

Delete the workspace manually only when you are sure you no longer need logs, artifacts, branches, or partial results.

### Wrap-up behavior

`/ratatosk-wrapup` keeps workspaces intact. It does not treat completion as permission to delete the whole workspace automatically.

## Configuration reference

### Shared defaults (`config.yaml`)

| Setting | Purpose | Current default |
| ------- | ------- | --------------- |
| `dashboard_port` | Dashboard port | `3210` |
| `buffer_board_url` | Base URL used to resolve the board/PAVE source | `http://localhost:6610/` |
| `crikey_base_url` | Crikey server for shared build artifacts | `https://crikey.wtg.zone` |
| `email_polling_interval_ms` | Email reply/command polling interval | `30000` |
| `email_poll_folder_path` | Shared default mail folder | `Inbox/Ratatosk` |
| `autonomy_mode` | Automatic launch mode | `suggestions-only` |
| `max_concurrent_workers` | Max simultaneous workers | `3` |
| `autonomy_max_workers_per_repo_group` | Soft per repo-family auto-launch cap | `1` |
| `startable_jobs_polling_interval_ms` | Startable refresh interval | `30000` |
| `startable_jobs_fetch_timeout_ms` | Per-poll timeout | `120000` |
| `startable_jobs_fallback_on_empty` | Attempt PAVE API fallback when BM OData returns empty | `false` |
| `excluded_task_types` | Task types hidden from the startable list | `["SHV", "SH0", "PRV", "MTG", "CHK", "CH0", "CH1", "CH2", "CHG", "CH4"]` |
| `staff_capabilities` | BM OData capability codes; includes unassigned tasks matching these | `[]` |
| `model_routing` | Preferred capability tier per phase | `design/code/test/review/triage/default` mapping |

### Machine-specific overrides (`config.local.yaml`)

| Setting | Purpose |
| ------- | ------- |
| `staff_code` | Your staff code |
| `board_name` | The board Ratatosk should watch |
| `worker_cli` | `auto`, `claude`, or `copilot` |
| `workspace_root` | Workspace root directory |
| `artifacts_cache` | Shared artifacts cache path |
| `git_source_root` | Existing repo root used for reference mode and cloning |
| `teams_webhook_url` | Teams outbound notification webhook |
| `smtp_server` / `smtp_from` / `smtp_to` | Email settings |
| `email_poll_folder_path` | Local mail folder override |
| `email_command_intake_enabled` | Enable structured command emails |
| `email_command_send_replies` | Reply to command emails with success/failure |
| `email_command_subject_prefix` | Required subject prefix for command emails |
| `email_command_allowed_senders` | Allowlist for command-email senders |
| `startable_jobs_fallback_mode` | Local fallback override |
| `startable_jobs_fallback_on_empty` | Local fallback-on-empty override |
| `staff_capabilities` | BM OData capability codes for unassigned-task matching |
| `domain_plugins` | Extra plugin repos and module routing |
| `ntlm_credentials_path` | Path to NTLM credentials |

### Model routing

`config.yaml` expresses preferred capability tiers such as `opus` and `sonnet`. The active CLI maps those preferences to the nearest available model names for that environment.

## Related documents

- `docs/email-guide.md`
- `docs/teams-guide.md`
- `docs/troubleshooting.md`
