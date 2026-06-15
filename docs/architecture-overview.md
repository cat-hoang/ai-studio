# Autotask System Architecture

> End-to-end reference for the Autotask multi-agent orchestrator. Covers components, data flows, worker lifecycle, notifications, and integrations.

---

## Table of Contents

1. [System Components](#1-system-components)
2. [Component Relationships](#2-component-relationships)
3. [Issue Source Integration](#3-issue-source-integration)
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
| **Email Notifier** | PowerShell + Microsoft Graph | Sends start/complete/failed reports to configured mailbox |
| **Teams Notifier** | PowerShell + Graph + JS helper | Sends messages to configured Teams chat |
| **Poller: Startable Jobs** | PowerShell (`get-autotask-startable-jobs.ps1`) | Queries the configured issue source (GitHub Issues) for available tasks every 30 s |
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
        GH[GitHub Issues API]
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
    PJ --> GH
    EM --> GRAPH
    TM --> GRAPH
    GRAPH --> TEAMS
    WA --> GH
    WA --> CRIKEY
```

---

## 3. Issue Source Integration

Autotask interacts with the configured issue source (GitHub Issues) through the
`issue-source` adapter at each major phase of the pipeline:

| Phase | Adapter touchpoint |
|-------|--------------------|
| **Startable jobs fetch** | `fetchStartable` — `get-autotask-startable-jobs.ps1` → `query-issue-source.ts` (github-issues adapter) lists open issues filtered by label/assignee |
| **Worker claim** | `claim` — marks the issue as in-progress (status label) when work begins |
| **Worker read** | the worker reads the issue title, body, and comments for task details and any human instructions |
| **Progress / completion notes** | `appendNote` — posts progress and final result (summary + PR links) as issue comments |
| **Status updates** | `updateStatus` — moves the issue through its lifecycle status labels |

> Issue comments are treated with the **same authority as the issue description**. Any instructions, constraints, or context left by a human or previous run are mandatory inputs to the design plan.

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
    participant GH as GitHub Issues

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
    end

    AGENT->>GH: Post progress comment to the issue
    AGENT->>AGENT: Execute task (build/test/PR/etc.)
```

---

## 5. Worker Lifecycle (State Machine)

```mermaid
stateDiagram-v2
    [*] --> Startable : startable poller discovers task

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
    M --> N[Append final note to the issue<br> start+end timestamps, summary]
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

### Prerequisites for the GitHub Issues fetch

> ⚠️ **Required config:** the startable poller fetches through `tools/query-issue-source.ts` (the `github-issues` adapter). For it to return results:
> 1. **`issue_source.github_issues.repo`** set to `owner/repo`
> 2. **GitHub token** present in the configured env var (`token_env`, default `GITHUB_TOKEN`)
> 3. **`bun` installed** — the script is run as `bun tools/query-issue-source.ts`

```mermaid
flowchart TD
    A([Dashboard Server polls every 30s]) --> B[get-autotask-startable-jobs.ps1]

    B --> E["bun tools/query-issue-source.ts"]

    E --> F["Loads the github-issues adapter<br>Queries the GitHub Issues API:<br>· GET /repos/{owner}/{repo}/issues<br>· filter by label + assignee<br>· excludes pull requests"]

    F --> I[Apply post-fetch filters]

    I --> M["Filter: drop excluded_task_types"]

    M --> N["Write to state.startableJobs[]"]
    N --> O([Dashboard UI shows Startable column])

    style A fill:#4a9eff,color:#fff
    style O fill:#22c55e,color:#fff
    style E fill:#f59e0b,color:#fff
```

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
        K3["issue_source.github_issues<br>(repo, labels, assignee, token_env)"]
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
| `tools/finalize-autotask-worker.ps1` | End-of-job: state update, issue notes, notifications, cleanup |
| `tools/autotask-state-common.ps1` | `Read-AutotaskState` / `Write-AutotaskState` with retries + backups |
| `tools/get-autotask-startable-jobs.ps1` | Fetches available tasks from the configured issue source (GitHub Issues) |
| `tools/send-email-notification.ps1` | Graph API email with OAuth2/SP, 3-retry + exponential backoff |
| `tools/send-teams-notification.ps1` | Teams direct-chat via Graph (webhook path removed) |
| `tools/invoke-teams-chat.js` | Node.js helper for Graph `/chats/{id}/messages` |
| `tools/teams-chat-common.ps1` | Shared Teams auth + message helpers |
| `tools/poll-autotask-email-input.ps1` | Polls Inbox/Autotask for operator commands |
| `tools/poll-autotask-teams-input.ps1` | Polls Teams chat for operator commands |
| `agents/task-worker.md` | System prompt / instructions given to every worker agent |
| `setup/install.ps1` | Interactive installer — requires **pwsh 7+** |

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

    B -- "GitHub API calls fail in worker" --> H["Check:<br>- GITHUB_TOKEN set in worker env<br>- token scopes + not expired<br>- repo/owner correct<br>- network / VPN reachable"]

    B -- "Ephemeral file CI failure" --> I["Artifact/token committed<br>outside temp/<br>Run: tools/check-ephemeral-files.ps1<br>Move file to temp/ and recommit"]

    style A fill:#ef4444,color:#fff
```

---

## 15. Operational Rules

> **Hard rules — no exceptions.**

| Rule | Reason |
|---|---|
| ❌ Never close issues from automation | Humans close issues manually after review |
| ✅ All temp files go in `temp/` | gitignored; CI enforces via `check-ephemeral-files.ps1` |
| ✅ `pwsh` 7+ required | `setup/install.ps1` enforced with `#Requires -Version 7.0` |
