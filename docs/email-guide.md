# Autotask Email Integration Guide

## What email is used for

Autotask uses email for two different inbound flows:

1. **Worker replies** when a worker asks you a question
2. **Structured command emails** when you want to control Autotask asynchronously

Email is asynchronous. It depends on the Mail Poller, Microsoft Graph access, and the configured mail folder.

## Setup

### SMTP and outbound mail

Configure your local mail settings in `config.local.yaml`:

~~~yaml
smtp_server: "smtp.office365.com"
smtp_from: "your.email@example.com"
smtp_to: "your.email@example.com"
~~~

### Mail polling

Autotask reads inbound mail through Microsoft Graph.

Important settings:

~~~yaml
email_polling_interval_ms: 30000
email_poll_folder_path: "Inbox/Autotask"
email_command_intake_enabled: false
email_command_send_replies: true
email_command_subject_prefix: "Autotask Command"
email_command_allowed_senders: ""
~~~

Notes:

- The shared default folder is `Inbox/Autotask`
- You can override the folder locally if you prefer a different mailbox path
- Command emails are ignored unless `email_command_intake_enabled: true`

## Worker reply flow

When a worker needs your input, Autotask sends a message with a subject similar to:

~~~text
Autotask Input Needed: WI00992034 [request-guid]
~~~

To answer:

1. Reply to the email
2. Keep the subject unchanged
3. Put your answer at the top of the reply

Autotask matches the request ID in the subject and routes the reply back to the worker automatically.

If the reply is not picked up:

- check the Mail Poller in the dashboard
- confirm Graph auth is still valid
- confirm Autotask is polling the folder where the reply landed

## Structured command emails

Structured command emails let you control Autotask without opening the local dashboard.

### Requirements

Autotask accepts a command email only when all of these are true:

1. `email_command_intake_enabled: true`
2. the sender is allowlisted by `email_command_allowed_senders` (or falls back to `smtp_to` when that list is blank)
3. the subject starts with `email_command_subject_prefix`
4. the first non-empty line of the email body (or the text after the prefix in the subject line) is the command. For multi-line commands such as `setnotes`, all subsequent body lines are treated as the content.

### Supported commands

Current structured email commands are:

| Command | Purpose |
| ------- | ------- |
| `help` | Show supported email/manual command syntax |
| `status [WI] [--task <seq>]` | Show overall status or one job |
| `queue <WI> [--task <seq>] [type] [desc]` | Add a job to the waiting queue |
| `start <WI> [--task <seq>]` | Queue and launch immediately |
| `resume <WI> [--task <seq>]` | Resume a paused worker |
| `retry <WI> [--task <seq>]` | Retry a failed worker |
| `cleanup <WI> [--task <seq>]` | Remove the job from Autotask state and keep the workspace |
| `reply <WI> <message>` | Answer a worker waiting for input |
| `answer <WI> <message>` | Alias for `reply` |
| `notes <WI> --task <seq>` | Read task notes; reply contains the current notes |
| `setnotes <WI> --task <seq> <content>` | Overwrite task notes (multi-line content supported) |

### Not supported by email command intake

These commands are dashboard-only:

- `never-auto <WI> --task <seq>`
- `allow-auto <WI> --task <seq>`

Use the dashboard command bar for those.

### Multi-line setnotes via email

`setnotes` content can span multiple lines. There are two supported formats:

**Option A — command in subject, content in body:**

Subject:
~~~text
Autotask Command: setnotes WI00975129 --task 423
~~~

Body (all lines become the note content):
~~~text
Line 1 of the note
Line 2

Still part of the note after the blank line
~~~

**Option B — command on body first line, content on remaining lines:**

Subject:
~~~text
Autotask Command
~~~

Body:
~~~text
setnotes WI00975129 --task 423
Line 1 of the note
Line 2

Still part of the note after the blank line
~~~

In both cases blank lines and internal whitespace within the content are preserved. Leading blank lines at the very start of the content are trimmed.

### Example command emails

Subject:

~~~text
Autotask Command
~~~

Body first line examples:

~~~text
status
status WI00975129 --task 423
queue WI00975129
queue WI00975129 --task 423 CDF Update calc path
start WI00975129 --task 423
resume WI00975129 --task 423
retry WI00975129
cleanup WI00975129 --task 423
reply WI00975129 Use option A
answer WI00975129 Proceed with the existing branch
notes WI00975129 --task 423
~~~

For `setnotes`, see the multi-line format above.

If `email_command_send_replies: true`, Autotask replies with a success or failure result.

## What command emails actually do

- `start` launches a worker immediately
- `resume` relaunches a paused worker from its retained workspace
- `retry` relaunches a failed worker
- `cleanup` removes the job record from Autotask state and leaves the workspace intact

Because workers launch in Windows Terminal tabs, the machine still needs to be awake and logged in.

## Outbound email notifications

Autotask can send HTML-formatted email for:

- task started
- task completed
- task failed
- user input needed
- daily summary

These emails may include:

- job number and title
- Session Broker HTTPS job link when available
- PR links
- worker summary
- current phase or failure details
- response instructions for user-input requests

## Operational notes

- Email is slower than the dashboard because it is poll-based
- Teams is a better fit for outbound visibility; email is the better fit for asynchronous replies
- For interactive local control, the dashboard command bar is still the fastest option

## Related documents

- `docs/user-guide.md`
- `docs/teams-guide.md`
- `docs/troubleshooting.md`
