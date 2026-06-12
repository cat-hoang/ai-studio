# Autotask Orchestrator — Setup

Automated multi-agent task orchestrator for software development workflows.

## Prerequisites

- **Node.js** (v18+)
- **Bun** (v1.0+) — <https://bun.sh>
- **Git** with GitHub CLI (`gh`)
- **Windows Terminal** (`wt`)
- **Claude CLI** (`claude`) and/or **GitHub Copilot CLI** (`copilot`)

## Installation

```powershell
& ".\setup\install.ps1"
```

The installer will:

1. Verify prerequisites
2. Create workspace directories under `.\workspaces\`
3. Generate `config.local.yaml` from the template
4. Prompt for your issue source adapter, preferred `worker_cli` (`auto`, `claude`, or `copilot`), and notification settings
5. Symlink slash commands into `~/.claude/commands/` when Claude is installed
6. Surface a Copilot helper entrypoint when Copilot is installed
7. Keep a root `plugin.json` manifest available for Copilot `--plugin-dir` sessions

## First Run

### Usage options

Autotask can be orchestrated from either **GitHub Copilot CLI** or **Claude Code CLI**.

#### Option A — GitHub Copilot CLI (most economical)

1. Open a terminal in the Autotask folder.
2. Start Copilot CLI with a cost-effective model (0× premium requests):
   ```
   copilot -i --model gpt-4o-mini --plugin-dir .
   ```
3. Tell Copilot: **"start autotask server"**
4. Subsequent task agents are launched with Copilot CLI.

#### Option B — Claude Code CLI

1. Open a terminal in the Autotask folder.
2. Start Claude Code:
   ```
   claude
   ```
3. Tell Claude: **"start autotask server"**
4. Subsequent task agents are launched with Claude Code.

### Launch the orchestrator

```ai-command
/autotask-start
```

## Configuration Reference

### config.yaml (shared, do not edit)

| Key | Description |
| --- | ----------- |
| `branch_prefix` | Git branch prefix for worker branches |
| `dashboard_port` | Local dashboard port (default: 3210) |
| `issue_source.adapter` | Active adapter: `github-issues`, `linear`, `jira`, or `file` |
| `model_routing` | Preferred model tier per task phase |
| `startable_jobs_polling_interval_ms` | Poll interval for refreshing the dashboard Startable column |
| `startable_jobs_fetch_timeout_ms` | Timeout for one Startable-column refresh attempt |
| `email_command_intake_enabled` | Enable structured command emails for Autotask |
| `email_command_subject_prefix` | Subject prefix for command emails |
| `email_command_allowed_senders` | Comma-separated allowlist for command emails |

### config.local.yaml (per-machine, gitignored)

| Key | Description |
| --- | ----------- |
| `worker_cli` | Worker launcher to use: `auto`, `claude`, or `copilot` |
| `workspace_root` | Where worktrees are created |
| `artifacts_cache` | Build artifact cache directory |
| `git_source_root` | Root of shared read-only Git mirrors (for reference mode) |
| `issue_source.adapter` | Override the active issue source adapter |
| `teams_chat_enabled` / target settings | Teams notification settings |
| `smtp_from` / `smtp_to` | Email notifications and reply loop |
| `email_polling_interval_ms` | Inbox polling interval for worker reply emails |

## Slash Commands

| Command | Description |
| ------- | ----------- |
| `/autotask-start` | Start the orchestrator for the day |
| `/autotask-queue` | Add an issue to the work queue |
| `/autotask-status` | Dashboard of active workers and progress |
| `/autotask-continue` | Resume a paused task |
| `/autotask-wrapup` | End-of-day wrap-up and summary |

## Worker final reports

Autotask workers should not stop silently.

- Use `.\tools\finalize-autotask-worker.ps1` on both success and failure.
- The script writes `.autotask\final-report.json` inside the workspace, updates `state.json`, and sends completion/failure notifications.
- Claude sessions also load a Stop hook from `hooks\hooks.json` that blocks exit if a Autotask worker has no final report yet.
