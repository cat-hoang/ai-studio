# Ratatosk Orchestrator

Automated task orchestrator for Rating/CargoWise development workflows.

## Prerequisites

- **Node.js** (v18+)
- **Git** with GitHub CLI (`gh`)
- **Windows Terminal** (`wt`)
- **Claude CLI** (`claude`) and/or **GitHub Copilot CLI** (`copilot`)
- VPN connection to `crikey.wtg.zone`

## Installation

```powershell
& ".\setup\install.ps1"
```

The installer will:

1. Verify prerequisites and VPN connectivity
2. Create workspace directories under `.\workspaces\`
3. Generate `config.local.yaml` from the template
4. Prompt for your staff code, board name, preferred `worker_cli` (`auto`, `claude`, or `copilot`), and notification settings
5. Symlink slash commands into `~/.claude/commands/` when Claude is installed
6. Surface a Copilot helper entrypoint when Copilot is installed
7. Keep a root `plugin.json` manifest available for Copilot `--plugin-dir` sessions

## First Run

### Usage options and economics

Ratatosk can be orchestrated from either **GitHub Copilot CLI** or **Claude Code CLI**. Each mode has different token/premium-request cost characteristics.

#### Option A — GitHub Copilot CLI (most economical)

1. Open a terminal in the Ratatosk folder (`C:\BS\ratatosk`).
2. Start Copilot CLI with the GPT-5 mini model (0× premium requests):
   ```
   copilot -i --model gpt-5-mini --plugin-dir .
   ```
3. Tell Copilot: **"start ratatosk server"**
4. Subsequent task agents are launched with Copilot CLI.
5. Each task agent run (Sonnet 4.6 equivalent) normally consumes **1 premium request**. By running the orchestrator itself on GPT-5 mini, orchestration costs 0 premium requests.

#### Option B — Claude Code CLI

1. Open a terminal in the Ratatosk folder.
2. Start Claude Code:
   ```
   claude
   ```
3. Tell Claude: **"start ratatosk server"**
4. Subsequent task agents are launched with Claude Code.
5. Token spend per task varies with task complexity — simple tasks are cheap, long investigations or large builds use more tokens.

**Summary: Copilot CLI + GPT-5 mini is the most economical orchestrator.** Use Claude Code when task complexity demands higher reasoning quality.

### Claude Code / GitHub Copilot CLI

```ai-command
/ratatosk-start
```

## Configuration Reference

### config.yaml (shared, do not edit)

| Key | Description |
| --- | ----------- |
| `branch_prefix` | Git branch prefix (default: your staff code) |
| `dashboard_port` | Local dashboard port (default: 3210) |
| `buffer_board_url` | Buffer board endpoint |
| `crikey_base_url` | Crikey CI server |
| `product_repo_mapping` | Maps product areas to repos |
| `model_routing` | Preferred model tier per task phase (mapped by the active CLI) |
| `startable_jobs_polling_interval_ms` | Poll interval for refreshing the dashboard Startable column |
| `startable_jobs_fetch_timeout_ms` | Timeout for one Startable-column refresh attempt |
| `email_command_intake_enabled` | Enable structured command emails for Ratatosk |
| `email_command_subject_prefix` | Subject prefix for command emails |
| `email_command_allowed_senders` | Comma-separated allowlist for command emails |
| `startable_jobs_fallback_mode` | Opt-in fallback mode when PAVE polling fails |
| `startable_jobs_fallback_on_empty` | Also use fallback when PAVE returns no jobs |

The dashboard Startable-column poll uses direct PAVE API calls, so it does not spend Copilot/Claude tokens or premium requests. The shared default is 5 minutes and can be tuned locally.

If you enable `startable_jobs_fallback_mode: "ediprod-mcp"`, Ratatosk will ask Copilot to use the `ediprod` skill as a backup source when PAVE is unavailable. That fallback is opt-in because it can spend AI requests.

### config.local.yaml (per-machine, gitignored)

| Key | Description |
| --- | ----------- |
| `staff_code` | Your 3-character staff code |
| `board_name` | Buffer board name to monitor |
| `worker_cli` | Worker launcher to use: `auto`, `claude`, or `copilot` |
| `workspace_root` | Where worktrees are created |
| `artifacts_cache` | Build artifact cache directory |
| `git_source_root` | Root of your Git clones |
| `teams_webhook_url` | Optional Teams notification webhook (outbound only) |
| `smtp_from` / `smtp_to` | Optional email notifications and reply loop |
| `email_polling_interval_ms` | Inbox polling interval for worker reply emails |
| `ntlm_credentials_path` | Path to NTLM credentials (default: `~/.etc`) |

## Slash Commands

| Command | Description |
| ------- | ----------- |
| `/ratatosk-start` | Start the orchestrator for the day |
| `/ratatosk-queue` | Show and manage the work queue |
| `/ratatosk-status` | Dashboard of active workers and progress |
| `/ratatosk-wrapup` | End-of-day wrap-up and summary |

## Worker final reports

Ratatosk workers should not stop silently.

- Use `.\tools\finalize-ratatosk-worker.ps1` on both success and failure.
- The script writes `.ratatosk\final-report.json` inside the workspace, updates `state.json`, and sends completion/failure notifications.
- Claude sessions also load a Stop hook from `hooks\hooks.json` that blocks exit if a Ratatosk worker has no final report yet.

## Quick steps to install the edi CLI (used by Ratatosk):

1. Install Bun (preferred) from <https://bun.sh> (or ensure Node/npm is available).

2. Clone the mcp-ediprod repo:

```
git clone https://github.com/WiseTechGlobal/mcp-ediprod.git
cd mcp-ediprod
```

1. Install & link the CLI:

```
bun install
bun link
```

(bun link creates a global edi command - if it doesn't work, create an edi.bat shim that runs `bun run edi %*` or use `npx edi` instead of `edi`.)

1. Verify:

```
edi --version
edi workitem list --product ENT --limit 1
```

1. Authenticate: run `edi login` and follow prompts (tokens cached on disk). You may need to re-authenticate every 24 hours.
Another option is to save GLOW_USERNAME (firstname.lastname) and GLOW_PASSWORD as environment variables. This option is less secure and not recommended for shared machines but it works every time without interactive login.
