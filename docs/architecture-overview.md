# Autotask System Architecture

> End-to-end reference for the Autotask multi-agent orchestrator. Covers components, data flows, worker lifecycle, notifications, and integrations.

---

## Table of Contents

1. [System Components](#1-system-components)
2. [Component Relationships](#2-component-relationships)
3. [edi CLI — Role Throughout the System](#3-edi-cli--role-throughout-the-system)
4. [Worker Start Flow (Sequence)](#4-worker-start-flow-sequence)
5. [Worker Lifecycle (State Machine)](#5-worker-lifecycle-state-machine)
6. [Worker Finalization Flow](#6-worker-finalization-flow)
7. [CLI Selection Logic](#7-cli-selection-logic)
8. [Startable Jobs Polling](#8-startable-jobs-polling)
9. [Command Intake (Email & Teams)](#9-command-intake-email--teams)
10. [Notification Flow (Email & Teams)](#10-notification-flow-email--teams)
11. [state.json Data Model](#11-statejson-data-model)
12. [Configuration Layering](#12-configuration-layering)
13. [Key Files Reference](#13-key-files-reference)
14. [Failure Modes & Debugging](#14-failure-modes--debugging)
15. [Operational Rules](#15-operational-rules)

---

## 1. System Components

| Component | Technology | Purpose |
|---|---|---|
| **Dashboard UI** | HTML/JS (browser) | Kanban view: Startable → Waiting → Running → Completed/Failed |
| **Dashboard Server** | Node.js (`dashboard/server.js`) | API server; reads/writes `temp\state.json`; spawns workers |
| **State Store** | JSON file (`temp\state.json`) | Authoritative runtime state — all buckets live here |
| **Start Script** | PowerShell (`tools\start-autotask-worker.ps1`) | Sets up workspace; resolves tasks; invokes launch script |
| **Launch Script** | PowerShell (`tools\launch-autotask-worker.ps1`) | Opens Windows Terminal tab; selects Claude or Copilot CLI |
| **Worker Agent** | Claude Code **or** Copilot CLI | Autonomous AI agent that executes the task end-to-end |
| **Finalize Script** | PowerShell (`tools\finalize-autotask-worker.ps1`) | Updates state; sends notifications; cleans up workspace |
| **edi CLI** | Bun/Node (`mcp-ediprod`) | Gate to ediProd: claim, suspend, notes, task queries |
| **Email Notifier** | PowerShell + Microsoft Graph | Sends start/complete/failed reports to configured mailbox |
| **Teams Notifier** | PowerShell + Graph + JS helper | Sends messages to configured Teams chat |
| **Poller: Startable Jobs** | PowerShell (`get-autotask-startable-jobs.ps1`) | Queries BM OData (primary) and PAVE API (fallback) for available tasks every 30 s |
| **Poller: Email Commands** | PowerShell (`poll-autotask-email-input.ps1`) | Reads Inbox/Autotask folder for operator commands |
| **Poller: Teams Commands** | PowerShell (`poll-autotask-teams-input.ps1`) | Reads Teams chat for operator commands |

---

## 2. Component Relationships

```mermaid
graph TB
    subgraph Browser["🖥️ Browser (Dashboard UI)"]
        UI[dashboard/index.html]
    end

    subgraph Server["⚙️ Dashboard Server (Node.js :3210)"]
        API["/api/state<br>/api/queue<br>/api/command<br>/api/pollers"]
        NRM["normalizeState()"]
        STATE["temp/state.json"]
    end

    subgraph Pollers["🔄 Background Pollers (pwsh)"]
        PJ[get-autotask-startable-jobs.ps1]
        PE[poll-autotask-email-input.ps1]
        PT[poll-autotask-teams-input.ps1]
    end

    subgraph Workers["🤖 Worker Agents"]
        SW[start-autotask-worker.ps1]
        LW[launch-autotask-worker.ps1]
        WA["Worker Agent<br/>(Claude Code or Copilot CLI)<br/>in Windows Terminal tab"]
        WS["workspaces/WIxxxxxxxx<br/>(per-job workspace)"]
        FW[finalize-autotask-worker.ps1]
    end

    subgraph Notify["📬 Notifications"]
        EM[send-email-notification.ps1]
        TM[send-teams-notification.ps1]
    end

    subgraph External["🌐 External Services"]
        EDI[edi CLI → ediProd / PAVE]
        GRAPH[Microsoft Graph API]
        TEAMS[Teams Chat]
        CRIKEY[Crikey / GitHub CI]
    end

    UI -- "GET /api/state (every 5s)" --> API
    UI -- "POST /api/queue (Start Now)" --> API
    UI -- "POST /api/command" --> API
    API --- NRM
    NRM --- STATE
    API -- "pwsh start-autotask-worker.ps1" --> SW
    SW --> LW
    LW -- "wt.exe new-tab" --> WA
    WA -- "writes heartbeats" --> STATE
    WA --> WS
    WA -- "on done/fail" --> FW
    FW -- "updates completedJobs/failedJobs" --> STATE
    FW --> EM
    FW --> TM
    PJ -- "writes startableJobs" --> STATE
    PE -- "writes commandHistory" --> STATE
    PT -- "writes commandHistory" --> STATE
    PJ --> EDI
    EM --> GRAPH
    TM --> GRAPH
    GRAPH --> TEAMS
    WA --> EDI
    WA --> CRIKEY
```

---

## 3. edi CLI — Role Throughout the System

The `edi` CLI (from the `mcp-ediprod` repo) is **not just a task management tool** — it is woven into every major phase of the Autotask pipeline. The sections below map each touchpoint.

```mermaid
flowchart TD
    subgraph legend["edi CLI touchpoints (in execution order)"]
        direction TB
        T1["① Startable Jobs Fetch<br>BM OData — query-bm-startable.ts<br>imports createClient from mcp-ediprod/src/apps/cli/auth.ts<br>(auth library, not CLI subprocess)"]
        T2["② Worker Phase 1 — Workspace Setup<br>edi task claim {WI} --task {seq}<br>edi task suspend {WI} --task {seq}<br>(claim → immediately SUS to prevent race conditions)"]
        T3["③ Worker Phase 4 — Read Work Item<br>edi workitem get {WI}<br>edi cs get {WI}<br>edi workflow list {WI}<br>edi task list {WI} --format json<br>edi task notes read {taskId}<br>(discover task details + mandatory human instructions in notes)"]
        T4["④ Worker during execution<br>edi task notes append {taskId} --content ...<br>(record progress, timestamps, intermediate findings)"]
        T5["⑤ Finalize Script — Completion/Failure Note<br>edi --format jsonl task list {WI}  → find taskId by sequence<br>edi task notes read {taskId}  → dedup check<br>edi task notes append {taskId} --content ...  → record result + PRs + duration"]
        T6["⑥ Finalize Script — INV report upload<br>edi file upload {WI} {report.html} --type INT<br>(only for INV task type, best-effort)"]
    end

    A([Startable Jobs Poll]) --> T1
    B([Worker Launched]) --> T2
    T2 --> T3
    T3 --> T4
    T4 --> T5
    T5 --> T6

    style T1 fill:#fef3c7,stroke:#f59e0b
    style T2 fill:#dbeafe,stroke:#3b82f6
    style T3 fill:#dbeafe,stroke:#3b82f6
    style T4 fill:#dbeafe,stroke:#3b82f6
    style T5 fill:#d1fae5,stroke:#10b981
    style T6 fill:#d1fae5,stroke:#10b981
```

### ① BM OData auth (library import)

`tools/query-bm-startable.ts` does **not** shell out to `edi`. It imports the auth layer directly from the mcp-ediprod TypeScript source:

```ts
import { createClient } from 'C:/BS/Git/GitHub/WiseTechGlobal/mcp-ediprod/src/apps/cli/auth.ts';
```

Requirements: mcp-ediprod cloned at that exact path + `edi login` cached + `bun` installed.

### ② Worker Phase 1 — claim & suspend

Immediately after the worker starts, it claims the task and **suspends it** to SUS status:

```
edi task claim {jobNumber} --task {taskSequence}
edi task suspend {jobNumber} --task {taskSequence} --reason "Claimed by {staffCode} for Autotask work"
```

This prevents other engineers from accidentally picking up the same task.

### ③ Worker Phase 4 — read work item

The worker reads everything it needs from ediProd before starting design/coding:

```
edi workitem get {jobNumber}          # full WI details + acceptance criteria
edi cs get {jobNumber}                # for CS incident tickets
edi workflow list {jobNumber}         # workflow task breakdown
edi task list {jobNumber} --format json   # find taskId matching taskSequence
edi task notes read {taskId}          # ⚠️ MANDATORY: notes may contain human instructions
```

> Task notes are treated with the **same authority as the work item description**. Any instructions, constraints, or context left by a human or previous run in task notes are mandatory inputs to the design plan.

### ④ Worker progress notes

Throughout execution the worker appends timestamped progress notes:

```
edi task notes append {taskId} --content "[NTR] Started: 2026-04-10T05:00Z — planning phase"
edi task notes append {taskId} --content "[NTR] Code complete — building tests"
```

### ⑤ Finalize script — completion/failure note

`finalize-autotask-worker.ps1` always appends a final note (with deduplication guard):

```
edi --format jsonl task list {jobNumber}   # locate taskId by sequence number
edi task notes read {taskId}              # check if completion marker already exists
edi task notes append {taskId} --content "[NTR] Completed: 2026-04-10T06:00Z (Autotask, 1h 2m)<br>{summary}<br>PRs: {urls}"
```

### ⑥ Finalize script — INV report upload

For `INV` task type only, the finalize script uploads any `*report*.html` files to ediProd:

```
edi file upload {jobNumber} {workspace}/*report*.html --type INT
```

---

## 4. Worker Start Flow (Sequence)

```mermaid
sequenceDiagram
    actor Operator
    participant UI as Dashboard UI<br/>(browser)
    participant SRV as Dashboard Server<br/>(Node.js)
    participant STATE as temp/state.json
    participant START as start-autotask-worker.ps1
    participant LAUNCH as launch-autotask-worker.ps1
    participant WT as Windows Terminal
    participant AGENT as Worker Agent<br/>(Claude/Copilot)
    participant EDI as edi CLI

    Operator->>UI: Click "Start Now" on Startable card
    UI->>SRV: POST /api/queue {jobNumber, taskSequence, taskType, ...}
    SRV->>SRV: normalizeState()<br/>normalizeTaskSequence() → string key
    SRV->>SRV: Check: already running? already completed same seq?
    alt blocked (duplicate)
        SRV-->>UI: 409 / error response
    else OK to start
        SRV->>STATE: Append job to waitingQueue[]
        SRV-->>UI: 200 OK (queued)
        SRV->>START: pwsh -File start-autotask-worker.ps1<br/>-JobNumber -TaskSequence -TaskType ...
    end

    START->>STATE: Read config + existing workers
    START->>START: Create workspaces/WIxxxxxxxx<br/>Write prompt file to .autotask/
    START->>LAUNCH: Call launch-autotask-worker.ps1<br/>-Cli auto -JobNumber -WorkspacePath -PromptFile
    LAUNCH->>LAUNCH: Resolve CLI (auto → claude or copilot)
    LAUNCH->>WT: wt.exe new-tab --title "⚙️ WIxxxxxxxx TASK"<br/>-d workspacePath claude/copilot ...

    WT->>AGENT: Start agent in new terminal tab
    AGENT->>STATE: Write worker entry {jobNumber, taskSequence,<br/>status: "running", startedAt, lastHeartbeatAt}
    STATE-->>SRV: (next poll /api/state)
    SRV->>SRV: Move waitingQueue → workers bucket
    SRV-->>UI: GET /api/state → card moves to Running column

    loop Every ~30s
        AGENT->>STATE: Update lastHeartbeatAt
        EDI->>EDI: edi task suspend (keep SUS status)
    end

    AGENT->>EDI: edi task notes append (progress)
    AGENT->>AGENT: Execute task (build/test/PR/etc.)
```

---

## 5. Worker Lifecycle (State Machine)

```mermaid
stateDiagram-v2
    [*] --> Startable : edi CLI / PAVE poller discovers task

    Startable --> WaitingQueue : "Operator clicks Start Now<br/>(POST /api/queue)"

    WaitingQueue --> Running : "start script spawns agent;<br/>agent writes state.workers entry"

    Running --> Running : "heartbeat updates every ~30s"

    Running --> NeedsInput : "agent writes userInputRequest<br/>to state.json"

    NeedsInput --> Running : "operator submits input<br/>(POST /api/submit-input or Teams/email command)"

    Running --> Completed : "finalize-autotask-worker.ps1<br/>-Status done"

    Running --> Failed : "finalize-autotask-worker.ps1<br/>-Status failed<br/>OR worker process crashes / stale heartbeat"

    Completed --> [*] : "card visible in Completed column;<br/>notifications sent"

    Failed --> [*] : "card visible in Failed column;<br/>error notifications sent"

    Failed --> WaitingQueue : "Operator clicks Retry<br/>(POST /api/queue -Mode retry)"

    note right of Running
        state.workers[]
        jobNumber, taskSequence,
        workspacePath, startedAt,
        lastHeartbeatAt, status,
        phase, activity
    end note

    note right of Completed
        state.completedJobs[]
        completedAt, finalReportSummary,
        finalReportPath, lastEmailResult,
        prUrls, changes, testing
    end note
```

---

## 6. Worker Finalization Flow

```mermaid
flowchart TD
    A([Worker agent finishes task]) --> B{Status?}
    B -- done --> C[Call finalize-autotask-worker.ps1<br>-Status done -Summary ...]
    B -- failed --> D[Call finalize-autotask-worker.ps1<br>-Status failed -ErrorMessage ...]
    C --> E[Write .autotask/final-report.json<br>to workspace]
    D --> E
    E --> F[Read-AutotaskState from temp/state.json]
    F --> G[Find worker entry by jobNumber + taskSequence]
    G --> H{"Found in workers[]"}
    H -- yes --> I[Build completedJob/failedJob object<br> with summary, prUrls, changes,<br>testing, completedAt, duration]
    H -- no --> J[⚠️ Warn: worker not found;<br>create minimal record]
    I --> K["Append to completedJobs[] or failedJobs[]"]
    J --> K
    K --> L["Remove from workers[]"]
    L --> M[Write-AutotaskState → temp/state.json<br>with retry + timestamped backup]
    M --> N[edi task notes append<br> start+end timestamps, summary]
    N --> O{Email configured?<br>smtp_from + smtp_to set?}
    O -- yes --> P[send-email-notification.ps1<br>Graph API with OAuth2/SP token]
    O -- no --> Q[Skip email]
    P --> R{Teams chat enabled?<br>teams_chat_enabled: true}
    Q --> R
    R -- yes --> S[send-teams-notification.ps1<br>→ invoke-teams-chat.js<br>→ Graph /chats/sendMessage]
    R -- no --> T[Skip Teams]
    S --> U([Done — card moves to Completed/Failed column])
    T --> U

    style A fill:#4a9eff,color:#fff
    style U fill:#22c55e,color:#fff
    style J fill:#f59e0b,color:#fff
```

---

## 7. CLI Selection Logic

```mermaid
flowchart TD
    A([launch-autotask-worker.ps1<br>-Cli 'auto'/'claude'/'copilot']) --> B{Cli param value?}
    B -- claude --> Z1([Use: claude])
    B -- copilot --> Z2([Use: copilot])
    B -- auto --> C{Env var<br>COPILOT_CLI or<br>COPILOT_RUN_APP set?}
    C -- yes --> Z2
    C -- no --> D{Env var<br>CLAUDE_CODE or<br>CLAUDECODE set?}
    D -- yes --> Z1
    D -- no --> E{claude on PATH?}
    E -- yes, copilot NOT on PATH --> Z1
    E -- no --> F{copilot on PATH?}
    F -- yes, claude NOT on PATH --> Z2
    F -- both or neither --> Z1

    Z1 --> G["wt.exe new-tab<br>claude --system-prompt-file ...<br>--dangerously-skip-permissions<br>--plugin-dir autotask/"]
    Z2 --> H["wt.exe new-tab<br>pwsh -EncodedCommand<br>copilot --plugin-dir ... --allow-all<br>--no-ask-user -i prompt"]

    style Z1 fill:#f97316,color:#fff
    style Z2 fill:#6366f1,color:#fff
```

---

## 8. Startable Jobs Polling

### Prerequisites for BM OData

> ⚠️ **Critical dependency:** `query-bm-startable.ts` does **not** shell out to `edi`. It imports the auth layer **directly from the mcp-ediprod source**:
> ```ts
> import { createClient } from 'C:/BS/Git/GitHub/WiseTechGlobal/mcp-ediprod/src/apps/cli/auth.ts';
> ```
> This means **all three of the following must be true** or BM OData fetching will fail entirely and fall back to PAVE API (or return empty):
> 1. **`mcp-ediprod` repo cloned** at `C:/BS/Git/GitHub/WiseTechGlobal/mcp-ediprod`
> 2. **`edi login` completed** — cached credentials must be present on disk
> 3. **`bun` installed** — the script is run as `bun tools/query-bm-startable.ts` (TypeScript executed directly; node/npm cannot substitute)

```mermaid
flowchart TD
    subgraph prereqs["⚠️ Required on this machine"]
        P1["mcp-ediprod repo<br>cloned at hardcoded path<br>C:/BS/Git/.../mcp-ediprod"]
        P2["edi login completed<br>(cached credentials on disk)"]
        P3["bun installed<br>(runs .ts directly)"]
    end

    A([Dashboard Server polls every 30s]) --> B[get-autotask-startable-jobs.ps1]

    B --> E["bun tools/query-bm-startable.ts"]

    prereqs --> E

    E --> F["Imports createClient from<br>mcp-ediprod/src/apps/cli/auth.ts<br>(uses edi login cached credentials)<br>Queries ediProd OData directly:<br>· BMWorkflowTasks — filter by staff_code<br>  or capability temp/staff-capabilities-CODE.json<br>· P9Logs — check SRT event per task<br>· WorkItems — batch-resolve WI numbers"]

    F --> G{BM OData<br>returned results?}
    G -- yes --> H[Cache to artifacts-cache/bm-startable-cache.json]
    H --> I[Apply post-fetch filters]

    G -- no --> J{buffer_board_url<br>configured?}
    J -- yes --> K["PAVE API fallback<br>GET /api/staff/{code}/tasks<br>?board_id={id}&include_off_board_tasks=true"]
    K --> I
    J -- no --> L[Return empty with warning]
    L --> I

    E --> I

    I --> M["Filter: Drop excluded_task_types<br>SHV SH0 PRV MTG CHK CH0 CH1 CH2 CHG CH4"]

    M --> N["Write to state.startableJobs[]<br>Enrich jobUrl via jobGuid if board URL configured"]
    N --> O([Dashboard UI shows Startable column])

    style A fill:#4a9eff,color:#fff
    style O fill:#22c55e,color:#fff
    style E fill:#f59e0b,color:#fff
    style K fill:#8b5cf6,color:#fff
    style prereqs fill:#fee2e2,stroke:#ef4444
    style P1 fill:#fecaca,stroke:#ef4444
    style P2 fill:#fecaca,stroke:#ef4444
    style P3 fill:#fecaca,stroke:#ef4444
```

> **Note:** `edi workitem list` is **not** used in the startable-jobs fetch path. BM OData is always queried directly via `bun tools/query-bm-startable.ts`. The PAVE API is used as an automatic fallback only when BM OData returns no results.

---

## 9. Command Intake (Email & Teams)

```mermaid
sequenceDiagram
    participant OP as Operator
    participant INBOX as Email Inbox<br/>(Inbox/Autotask)
    participant TEAMS as Teams Chat
    participant PE as poll-autotask-email-input.ps1
    participant PT as poll-autotask-teams-input.ps1
    participant SRV as Dashboard Server
    participant STATE as temp/state.json

    Note over PE,PT: Pollers run every 30s (configurable)

    OP->>INBOX: Send email with subject "Autotask Command: ..."
    OP->>TEAMS: Send message in configured chat

    loop Email poll (30s)
        SRV->>PE: Trigger via /api/pollers
        PE->>INBOX: Graph API — read unread messages<br/>in Inbox/Autotask folder
        INBOX-->>PE: Message list with subjects + bodies
        PE->>PE: Parse command from subject/body<br/>Validate sender in allowed_senders<br/>Supports: start, queue, status, resume, retry,<br/>cleanup, reply, notes, setnotes (multi-line)
        PE->>STATE: Append to commandHistory[]
        PE->>SRV: Return processed commands
        SRV-->>STATE: Mark messages read (deltaLink cursor)
    end

    loop Teams poll (30s)
        SRV->>PT: Trigger via /api/pollers
        PT->>TEAMS: Graph API — list messages since lastCursor
        TEAMS-->>PT: New messages
        PT->>PT: Parse !command syntax<br/>Reject unknown senders
        PT->>STATE: Append to commandHistory[] + update teamsChat.cursor
        PT->>TEAMS: Send acknowledgement reply
    end

    SRV->>SRV: Process commandHistory entries<br/>(start, stop, status, input)
    SRV->>STATE: Execute commands + update state
```

---

## 10. Notification Flow (Email & Teams)

```mermaid
flowchart LR
    subgraph Trigger["Trigger (finalize script)"]
        FIN[finalize-autotask-worker.ps1]
    end

    subgraph Email["📧 Email Path"]
        EN[send-email-notification.ps1]
        subgraph Token["OAuth2 Token"]
            TC[".oauth-token-cache.json<br>(temp\\)"]
            SP["Service-Principal<br>client_credentials grant<br>(graph_sp_*)"]
            DC["Device-code flow<br>(interactive, first run)"]
        end
        GM["Graph API<br>POST /v1.0/me/sendMail"]
        MB["Recipient Mailbox<br>(smtp_to)"]
    end

    subgraph Teams["💬 Teams Path"]
        TN[send-teams-notification.ps1]
        TCH[teams-chat-common.ps1]
        JS["invoke-teams-chat.js<br>(Node helper)"]
        GC["Graph API<br>POST /v1.0/chats/{id}/messages"]
        TC2["Teams Chat<br>(teams_chat_id)"]
    end

    FIN --> EN
    FIN --> TN
    EN --> Token
    TC --> GM
    SP --> GM
    DC --> TC
    SP --> TC
    GM --> MB

    TN --> TCH
    TCH --> JS
    JS --> GC
    GC --> TC2

    style FIN fill:#4a9eff,color:#fff
    style MB fill:#22c55e,color:#fff
    style TC2 fill:#6366f1,color:#fff
```

---

## 11. state.json Data Model

```mermaid
erDiagram
    STATE {
        array waitingQueue
        array workers
        array completedJobs
        array failedJobs
        object autoStartPreferences
        array commandHistory
        object teamsChat
        array startableJobs
        string lastUpdated
    }

    JOB_ENTRY {
        string jobNumber
        string taskSequence
        string taskType
        string description
        string workspacePath
        string startedAt
        string status
        string phase
        string activity
        string lastHeartbeatAt
    }

    COMPLETED_JOB {
        string jobNumber
        string taskSequence
        string taskType
        string completedAt
        string finalReportSummary
        string finalReportPath
        string lastEmailResult
        array prUrls
        array changes
        array testing
        string duration
    }

    FAILED_JOB {
        string jobNumber
        string taskSequence
        string taskType
        string completedAt
        string errorMessage
        string lastEmailResult
        string logs
    }

    COMMAND_HISTORY {
        string id
        string source
        string command
        string body
        string receivedAt
        string status
        string result
    }

    TEAMS_CHAT {
        string cursor
        string conversationId
        string lastPolledAt
    }

    STARTABLE_JOB {
        string jobNumber
        string taskSequence
        string taskType
        string description
        string module
        string assignedTo
    }

    STATE ||--o{ JOB_ENTRY : "waitingQueue / workers"
    STATE ||--o{ COMPLETED_JOB : "completedJobs"
    STATE ||--o{ FAILED_JOB : "failedJobs"
    STATE ||--o{ COMMAND_HISTORY : "commandHistory"
    STATE ||--|| TEAMS_CHAT : "teamsChat"
    STATE ||--o{ STARTABLE_JOB : "startableJobs"
```

---

## 12. Configuration Layering

```mermaid
flowchart TD
    subgraph Files["Config Files (merged top-to-bottom, last wins)"]
        CY["config.yaml<br>(base defaults,<br>committed to repo)"]
        CL["config.local.yaml<br>(machine-specific overrides,<br>gitignored)"]
    end

    subgraph Keys["Key Settings"]
        K1["dashboard_port: 3210"]
        K2["worker_cli: auto | claude | copilot"]
        K3["board_name: (optional)<br>buffer_board_url"]
        K4["staff_code"]
        K5["smtp_from / smtp_to"]
        K6["teams_chat_id<br>teams_chat_enabled"]
        K7["graph_sp_tenant_id<br>graph_sp_client_id<br>graph_sp_client_secret<br>(optional — enables SP auth)"]
        K8["model_routing:<br>  design/code: opus<br>  test/review: sonnet<br>  default: sonnet"]
        K9["autonomy_mode:<br>suggestions-only | auto"]
        K10["excluded_task_types:<br>SHV SH0 PRV MTG CHK..."]
    end

    CY --> SRV["Dashboard Server<br>reads both files;<br>merges line-by-line<br>(last match wins)"]
    CL --> SRV
    SRV --> K1
    SRV --> K2
    SRV --> K3
    SRV --> K4
    SRV --> K5
    SRV --> K6
    SRV --> K7
    SRV --> K8
    SRV --> K9
    SRV --> K10

    style CY fill:#3b82f6,color:#fff
    style CL fill:#f59e0b,color:#fff
```

---

## 13. Key Files Reference

| Path | Role |
|---|---|
| `dashboard/server.js` | API server, state normalization, start-flow logic, bucket routing |
| `dashboard/index.html` | Kanban UI — `refreshState()`, `detectChanges()`, card rendering |
| `temp/state.json` | **Runtime state** — authoritative source for all buckets (gitignored) |
| `config.yaml` | Base config (committed) |
| `config.local.yaml` | Machine config overrides (gitignored) |
| `config.local.yaml.template` | Template for new installs |
| `tools/start-autotask-worker.ps1` | Worker bootstrap: creates workspace, writes prompt, calls launch |
| `tools/launch-autotask-worker.ps1` | Resolves CLI; opens `wt.exe` tab for Claude or Copilot |
| `tools/finalize-autotask-worker.ps1` | End-of-job: state update, edi notes, notifications, cleanup |
| `tools/autotask-state-common.ps1` | `Read-AutotaskState` / `Write-AutotaskState` with retries + backups |
| `tools/get-autotask-startable-jobs.ps1` | Fetches available tasks from edi CLI or PAVE board |
| `tools/send-email-notification.ps1` | Graph API email with OAuth2/SP, 3-retry + exponential backoff |
| `tools/send-teams-notification.ps1` | Teams direct-chat via Graph (webhook path removed) |
| `tools/invoke-teams-chat.js` | Node.js helper for Graph `/chats/{id}/messages` |
| `tools/teams-chat-common.ps1` | Shared Teams auth + message helpers |
| `tools/poll-autotask-email-input.ps1` | Polls Inbox/Autotask for operator commands |
| `tools/poll-autotask-teams-input.ps1` | Polls Teams chat for operator commands |
| `agents/task-worker.md` | System prompt / instructions given to every worker agent |
| `setup/install.ps1` | Interactive installer — requires **pwsh 7+** |
| `docs/edi-cli.md` | edi CLI quick reference + install steps |

---

## 14. Failure Modes & Debugging

```mermaid
flowchart TD
    A[Symptom] --> B{Which symptom?}

    B -- "Card stuck in Waiting Queue<br/>after Start Now" --> C["Check temp/state.json:<br/>- waitingQueue entry present?<br/>- Matching workers entry?<br/>- taskSequence stored as string?<br/>Previous fix: numeric taskSequence<br/>now coerced to string in<br/>normalizeTaskSequence"]

    B -- "No completed/failed emails<br/>(only start emails visible)" --> D["Possible causes:<br/>1. finalize script never ran<br/>   (worker crashed)<br/>2. OAuth token expired<br/>   (device-code flow)<br/>3. smtp_from/smtp_to not set<br/>Check: lastEmailResult field<br/>in completedJobs[]/failedJobs[]<br/>Fix: use SP credentials in<br/>config.local.yaml"]

    B -- "Teams notifications not working" --> E["Check:<br/>- teams_chat_enabled: true in config<br/>- teams_chat_id configured<br/>- invoke-teams-chat.js present<br/>  in tools/<br/>- Graph token valid"]

    B -- "Worker starts but never registers<br>in Running column" --> F["Check:<br>- workspace created under workspaces/?<br>- Agent tab opened in wt.exe?<br>- state.workers[] entry written?<br>- Heartbeat updating lastHeartbeatAt?<br>Default stale grace: 30 min"]

    B -- "State write errors / data loss" --> G["Write-AutotaskState retries 3x;<br>Timestamped backups in temp/<br>Check temp/*.backup-*.json<br>for last known good state"]

    B -- "edi commands fail in worker" --> H["Check:<br>- edi --version works in worker tab<br>- GLOW_USERNAME/GLOW_PASSWORD<br>  env vars set (User scope)<br>- Run edi login to refresh<br>- Copilot workers auto-copy<br>  User env vars at launch"]

    B -- "Ephemeral file CI failure" --> I["Artifact/token committed<br>outside temp/<br>Run: tools/check-ephemeral-files.ps1<br>Move file to temp/ and recommit"]

    style A fill:#ef4444,color:#fff
```

---

## 15. Operational Rules

> **Hard rules — no exceptions.**

| Rule | Reason |
|---|---|
| ✅ `edi task suspend` — permitted | Puts task in SUS; safe to use freely |
| ✅ `edi task claim` → immediately `edi task suspend` | Prevents race conditions with other engineers |
| ✅ `edi task notes append` | Safe audit trail for start/end times |
| ❌ `edi task start` — **NEVER** | Sets WRK status; causes race conditions |
| ❌ `edi task complete` — **NEVER** | Sets CLS status; humans close tasks manually |
| ✅ All temp files go in `temp/` | gitignored; CI enforces via `check-ephemeral-files.ps1` |
| ✅ `pwsh` 7+ required | `setup/install.ps1` enforced with `#Requires -Version 7.0` |
