# Ratatosk Orchestrator

Multi-agent task orchestrator for WiseTech development work items.

## Repository Role
This directory contains the shared Ratatosk orchestration core plus CLI-specific adapters.

## Shared Core
- `config.yaml` / `config.local.yaml`
- `temp/state.json`
- `dashboard/`
- `workspaces/`
- `commands/` playbooks
- `tools/launch-ratatosk-worker.ps1`

## Claude Adapter
- `.claude-plugin\plugin.json`
- Claude slash commands under `commands/`
- Claude agent definition in `agents/task-worker.md`

## Copilot Adapter
- `plugin.json`
- `AGENTS.md`
- `tools/invoke-ratatosk-copilot.ps1`
- `worker_cli: copilot` in `config.local.yaml`

## Key Paths
- **Config**: `config.yaml` (base), `config.local.yaml` (local overrides, gitignored)
- **State**: `temp/state.json` (runtime state — workers, queue, completed/failed jobs)
- **Workspaces**: `workspaces/` (per-job working directories)
- **Artifacts**: `artifacts-cache/` (Crikey build artifact cache)
- **Dashboard**: `dashboard/server.js` on port 3210
- **Temp**: `temp/` (gitignored — all scratch files, prompts, and output files go here)

## Temp File Rule
**All temporary files must be written to `temp/`**, never to the repo root or other tracked directories.
This includes: prompt files, script output, MCP responses, debug logs, test scripts, and any other scratch files.
The `temp/` folder is gitignored and will never be committed.

## Shared Commands
- `/ratatosk-start` — Fetch tasks, select, spawn worker tabs
- `/ratatosk-status` — Show current orchestrator state
- `/ratatosk-queue` — Add a task to the waiting queue
- `/ratatosk-wrapup` — End-of-day: verify PRs, save context, cleanup, summary

## Agents
- `task-worker` — Autonomous worker that drives a work item through the full lifecycle

## Additional Resource Repositories

Domain-specific plugin repos are configured in `config.local.yaml` under `domain_plugins`. Each entry has a `name`, `path`, `modules` list, and optional `inv_command`. Read this config at startup and load the matching plugin repos for the work item's module.

### Example: Rating.AI plugin

When a plugin entry matches the Rating modules (RAT, CLR, COS, RSL, ICT, SOQ, RAD, SAL, CCC, NQP, RPI, RS), load resources from its configured path:

- **Skills**: `skills/` — cw-rating, cw-patch-back, planning, rates-logs, rating-test-generator, openspec-*, git
- **Commands**: `commands/` — including `investigate-incident.prompt.md` (mandatory for INV tasks)
- **Instructions**: `instructions/rating.instructions.md` — module routing, architecture rules, coding conventions

**Investigation tasks** (`taskType: investigation`, `inv`, or `INV` prefix) **MUST** strictly follow the workflow defined at the plugin's `inv_command` path — no deviations.

## ediProd task status — hard rules (workers)
> Applies to every task type (INV, DOC, coding — no exceptions).

- **NEVER run `edi task complete`** — sets task to CLS. Human closes tasks manually.
- **NEVER run `edi task start`** — these set WRK and cause worker race conditions.
- **When claiming a task using `edi task claim`**, immediately suspend it with `edi task suspend` (→ SUS) to prevent others from claiming it. Do not start work until the task is in SUS status.
- **Mainly permitted `edi task` action is `edi task suspend`** (→ SUS). Record start/end timestamps in task notes via `edi task notes append`. Leave status as SUS when finished.

## ediProd HTTPS Links
When Ratatosk knows the underlying ediProd GUID, job numbers matching `(WI|CS|PRJ)\d{8}` should be rendered as Session Broker HTTPS links such as `https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/WorkItem/{guid}?lang=en-gb`. If the GUID is unknown, prefer plain text over `edient:` links in notifications and dashboards.

## Autonomous Operation
Worker tabs are launched through `tools\launch-ratatosk-worker.ps1`, which selects `claude` or `copilot` based on `worker_cli`. Claude workers still run with `--dangerously-skip-permissions`; Copilot workers use `copilot -i` with `--plugin-dir .`, `--allow-all`, and `--no-ask-user`.

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

