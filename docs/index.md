# Autotask Documentation Index

Welcome — this directory collects Autotask documentation.

## Guides

| Document | What it covers |
| -------- | -------------- |
| [`user-guide.md`](user-guide.md) | Setup, daily workflow, dashboard, command channels, autonomy, configuration reference |
| [`teams-guide.md`](teams-guide.md) | Teams direct chat setup, notifications, sending commands from Teams |
| [`email-guide.md`](email-guide.md) | Email worker replies, structured command emails, `notes`/`setnotes` via email |
| [`notifications.md`](notifications.md) | Notification events, content fields, email delivery, service principal auth |
| [`troubleshooting.md`](troubleshooting.md) | Common problems and fixes: VPN, dashboard, pollers, workers, email, Teams |
| [`architecture-overview.md`](architecture-overview.md) | Component map, sequence diagrams, state machine, startable polling flow |

## Notes

- Temporary files: All ephemeral files must be stored under `temp/` (gitignored).
- Adapter-specific guidance: `CLAUDE.md` (Claude Code) and `AGENTS.md` (Copilot CLI).
