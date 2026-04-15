# Ratatosk for Copilot CLI

Ratatosk uses a shared orchestration core with CLI-specific adapters.

## Shared entrypoints
- Treat `commands\ratatosk-start.md`, `commands\ratatosk-queue.md`, `commands\ratatosk-status.md`, and `commands\ratatosk-wrapup.md` as the authoritative playbooks.
- Shared runtime state lives in `temp\state.json`.
- Shared dashboard lives in `dashboard\`.

## Temp File Rule
**All temporary files must be written to `temp\`**, never to the repo root or other tracked directories.
This includes: prompt files, script output, MCP responses, debug logs, test scripts, and any other scratch files.
The `temp\` folder is gitignored and will never be committed.

## Copilot adapter rules
- When asked to run Ratatosk from Copilot, prefer `tools\invoke-ratatosk-copilot.ps1`.
- When a playbook needs to spawn worker tabs, use `tools\launch-ratatosk-worker.ps1` instead of hard-coding `claude` or `copilot`.
- Read `config.local.yaml` and honor `worker_cli`. If the key is absent, default to `claude` for backward compatibility.

## Worker guidance
- Worker instructions live in `agents\task-worker.md`.
- Interpret `config.model_routing` as preferred capability tiers and map them to the nearest available model names in the active CLI.

## Additional Resource Repositories

Domain-specific plugin repos are configured in `config.local.yaml` under `domain_plugins`. Each entry has a `name`, `path`, `modules` list, and optional `inv_command`. Read this config at startup and load the matching plugin repos for the work item's module.

### Example: Rating.AI plugin

When a plugin entry matches the Rating modules (RAT, CLR, COS, RSL, ICT, SOQ, RAD, SAL, CCC, NQP, RPI, RS), load resources from its configured path:

- **Skills**: `skills/` — cw-rating, cw-patch-back, planning, rates-logs, rating-test-generator, openspec-*, git
- **Commands**: `commands/` — including `investigate-incident.prompt.md` (mandatory for INV tasks)
- **Instructions**: `instructions/rating.instructions.md` — module routing, architecture rules, coding conventions

**Investigation tasks** (`taskType: investigation`, `inv`, or `INV` prefix) **MUST** strictly follow the workflow defined at the plugin's `inv_command` path — no deviations.

## ediProd task status — hard rules
> These apply to every task type (INV, DOC, coding tasks — no exceptions).
ediProd only allows to work on one task at a time, so strict discipline is required to prevent task collisions and ensure accurate status and time tracking.

- **NEVER run `edi task complete`** — this sets the task to CLS. Human closes tasks manually.
- **NEVER run `edi task start`** — these set WRK and cause worker race conditions.
- **When claiming a task using `edi task claim`**, immediately suspend it with `edi task suspend` (→ SUS) to prevent others from claiming it. Do not start work until the task is in SUS status.
- **Mainly permitted `edi task` action is `edi task suspend`** (→ SUS). Record start/end timestamps in task notes via `edi task notes append`. Leave status as SUS when finished.

## ediProd HTTPS Links
When Ratatosk knows the underlying ediProd GUID, job numbers matching `(WI|CS|PRJ)\d{8}` should be rendered as Session Broker HTTPS links such as `https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/WorkItem/{guid}?lang=en-gb`. If the GUID is unknown, prefer plain text over `edient:` links in notifications and dashboards.

---

## Project Reference (Copilot session cache)

> Detailed memory lives in the Claude Code memory store. See **Session Memory** below for how to locate and seed it on your machine.

### Key paths
| Path | Purpose |
|------|---------|
| `config.yaml` | Shared base config |
| `config.local.yaml` | Machine overrides (gitignored) — `staff_code: HOT`, `worker_cli`, `workspace_root`, `git_source_root` |
| `temp/state.json` | Runtime state — `waitingQueue`, `workers`, `completedJobs`, `pollers` |
| `workspaces/` | Per-job isolated working directories |
| `artifacts-cache/` | Shared Crikey build artifact cache (gitignored) |
| `dashboard/server.js` | Node.js Kanban dashboard on port 3210 |
| `agents/task-worker.md` | Autonomous worker agent definition |
| `temp/` | ALL scratch files — never write temp files elsewhere |

### Core tools (tools/)
| Script | Purpose |
|--------|---------|
| `launch-ratatosk-worker.ps1` | Open Windows Terminal tab, select Claude/Copilot, launch agent |
| `start-ratatosk-worker.ps1` | Workspace setup, task resolution, worker preparation |
| `finalize-ratatosk-worker.ps1` | Final report, state update, send notifications |
| `get-ratatosk-startable-jobs.ps1` | Fetch startable tasks — BM OData primary, PAVE fallback |
| `invoke-ratatosk-command.ps1` | Command parser + dispatcher for all channels (dashboard/email/Teams) |
| `poll-ratatosk-email-input.ps1` | Email command poller (30s interval) |
| `poll-ratatosk-teams-input.ps1` | Teams command poller (30s interval) |
| `send-email-notification.ps1` | Email notifications via Microsoft Graph |
| `send-teams-notification.ps1` | Teams notifications via direct chat |
| `set-ratatosk-worker-activity.ps1` | Update activity badge in dashboard |
| `update-ratatosk-build-plan.ps1` | Record build/test scope |
| `request-ratatosk-user-input.ps1` | Block worker, prompt user |
| `wait-for-ratatosk-user-input.ps1` | Poll for user reply |

### Dashboard commands (all channels: dashboard bar, email, Teams)
| Command | Purpose |
|---------|---------|
| `start <WI> [--task <seq>]` | Launch worker immediately |
| `queue <WI> [--task <seq>] [type] [desc]` | Add to waiting queue |
| `status [WI] [--task <seq>]` | Show state / per-job detail |
| `resume/retry/cleanup <WI> [--task]` | Resume/retry/remove job |
| `notes <WI> --task <seq>` | Read ediProd task notes |
| `setnotes <WI> --task <seq> <content>` | Overwrite notes (multi-line OK via email/Teams) |
| `reply/answer <WI> <msg>` | Answer worker waiting for input |
| `never-auto/allow-auto <WI> --task` | Dashboard only — auto-launch control |

### Startable poller
- Primary: BM OData via `bun tools/query-bm-startable.ts`
- Fallback: PAVE API when BM OData returns empty
- Interval: 30 s (`startable_jobs_polling_interval_ms: 30000`)

### Notification events
- Task started → includes work item title + task number
- Task completed → includes work item title + description
- Status report → per-item: task number, title, Never Auto badge, copyable start command

### Skills (skills/)
| Skill | Purpose |
|-------|---------|
| `vpn-preflight` | Verify VPN before downstream work |
| `workspace-manager` | Per-job workspace create/reuse/cleanup |
| `crikey-build-artifacts` | Download Crikey CI artifacts to avoid full rebuild |
| `cw-incremental-build` | Build only changed projects |
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
| `C:\BS\ratatosk` | `C--BS-ratatosk` |
| `D:\work\ratatosk` | `D--work-ratatosk` |

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
| `ediprod_rules.md` | Hard rules — never complete/start, always claim+suspend |
| `config_state.md` | config.yaml/local.yaml settings, state.json schema |
| `tools_reference.md` | All tools/ scripts catalogued by category |
| `skills_reference.md` | All 5 skills with invocation context |
| `commands_reference.md` | All 5 slash commands with step-by-step flow |
