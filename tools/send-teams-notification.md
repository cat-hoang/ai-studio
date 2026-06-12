---
name: send-teams-notification
description: Sends Teams notifications via Incoming Webhook using Adaptive Card templates. Supports task lifecycle events and daily summaries.
parameters:
  templateName:
    type: string
    required: true
    enum: ["task-started", "task-completed", "task-failed", "daily-summary", "queue-added"]
    description: The notification template to use.
  data:
    type: object
    required: true
    description: >
      Template-specific data. Fields vary by template:
      - task-started: jobNumber, taskType, description, zone, workspacePath
      - task-completed: jobNumber, prUrls (array), duration
      - task-failed: jobNumber, error, logs (string)
      - daily-summary: workers (array of {name, zone, status, jobNumber, lastActivity})
      - queue-added: jobNumber, taskType, description, source (manual|teams|email)
---

# Send Teams Notification

Sends formatted Adaptive Card messages to a Microsoft Teams channel via an Incoming Webhook connector.

## Steps

### 1. Read webhook URL from config

```powershell
$autotaskRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $autotaskRoot "config.local.yaml"
$configContent = Get-Content $configPath -Raw

# Extract teams_webhook_url from YAML (simple key: value parsing)
if ($configContent -match 'teams_webhook_url:\s*(.+)') {
    $webhookUrl = $Matches[1].Trim().Trim('"').Trim("'")
} else {
    throw "teams_webhook_url not found in config.local.yaml"
}
```

### 2. Build Adaptive Card payload by template

Each template produces an Adaptive Card JSON body with appropriate accent color, title, and content blocks.

#### task-started (green accent)

```powershell
$card = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"
            version = "1.4"
            msteams = @{ width = "Full" }
            body = @(
                @{
                    type = "Container"
                    style = "good"  # green accent
                    items = @(
                        @{ type = "TextBlock"; text = "Task Started"; weight = "Bolder"; size = "Large" }
                    )
                }
                @{
                    type = "FactSet"
                    facts = @(
                        @{ title = "Job"; value = $data.jobNumber }
                        @{ title = "Type"; value = $data.taskType }
                        @{ title = "Zone"; value = $data.zone }
                        @{ title = "Description"; value = $data.description }
                        @{ title = "Workspace"; value = $data.workspacePath }
                    )
                }
            )
        }
    })
}
```

#### task-completed (blue accent)

```powershell
$prLinks = ($data.prUrls | ForEach-Object { "- [$_]($_)" }) -join "`n"
$card = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"
            version = "1.4"
            msteams = @{ width = "Full" }
            body = @(
                @{
                    type = "Container"
                    style = "accent"  # blue accent
                    items = @(
                        @{ type = "TextBlock"; text = "Task Completed"; weight = "Bolder"; size = "Large" }
                    )
                }
                @{
                    type = "FactSet"
                    facts = @(
                        @{ title = "Job"; value = $data.jobNumber }
                        @{ title = "Duration"; value = $data.duration }
                    )
                }
                @{
                    type = "TextBlock"
                    text = "**Pull Requests:**`n$prLinks"
                    wrap = $true
                }
            )
        }
    })
}
```

#### task-failed (red accent)

```powershell
$card = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"
            version = "1.4"
            msteams = @{ width = "Full" }
            body = @(
                @{
                    type = "Container"
                    style = "attention"  # red accent
                    items = @(
                        @{ type = "TextBlock"; text = "Task Failed"; weight = "Bolder"; size = "Large"; color = "Attention" }
                    )
                }
                @{
                    type = "FactSet"
                    facts = @(
                        @{ title = "Job"; value = $data.jobNumber }
                        @{ title = "Error"; value = $data.error }
                    )
                }
                @{
                    type = "TextBlock"
                    text = "``````$($data.logs)``````"
                    wrap = $true
                    fontType = "Monospace"
                }
            )
        }
    })
}
```

#### daily-summary (summary table)

```powershell
$rows = $data.workers | ForEach-Object {
    @{
        type = "TableRow"
        cells = @(
            @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = $_.name }) }
            @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = $_.zone }) }
            @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = $_.status }) }
            @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = $_.jobNumber }) }
            @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = $_.lastActivity }) }
        )
    }
}

$card = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"
            version = "1.5"
            msteams = @{ width = "Full" }
            body = @(
                @{ type = "TextBlock"; text = "Autotask Daily Summary"; weight = "Bolder"; size = "Large" }
                @{
                    type = "Table"
                    columns = @(
                        @{ width = 1 }, @{ width = 1 }, @{ width = 1 }, @{ width = 1 }, @{ width = 2 }
                    )
                    rows = @(
                        @{
                            type = "TableRow"
                            style = "accent"
                            cells = @(
                                @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = "Worker"; weight = "Bolder" }) }
                                @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = "Zone"; weight = "Bolder" }) }
                                @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = "Status"; weight = "Bolder" }) }
                                @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = "Job"; weight = "Bolder" }) }
                                @{ type = "TableCell"; items = @(@{ type = "TextBlock"; text = "Last Activity"; weight = "Bolder" }) }
                            )
                        }
                    ) + $rows
                }
            )
        }
    })
}
```

#### queue-added (yellow accent)

```powershell
$card = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"
            version = "1.4"
            msteams = @{ width = "Full" }
            body = @(
                @{
                    type = "Container"
                    style = "warning"  # yellow accent
                    items = @(
                        @{ type = "TextBlock"; text = "Job Queued"; weight = "Bolder"; size = "Large" }
                    )
                }
                @{
                    type = "FactSet"
                    facts = @(
                        @{ title = "Job"; value = $data.jobNumber }
                        @{ title = "Type"; value = $data.taskType }
                        @{ title = "Description"; value = $data.description }
                        @{ title = "Source"; value = $data.source }
                    )
                }
            )
        }
    })
}
```

### 3. POST to webhook

```powershell
$jsonBody = $card | ConvertTo-Json -Depth 20 -Compress

try {
    $response = Invoke-RestMethod -Uri $webhookUrl -Method POST -Body $jsonBody -ContentType "application/json"
    Write-Host "Teams notification sent successfully ($templateName)"
    [PSCustomObject]@{ success = $true; template = $templateName }
} catch {
    Write-Warning "Failed to send Teams notification: $_"
    [PSCustomObject]@{ success = $false; template = $templateName; error = $_.Exception.Message }
}
```

### 4. Return result

Returns an object with:
- **success** (boolean): Whether the POST succeeded.
- **template** (string): The template name that was used.
- **error** (string, optional): Error message if the POST failed.

## Error Handling

- If `config.local.yaml` is missing or does not contain `teams_webhook_url`, throw immediately.
- If the webhook POST returns a non-success status, catch the error and return a failure result rather than throwing, so the caller can decide how to handle it.
- All card payloads are serialized with `-Depth 20` to avoid truncation of nested structures.

