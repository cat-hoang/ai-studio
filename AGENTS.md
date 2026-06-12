# Autotask for Copilot CLI

Autotask uses a shared orchestration core with CLI-specific adapters.

## Shared entrypoints

- Treat `commands\autotask-start.md`, `commands\autotask-queue.md`, `commands\autotask-status.md`, and `commands\autotask-wrapup.md` as the authoritative playbooks.
- Shared runtime state lives in `temp\state.json`.
- Shared dashboard lives in `dashboard\`.

## Temp File Rule

**All temporary files must be written to `temp\`**, never to the repo root or other tracked directories.
This includes: prompt files, script output, MCP responses, debug logs, test scripts, and any other scratch files.
The `temp\` folder is gitignored and will never be committed.

## Copilot adapter rules

- When asked to run Autotask from Copilot, prefer `tools\invoke-autotask-copilot.ps1`.
- When a playbook needs to spawn worker tabs, use `tools\launch-autotask-worker.ps1` instead of hard-coding `claude` or `copilot`.
- Read `config.local.yaml` and honor `worker_cli`. If the key is absent, default to `claude` for backward compatibility.

## Worker guidance

- Worker instructions live in `agents\task-worker.md`.
- Interpret `config.model_routing` as preferred capability tiers and map them to the nearest available model names in the active CLI.

---

## Project Reference (Copilot session cache)

> Detailed memory lives in the Claude Code memory store. See **Session Memory** below for how to locate and seed it on your machine.

### Key paths

| Path | Purpose |
|------|----------|
| `config.yaml` | Shared base config |
| `config.local.yaml` | Machine overrides (gitignored) — `worker_cli`, `workspace_root`, `issue_source` |
| `temp/state.json` | Runtime state — `waitingQueue`, `workers`, `completedJobs`, `pollers` |
| `workspaces/` | Per-job isolated working directories |
| `dashboard/server.js` | Node.js Kanban dashboard on port 3210 |
| `agents/task-worker.md` | Autonomous worker agent definition |
| `temp/` | ALL scratch files — never write temp files elsewhere |

### Core tools (tools/)

| Script | Purpose |
|--------|---------|
| `launch-autotask-worker.ps1` | Open Windows Terminal tab, select Claude/Copilot, launch agent |
| `start-autotask-worker.ps1` | Workspace setup, task resolution, worker preparation |
| `finalize-autotask-worker.ps1` | Final report, state update, send notifications |
| `get-autotask-startable-jobs.ps1` | Fetch startable issues via configured issue-source adapter |
| `invoke-autotask-command.ps1` | Command parser + dispatcher for all channels (dashboard/email/Teams) |
| `poll-autotask-email-input.ps1` | Email command poller (30s interval) |
| `poll-autotask-teams-input.ps1` | Teams command poller (30s interval) |
| `send-email-notification.ps1` | Email notifications via Microsoft Graph |
| `send-teams-notification.ps1` | Teams notifications via direct chat |
| `set-autotask-worker-activity.ps1` | Update activity badge in dashboard |
| `update-autotask-build-plan.ps1` | Record build/test scope |
| `request-autotask-user-input.ps1` | Block worker, prompt user |
| `wait-for-autotask-user-input.ps1` | Poll for user reply |

### Dashboard commands (all channels: dashboard bar, email, Teams)

| Command | Purpose |
|---------|---------|
| `start <issue-id>` | Launch worker immediately |
| `queue <issue-id> [type] [desc]` | Add to waiting queue |
| `status [issue-id]` | Show state / per-job detail |
| `resume/retry/cleanup <issue-id>` | Resume/retry/remove job |
| `reply/answer <issue-id> <msg>` | Answer worker waiting for input |
| `never-auto/allow-auto <issue-id>` | Dashboard only — auto-launch control |

### Startable poller

- Issue source adapter via `bun tools/query-issue-source.ts`
- Interval: 30 s (`startable_jobs_polling_interval_ms: 30000`)

### Notification events

- Task started → includes work item title + task number
- Task completed → includes work item title + description
- Status report → per-item: task number, title, Never Auto badge, copyable start command

### Skills (skills/)

| Skill | Purpose |
|-------|---------|
| `vpn-preflight` | Verify connectivity before downstream work |
| `workspace-manager` | Per-job workspace create/reuse/cleanup |
| `qgl-cli-build` | Glow platform build (YAML/TypeScript) |

---

## Session Memory (Claude Code)

Claude Code automatically loads a persistent memory index from:

```
~/.claude/projects/{encoded-project-path}/memory/MEMORY.md
```

**Path encoding** — the encoded project path is the absolute repo path with each `\` and `:` replaced by `-`:

| Repo path | Encoded project path |
|-----------|---------------------|
| `C:\BS\autotask` | `C--BS-autotask` |
| `D:\work\autotask` | `D--work-autotask` |

Full path on Windows: `C:\Users\{USERNAME}\.claude\projects\{encoded}\memory\`

**First-time setup after cloning:**

1. Derive your encoded path (replace every `\` with `-` and `:` with `-` in your repo's absolute path)
2. Create the directory: `mkdir ~/.claude/projects/{encoded}/memory`
3. Ask Claude: `learn the documents, the code and cache them for future sessions`

**Memory files seeded by that command:**

| File | Contents |
|------|---------|
| `MEMORY.md` | Index — always loaded into context |
| `project_overview.md` | Purpose, key paths, operational constraints |
| `repo_structure.md` | Full directory layout with purposes |
| `architecture.md` | Worker pipeline phases, CLI adapters, domain plugins, hooks |
| `worker_rules.md` | Operational rules — workspace isolation, commit hygiene, notification requirements |
| `config_state.md` | config.yaml/local.yaml settings, state.json schema |
| `tools_reference.md` | All tools/ scripts catalogued by category |
| `skills_reference.md` | All 5 skills with invocation context |
| `commands_reference.md` | All 5 slash commands with step-by-step flow |
