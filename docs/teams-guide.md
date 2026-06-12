# Autotask Teams Integration Guide

## Overview

Autotask now supports **two** Teams delivery modes:

1. **Incoming Webhook** for Adaptive Card notifications
2. **Direct Teams chat** via `teams-api` for chat messages and optional command polling

Webhook mode is still the default legacy path. Direct chat is opt-in through `config.local.yaml`.

## Choosing a Teams mode

| Mode | What it does | What it cannot do |
| --- | --- | --- |
| Webhook | Sends Adaptive Card notifications into a Teams channel | Cannot read messages or replies |
| Direct chat | Sends Autotask messages into a 1:1 chat, self-chat, or specific conversation; can poll that chat for `autotask:` commands | Depends on local `teams-api` auth and cached Teams tokens |

When `teams_chat_enabled: true`, Autotask sends Teams notifications through the **direct chat** path. When it is `false`, Autotask falls back to `teams_webhook_url` if that webhook is configured.

## Direct Teams chat setup

Add these keys to `config.local.yaml`:

~~~yaml
teams_chat_enabled: true
teams_chat_email: "your.name@wisetechglobal.com"
teams_chat_target_mode: "self"
teams_chat_target: ""
teams_chat_command_polling_enabled: true
teams_chat_command_send_replies: true
teams_chat_command_prefix: "autotask:"
teams_chat_polling_interval_ms: 30000
~~~

### `teams_chat_target_mode`

Supported values:

- `self` — your self-chat
- `person` — a 1:1 chat with the person named in `teams_chat_target`
- `chat` — a group chat or conversation matched by topic/name
- `conversation-id` — use the exact Teams conversation ID from `teams_chat_target`

### `teams_chat_target`

`teams_chat_target` is required for:

- `person`
- `chat`
- `conversation-id`

It is ignored for `self`.

## Note: Incoming webhooks deprecated

Incoming webhook support (Adaptive Card channel notifications) is deprecated and has been removed. Configure direct Teams chat instead by enabling `teams_chat_enabled: true` and setting the appropriate `teams_chat_target_mode` / `teams_chat_target` in `config.local.yaml`.

## Notification behavior

Direct Teams chat sends plain Autotask messages prefixed with:

~~~text
[Autotask]
~~~

That prefix is important because the Teams command poller ignores Autotask-generated chat messages to avoid command loops.

Notification templates supported in both Teams modes:

- task started (includes work item title and task number)
- task completed (includes work item title and task description)
- task failed
- user input needed
- queue added
- daily summary (includes startable items with Never Auto badges and per-item start commands)

## Sending commands from Teams

When `teams_chat_command_polling_enabled: true`, Autotask polls the configured chat and executes messages that begin with the configured prefix.

Default prefix:

~~~text
autotask:
~~~

Examples:

~~~text
autotask: status
autotask: start WI00975129 --task 423
autotask: queue WI00975129 --task 423 DEV Investigate regression
autotask: retry WI00975129 --task 423
autotask: cleanup WI00975129 --task 423
autotask: reply WI00975129 Use option A
autotask: notes WI00975129 --task 423
~~~

For `setnotes`, put the command on the first line and the note content on the following lines in the same Teams message:

~~~text
autotask: setnotes WI00975129 --task 423
Line 1 of your note

Line 3 after a blank line
~~~

Autotask can optionally acknowledge those commands back into the same chat with `[Autotask]` messages when:

~~~yaml
teams_chat_command_send_replies: true
~~~

Direct Teams commands currently support the same command subset as the email command path, plus `notes` and `setnotes`. `never-auto` / `allow-auto` remain dashboard-only.

## Worker replies through Teams

There is no special reply-only transport. Instead, when a worker asks for clarification, answer it through the normal Teams command path:

~~~text
autotask: reply WI00975129 Use option A
~~~

or:

~~~text
autotask: answer WI00975129 Use option A
~~~

This reuses the existing Autotask command parser and reply plumbing.

## Dashboard behavior

When Teams direct chat is configured, the dashboard can surface a **Teams Poller** card alongside the Mail and Startable pollers.

The card shows:

- poll interval
- last attempt / last success
- warnings or last error
- latest poll outcome
- a **Revive** button

If direct chat is configured but command polling is disabled, the Teams Poller card shows **Disabled** with the reason.

## Auth and operational notes

Autotask uses the `teams-api` package for direct chat. Practical implications:

- auth is local to your machine
- first use may require an interactive Teams login
- cached Teams tokens can expire, so the next direct-chat operation may need another login
- this path is more convenient than webhook-plus-email, but less battle-tested than the Graph mail flow

For unattended operation, keep email available as a fallback even if you mainly operate through Teams chat.

## Troubleshooting

### Teams notification did not arrive

1. If `teams_chat_enabled: true`, confirm the direct-chat target settings are valid
2. If `teams_chat_enabled: false`, verify `teams_webhook_url`
3. Check the dashboard poller card or server logs for the exact error
4. If direct chat was using an expired token, retry after re-authenticating Teams

### Teams command did nothing

1. Confirm `teams_chat_command_polling_enabled: true`
2. Confirm the message starts with the configured prefix such as `autotask:`
3. Confirm the dashboard server is running
4. Check the **Teams Poller** card for the last poll result
5. If acknowledgements are enabled, look for a `[Autotask] Command failed ...` response

### Why are Autotask's own messages not reprocessed as commands?

Because Autotask only processes messages that start with the command prefix, and its own outbound chat messages start with `[Autotask]`.

## Related documents

- `docs/user-guide.md`
- `docs/email-guide.md`
- `docs/troubleshooting.md`
