# EDI CLI (edi) — Quick reference for Ratatosk

This document records the non-interactive edi CLI usage patterns and Ratatosk-specific rules.

Important rules (follow these exactly):
- NEVER run `edi task start` or `edi task complete` from automation or Ratatosk workers — these change EDI status to WRK/CLS and cause race conditions.
- If you must claim a task, immediately suspend it to avoid blocking others: claim → suspend → record notes.

Recommended sequence when interacting with edi for a work item (manual operator):
1. Claim (if required):
   edi task claim <WORKITEM_NUMBER> --task <TASK_SEQUENCE>

2. Immediately suspend to prevent accidental WRK state:
   edi task suspend <WORKITEM_NUMBER> --task <TASK_SEQUENCE> --reason "Claimed by <staff_code> for Ratatosk work"

3. Record start timestamps or context in the task notes (audit trail):
   edi task notes append <WORKITEM_NUMBER> --task <TASK_SEQUENCE> --note "Work claimed and suspended by <staff_code> at 2026-04-10T02:00:00Z"

4. Let Ratatosk or the worker run work and finalize via `tools/finalize-ratatosk-worker.ps1` so Ratatosk updates state.json and sends notifications. Do NOT change EDI status to WRK from outside Ratatosk.

If you need to record intermittent updates, use `edi task notes append` with short messages and timestamps.

Example: claim-and-suspend (replace placeholders):

```
edi task claim WI01056353 --task 243
edi task suspend WI01056353 --task 243 --reason "Claimed by NTR - suspended before work"
edi task notes append WI01056353 --task 243 --note "Preparing workspace; Ratatosk start requested via dashboard"
```

Troubleshooting and tips:
- Verify current task state with `edi task status <WORKITEM_NUMBER> --task <TASK_SEQUENCE>` before claiming.
- If unsure, prefer `edi task suspend` and notes over `edi task start`.
- Ratatosk authoritative state lives in `temp\state.json` (Ratatosk manages worker lifecycle). Use the dashboard or Ratatosk commands to start/resume workers.

References:
- AGENTS.md — ediProd hard rules and discipline
- setup\README.md — prerequisites and first-run setup
- tools\finalize-ratatosk-worker.ps1 — how Ratatosk finalizes and reports back to state.json


Quick steps to install the edi CLI (used by Ratatosk):

1. Install Bun (preferred) from https://bun.sh (or ensure Node/npm is available).

2. Clone the mcp-ediprod repo:

```
git clone https://github.com/WiseTechGlobal/mcp-ediprod.git
cd mcp-ediprod
```

3. Install & link the CLI:

```
bun install
bun link
```

(bun link creates a global edi command - if it doesn't work, create an edi.bat shim that runs `bun run edi %*` or use `npx edi` instead of `edi`.)

4. Verify:

```
edi --version
edi workitem list --product ENT --limit 1
```

5. Authenticate: run `edi login` and follow prompts (tokens cached on disk). You may need to re-authenticate every 24 hours.
Another option is to save GLOW_USERNAME (firstname.lastname) and GLOW_PASSWORD as environment variables. This option is less secure and not recommended for shared machines but it works every time without interactive login.

## mcp-ediprod as a library dependency (BM OData)

> ⚠️ **Beyond the `edi` CLI command**, Ratatosk also imports mcp-ediprod's auth layer **directly as a TypeScript library** in `tools/query-bm-startable.ts`:
>
> ```ts
> import { createClient } from 'C:/BS/Git/GitHub/WiseTechGlobal/mcp-ediprod/src/apps/cli/auth.ts';
> ```
>
> This is the primary mechanism for fetching startable jobs (BM OData). It requires:
> - `mcp-ediprod` cloned at the **exact path** `C:/BS/Git/GitHub/WiseTechGlobal/mcp-ediprod`
> - `edi login` completed so credentials are cached on disk
> - `bun` installed — the script is executed as `bun tools/query-bm-startable.ts` directly
>
> If any of these conditions are not met, startable job fetching silently falls back to the PAVE API or returns empty.

