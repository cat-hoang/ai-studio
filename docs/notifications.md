# Ratatosk Notifications and Email Delivery

This document explains how Ratatosk sends notifications and recent repository changes made to aid diagnosis and reliability.

## Notification events

Ratatosk sends notifications for these events:

| Event | Sent by | Channels |
| ----- | ------- | -------- |
| Task started | `start-ratatosk-worker.ps1` | Email, Teams |
| Task completed | `finalize-ratatosk-worker.ps1` | Email, Teams |
| Task failed | `finalize-ratatosk-worker.ps1` | Email, Teams |
| User input needed | `finalize-ratatosk-worker.ps1` | Email, Teams |
| Daily summary / status report | `/ratatosk-status` or on-demand | Email, Teams |

## Notification content

### Task started

- Work item number and title (e.g. `WI00992034 · [UCG] Create new Mappings tab`)
- Task number and type
- Task description
- Timestamp

### Task completed

- Work item number and title
- Task type and description
- Duration
- Worker summary (brief description of work done)
- PR links when available

### Status report

- Counts: startable, queue, workers, completed, failed
- Per-item detail for startable tasks including:
  - Task number and type
  - Work item title
  - 🚫 badge when the task has Never Auto set
  - Copyable `ratatosk: start WI... --task N` command

## Implementation notes

- "Task Started" notifications are sent by `start-ratatosk-worker.ps1` when a worker launches.
- "Task Completed" / failure notifications are sent by `finalize-ratatosk-worker.ps1` when finalize completes.
- Finalize records the result of the email send in `state.json` on the completed/failed job object under `lastEmailResult` for easier auditing.
- Start script was relaxed to avoid blocking starts when a completed job exists for a different taskSequence.
- OAuth token cache `.oauth-token-cache.json` must live under `temp\` (moved there if present).
- Email sender now supports Microsoft Graph client-credentials (service principal) and retries on transient failures.

## Service principal (recommended)

To avoid device-code expiry and interactive auth, configure a service principal and add the following keys to `config.local.yaml` (do not commit secrets):

~~~yaml
graph_sp_tenant_id: "<tenant-id>"
graph_sp_client_id: "<client-id>"
graph_sp_client_secret: "<client-secret>"
~~~

When present, `send-email-notification.ps1` uses the OAuth2 client_credentials flow to request tokens with scope `https://graph.microsoft.com/.default`.
Secrets are never written to the repository and should be stored only in `config.local.yaml` or a secrets manager.

## Temporary files

All temporary files (tokens, transient outputs) must be placed in the `temp\` directory. `temp\` is gitignored.

## Troubleshooting

- If you only see "Started" notifications, check `state.json` for `finalReportedAt` and `lastEmailResult` on completed jobs.
- If email sending failed, `lastEmailResult` will contain the send response object or error for diagnostics.
- Device-code logs are written to `temp\device-code.log` with the user code when interactive auth is used.

