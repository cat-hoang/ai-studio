param(
    [Parameter(Mandatory)]
    [string]$JsonPayload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-config-common.ps1')
. (Join-Path $PSScriptRoot 'teams-chat-common.ps1')

$data = $JsonPayload | ConvertFrom-Json
$templateName = [string]$data.templateName
$tplData = $data.data

$ratatoskRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $ratatoskRoot 'temp\state.json'
$linkCommonPath = Join-Path $PSScriptRoot 'ratatosk-ediprod-link-common.ps1'
if (-not (Test-Path -LiteralPath $linkCommonPath)) {
    throw "Shared ediProd link helper not found: $linkCommonPath"
}
. $linkCommonPath

function Get-NotificationValue {
    param(
        [object]$Object,
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Default = ''
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object.PSObject.Properties[$Name]) {
        $value = $Object.$Name
        if ($null -ne $value) {
            return [string]$value
        }
    }

    return $Default
}

function Get-NotificationArray {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }

        return @($Value)
    }

    return @($Value | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Join-NotificationLines {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @()
    )

    return (@($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n").Trim()
}

function Get-NotificationLogExcerpt {
    param(
        [string]$Logs
    )

    if ([string]::IsNullOrWhiteSpace($Logs)) {
        return '(no logs)'
    }

    $normalized = $Logs.Trim()
    if ($normalized.Length -le 1800) {
        return $normalized
    }

    return ($normalized.Substring(0, 1800).TrimEnd() + "`n... (truncated)")
}

# Incoming webhooks are deprecated. Use direct Teams chat via teams_chat_enabled and the teams-chat helper.
# The legacy webhook code was removed to prevent dual-path complexity. If you still rely on a webhook,
# migrate to direct Teams chat or keep a local adapter that translates chat -> webhook.

$configContent = Get-RatatoskConfigContent
$teamsChatSettings = Get-RatatoskTeamsChatSettings
if (-not $teamsChatSettings.enabled) {
    throw "Deprecated: incoming Teams webhook support has been removed. Enable direct Teams chat by setting 'teams_chat_enabled: true' and configure teams_chat_target_mode/teams_chat_target. See docs/teams-guide.md for migration steps."
}

$jobNumber = Get-NotificationValue -Object $tplData -Name 'jobNumber'
$jobGuid = Get-NotificationValue -Object $tplData -Name 'jobGuid'
$jobLink = if ([string]::IsNullOrWhiteSpace($jobNumber)) {
    ''
} else {
    Get-EdiProdMarkdownLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
}

function Get-HtmlJobLink {
    param([string]$JobNumber, [string]$JobGuid, [string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($JobNumber)) { return '' }
    $url = Get-EdiProdWebLink -JobNumber $JobNumber -JobGuid $JobGuid -StatePath $StatePath
    $safe = [System.Net.WebUtility]::HtmlEncode($JobNumber)
    if ([string]::IsNullOrWhiteSpace($url)) { return $safe }
    return "<a href=`"$url`">$safe</a>"
}

function Get-HtmlSafe { param([string]$Value) return [System.Net.WebUtility]::HtmlEncode($Value) }

function Build-HtmlFact {
    param([string]$Label, [string]$Value)
    $safeLabel = Get-HtmlSafe $Label
    $safeValue = Get-HtmlSafe $Value
    return "<tr><td><strong>$safeLabel</strong></td><td>$safeValue</td></tr>"
}

function Build-HtmlNotification {
    param(
        [string]$Emoji,
        [string]$Title,
        [string]$JobHtmlLink,
        [string[]]$FactRows,
        [string]$BodyHtml = ''
    )

    $factsHtml = if ($FactRows.Count -gt 0) {
        '<table>' + ($FactRows -join '') + '</table>'
    } else { '' }

    $jobRow = if (-not [string]::IsNullOrWhiteSpace($JobHtmlLink)) {
        "<p>$JobHtmlLink</p>"
    } else { '' }

    $body = if (-not [string]::IsNullOrWhiteSpace($BodyHtml)) { $BodyHtml } else { '' }

    return "<p><strong>$Emoji $Title</strong></p>$jobRow$factsHtml$body"
}

$cardBody = @()
$chatText = ''
$chatHtml = ''
$chatFallbackFormat = 'html'

switch ($templateName) {
    'task-started' {
        $taskType = Get-NotificationValue -Object $tplData -Name 'taskType'
        $taskSequence = Get-NotificationValue -Object $tplData -Name 'taskSequence'
        $jobTitle = Get-NotificationValue -Object $tplData -Name 'jobTitle'
        $zone = Get-NotificationValue -Object $tplData -Name 'zone'
        $description = Get-NotificationValue -Object $tplData -Name 'description' -Default $jobNumber
        $jobLabel = if (-not [string]::IsNullOrWhiteSpace($jobTitle)) { "$jobNumber · $jobTitle" } else { $jobNumber }

        $cardBody = @(
            @{
                type = 'Container'
                style = 'good'
                items = @(
                    @{ type = 'TextBlock'; text = 'Task Started'; weight = 'Bolder'; size = 'Large' }
                )
            }
            @{
                type = 'TextBlock'
                text = "Open job: $jobLink"
                wrap = $true
            }
            @{
                type = 'FactSet'
                facts = @(
                    @{ title = 'Job'; value = $jobLabel }
                    @{ title = 'Type'; value = $taskType }
                    @{ title = 'Task'; value = $taskSequence }
                    @{ title = 'Zone'; value = $zone }
                    @{ title = 'Description'; value = $description }
                )
            }
        )

        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) Task Started"
            "Job: $jobLabel  $jobLink"
            "Type: $taskType"
            "Task: $taskSequence"
            "Zone: $zone"
            "Description: $description"
        )

        $htmlLink = Get-HtmlJobLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
        $chatHtml = Build-HtmlNotification -Emoji '🚀' -Title 'Task Started' -JobHtmlLink $htmlLink -FactRows @(
            Build-HtmlFact 'Job' $jobLabel
            Build-HtmlFact 'Type' $taskType
            Build-HtmlFact 'Task' $taskSequence
            Build-HtmlFact 'Zone' $zone
            Build-HtmlFact 'Description' $description
        )
    }

    'task-completed' {
        $taskType = Get-NotificationValue -Object $tplData -Name 'taskType' -Default '(unknown)'
        $taskSequence = Get-NotificationValue -Object $tplData -Name 'taskSequence' -Default '(unknown)'
        $jobTitle = Get-NotificationValue -Object $tplData -Name 'jobTitle'
        $description = Get-NotificationValue -Object $tplData -Name 'description'
        $duration = Get-NotificationValue -Object $tplData -Name 'duration' -Default '(unknown)'
        $summaryText = Get-NotificationValue -Object $tplData -Name 'summary' -Default '(no final summary provided)'
        $prUrls = @(Get-NotificationArray -Value $tplData.prUrls)
        $prText = if ($prUrls.Count -gt 0) { ($prUrls | ForEach-Object { "- [$_]($_)" }) -join "`n" } else { '(none)' }
        $jobLabel = if (-not [string]::IsNullOrWhiteSpace($jobTitle)) { "$jobNumber · $jobTitle" } else { $jobNumber }

        $cardBody = @(
            @{
                type = 'Container'
                style = 'accent'
                items = @(
                    @{ type = 'TextBlock'; text = 'Task Completed'; weight = 'Bolder'; size = 'Large' }
                )
            }
            @{
                type = 'TextBlock'
                text = "Open job: $jobLink"
                wrap = $true
            }
            @{
                type = 'FactSet'
                facts = @(
                    @{ title = 'Job'; value = $jobLabel }
                    @{ title = 'Type'; value = $taskType }
                    @{ title = 'Task Seq'; value = $taskSequence }
                    @{ title = 'Description'; value = $description }
                    @{ title = 'Duration'; value = $duration }
                )
            }
            @{
                type = 'TextBlock'
                text = "**Final Summary:**`n$summaryText"
                wrap = $true
            }
            @{
                type = 'TextBlock'
                text = "**Pull Requests:**`n$prText"
                wrap = $true
            }
        )

        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) Task Completed"
            "Job: $jobLabel  $jobLink"
            "Type: $taskType"
            "Task: $taskSequence"
            "Description: $description"
            "Duration: $duration"
            "Summary: $summaryText"
            "Pull Requests:"
            $prText
        )

        $htmlLink = Get-HtmlJobLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
        $prHtmlList = if ($prUrls.Count -gt 0) {
            '<ul>' + ($prUrls | ForEach-Object { "<li><a href=`"$(Get-HtmlSafe $_)`">$(Get-HtmlSafe $_)</a></li>" }) -join '' + '</ul>'
        } else { '<p>(none)</p>' }

        $bodyHtml = "<p><strong>Summary:</strong></p><blockquote>$(Get-HtmlSafe $summaryText)</blockquote><p><strong>Pull Requests:</strong></p>$prHtmlList"
        $chatHtml = Build-HtmlNotification -Emoji '✅' -Title 'Task Completed' -JobHtmlLink $htmlLink -FactRows @(
            Build-HtmlFact 'Job' $jobLabel
            Build-HtmlFact 'Type' $taskType
            Build-HtmlFact 'Task' $taskSequence
            Build-HtmlFact 'Description' $description
            Build-HtmlFact 'Duration' $duration
        ) -BodyHtml $bodyHtml
    }

    'task-failed' {
        $taskSequence = Get-NotificationValue -Object $tplData -Name 'taskSequence' -Default '(unknown)'
        $taskType = Get-NotificationValue -Object $tplData -Name 'taskType' -Default '(unknown)'
        $zone = Get-NotificationValue -Object $tplData -Name 'zone' -Default '(unknown)'
        $duration = Get-NotificationValue -Object $tplData -Name 'duration' -Default '(unknown)'
        $timestamp = Get-NotificationValue -Object $tplData -Name 'timestamp' -Default '(unknown)'
        $errorText = Get-NotificationValue -Object $tplData -Name 'error' -Default '(unknown)'
        $logText = Get-NotificationLogExcerpt -Logs (Get-NotificationValue -Object $tplData -Name 'logs')

        $cardBody = @(
            @{
                type = 'Container'
                style = 'attention'
                items = @(
                    @{ type = 'TextBlock'; text = 'Task Failed'; weight = 'Bolder'; size = 'Large'; color = 'Attention' }
                )
            }
            @{
                type = 'TextBlock'
                text = "Open job: $jobLink"
                wrap = $true
            }
            @{
                type = 'FactSet'
                facts = @(
                    @{ title = 'Job'; value = $jobNumber }
                    @{ title = 'Task Seq'; value = $taskSequence }
                    @{ title = 'Type'; value = $taskType }
                    @{ title = 'Zone'; value = $zone }
                    @{ title = 'Duration'; value = $duration }
                    @{ title = 'Timestamp'; value = $timestamp }
                    @{ title = 'Error'; value = $errorText }
                )
            }
            @{
                type = 'TextBlock'
                text = "``````$logText``````"
                wrap = $true
                fontType = 'Monospace'
            }
        )

        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) Task Failed"
            "Job: $jobLink"
            "Task: $taskSequence"
            "Type: $taskType"
            "Zone: $zone"
            "Duration: $duration"
            "Timestamp: $timestamp"
            "Error: $errorText"
            'Logs:'
            '```'
            $logText
            '```'
        )

        $htmlLink = Get-HtmlJobLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
        $bodyHtml = "<p><strong>Error:</strong> $(Get-HtmlSafe $errorText)</p><p><strong>Logs:</strong></p><pre>$(Get-HtmlSafe $logText)</pre>"
        $chatHtml = Build-HtmlNotification -Emoji '❌' -Title 'Task Failed' -JobHtmlLink $htmlLink -FactRows @(
            Build-HtmlFact 'Task' $taskSequence
            Build-HtmlFact 'Type' $taskType
            Build-HtmlFact 'Zone' $zone
            Build-HtmlFact 'Duration' $duration
            Build-HtmlFact 'Timestamp' $timestamp
        ) -BodyHtml $bodyHtml
    }

    'user-input-request' {
        $taskSequence = Get-NotificationValue -Object $tplData -Name 'taskSequence' -Default '(unknown)'
        $taskType = Get-NotificationValue -Object $tplData -Name 'taskType' -Default '(unknown)'
        $zone = Get-NotificationValue -Object $tplData -Name 'zone' -Default '(unknown)'
        $questionType = Get-NotificationValue -Object $tplData -Name 'questionType' -Default '(unknown)'
        $severity = Get-NotificationValue -Object $tplData -Name 'severity' -Default '(unknown)'
        $answerMode = Get-NotificationValue -Object $tplData -Name 'answerMode' -Default '(unknown)'
        $requestId = Get-NotificationValue -Object $tplData -Name 'requestId'
        $question = Get-NotificationValue -Object $tplData -Name 'question'
        $options = @(Get-NotificationArray -Value $tplData.options)
        $optionsText = if ($options.Count -gt 0) { ($options | ForEach-Object { "- $_" }) -join "`n" } else { '(freeform response)' }

        $cardBody = @(
            @{
                type = 'Container'
                style = 'warning'
                items = @(
                    @{ type = 'TextBlock'; text = 'User Input Needed'; weight = 'Bolder'; size = 'Large' }
                )
            }
            @{
                type = 'TextBlock'
                text = "Open job: $jobLink"
                wrap = $true
            }
            @{
                type = 'FactSet'
                facts = @(
                    @{ title = 'Job'; value = $jobNumber }
                    @{ title = 'Task Seq'; value = $taskSequence }
                    @{ title = 'Type'; value = $taskType }
                    @{ title = 'Zone'; value = $zone }
                    @{ title = 'Question Type'; value = $questionType }
                    @{ title = 'Severity'; value = $severity }
                    @{ title = 'Answer Mode'; value = $answerMode }
                    @{ title = 'Request Id'; value = $requestId }
                )
            }
            @{
                type = 'TextBlock'
                text = "**Question:**`n$question"
                wrap = $true
            }
            @{
                type = 'TextBlock'
                text = "**Reply options:**`n$optionsText"
                wrap = $true
            }
            @{
                type = 'TextBlock'
                text = "Use the Ratatosk dashboard command bar with: `reply $jobNumber <your answer>` or reply to the matching Ratatosk email notification."
                wrap = $true
            }
        )

        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) User Input Needed"
            "Job: $jobLink"
            "Task: $taskSequence"
            "Type: $taskType"
            "Question Type: $questionType"
            "Severity: $severity"
            "Question: $question"
            "Reply options:"
            $optionsText
            "Reply here with: $($teamsChatSettings.commandPrefix) reply $jobNumber <your answer>"
        )

        $htmlLink = Get-HtmlJobLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
        $optionsHtml = if ($options.Count -gt 0) {
            '<ul>' + ($options | ForEach-Object { "<li>$(Get-HtmlSafe $_)</li>" }) -join '' + '</ul>'
        } else { '<p><em>(freeform response)</em></p>' }
        $replyCommand = "$(Get-HtmlSafe $teamsChatSettings.commandPrefix) reply $([System.Net.WebUtility]::HtmlEncode($jobNumber)) &lt;your answer&gt;"
        $bodyHtml = "<p><strong>Question:</strong></p><blockquote>$(Get-HtmlSafe $question)</blockquote><p><strong>Reply options:</strong></p>$optionsHtml<p>Reply here: <code>$replyCommand</code></p>"
        $chatHtml = Build-HtmlNotification -Emoji '❓' -Title 'User Input Needed' -JobHtmlLink $htmlLink -FactRows @(
            Build-HtmlFact 'Task' $taskSequence
            Build-HtmlFact 'Type' $taskType
            Build-HtmlFact 'Severity' $severity
            Build-HtmlFact 'Question Type' $questionType
        ) -BodyHtml $bodyHtml
    }

    'queue-added' {
        $taskType = Get-NotificationValue -Object $tplData -Name 'taskType'
        $description = Get-NotificationValue -Object $tplData -Name 'description' -Default $jobNumber
        $source = Get-NotificationValue -Object $tplData -Name 'source' -Default '(unknown)'

        $cardBody = @(
            @{
                type = 'Container'
                style = 'warning'
                items = @(
                    @{ type = 'TextBlock'; text = 'Job Queued'; weight = 'Bolder'; size = 'Large' }
                )
            }
            @{
                type = 'TextBlock'
                text = "Open job: $jobLink"
                wrap = $true
            }
            @{
                type = 'FactSet'
                facts = @(
                    @{ title = 'Job'; value = $jobNumber }
                    @{ title = 'Type'; value = $taskType }
                    @{ title = 'Description'; value = $description }
                    @{ title = 'Source'; value = $source }
                )
            }
        )

        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) Job Queued"
            "Job: $jobLink"
            "Type: $taskType"
            "Description: $description"
            "Source: $source"
        )

        $htmlLink = Get-HtmlJobLink -JobNumber $jobNumber -JobGuid $jobGuid -StatePath $statePath
        $chatHtml = Build-HtmlNotification -Emoji '📥' -Title 'Job Queued' -JobHtmlLink $htmlLink -FactRows @(
            Build-HtmlFact 'Type' $taskType
            Build-HtmlFact 'Description' $description
            Build-HtmlFact 'Source' $source
        )
    }

    'daily-summary' {
        $workerRows = @(
            Get-NotificationArray -Value $tplData.workers | ForEach-Object {
                "- $($_.name) | zone $($_.zone) | $($_.status) | $($_.jobNumber) | $($_.lastActivity)"
            }
        )

        $rows = @()
        if ($tplData.workers) {
            $rows = $tplData.workers | ForEach-Object {
                @{
                    type = 'TableRow'
                    cells = @(
                        @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = "$($_.name)" }) }
                        @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = "$($_.zone)" }) }
                        @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = "$($_.status)" }) }
                        @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = "$($_.jobNumber)" }) }
                        @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = "$($_.lastActivity)" }) }
                    )
                }
            }
        }

        $headerRow = @{
            type = 'TableRow'
            style = 'accent'
            cells = @(
                @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = 'Worker'; weight = 'Bolder' }) }
                @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = 'Zone'; weight = 'Bolder' }) }
                @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = 'Status'; weight = 'Bolder' }) }
                @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = 'Job'; weight = 'Bolder' }) }
                @{ type = 'TableCell'; items = @(@{ type = 'TextBlock'; text = 'Last Activity'; weight = 'Bolder' }) }
            )
        }

        $cardBody = @(
            @{ type = 'TextBlock'; text = 'Ratatosk Daily Summary'; weight = 'Bolder'; size = 'Large' }
            @{
                type = 'Table'
                columns = @(
                    @{ width = 1 }, @{ width = 1 }, @{ width = 1 }, @{ width = 1 }, @{ width = 2 }
                )
                rows = @($headerRow) + @($rows)
            }
        )

        $summaryLines = if ($workerRows.Count -gt 0) { @($workerRows) } else { @('- No worker rows in this summary.') }
        $chatText = Join-NotificationLines @(
            "$(Get-RatatoskTeamsNotificationPrefix) Ratatosk Daily Summary"
            $summaryLines
        )

        # Build HTML table for daily summary
        $tableRows = if ($tplData.workers) {
            $tplData.workers | ForEach-Object {
                $wJobLink = Get-HtmlJobLink -JobNumber ([string]$_.jobNumber) -StatePath $statePath
                "<tr><td>$(Get-HtmlSafe ([string]$_.name))</td><td>$(Get-HtmlSafe ([string]$_.zone))</td><td>$(Get-HtmlSafe ([string]$_.status))</td><td>$wJobLink</td><td>$(Get-HtmlSafe ([string]$_.lastActivity))</td></tr>"
            }
        } else { @() }
        $tableHtml = '<table><tr><th>Worker</th><th>Zone</th><th>Status</th><th>Job</th><th>Last Activity</th></tr>' + ($tableRows -join '') + '</table>'
        $chatHtml = "<p><strong>📊 Ratatosk Daily Summary</strong></p>$tableHtml"
    }

    'status-report' {
        $statusReport = if ($tplData.statusReport) { [string]$tplData.statusReport } else { '' }
        if ([string]::IsNullOrWhiteSpace($statusReport) -and $tplData.counts) {
            $c = $tplData.counts
            $statusReport = "Startable: $($c.startableJobs)  ·  Queue: $($c.waitingQueue)  ·  Workers: $($c.workers)  ·  Completed: $($c.completedJobs)  ·  Failed: $($c.failedJobs)"
        }
        if ([string]::IsNullOrWhiteSpace($statusReport)) { $statusReport = 'Ratatosk Status' }
        $prefix = "$(Get-RatatoskTeamsNotificationPrefix) Status"
        $chatText = "$prefix`n$statusReport"
        # Fallback uses raw markdown so **bold** and code blocks render correctly in Teams
        $chatHtml = $chatText
        $chatFallbackFormat = 'markdown'
    }

    default {
        throw "Unknown template: $templateName"
    }
}

try {
    $channels = @()
    $errors = @()

    # Legacy webhook support removed — only direct Teams chat is supported.
    # If you're seeing this error, ensure teams_chat_enabled: true in config.local.yaml and that the teams chat helper is available.
    # (The old adaptive-card webhook path was intentionally deprecated.)

    # --- Direct chat (rich HTML log; no toast but keeps history) ---
    $teamsChatDisabledReason = Get-RatatoskTeamsChatDisabledReason -Settings $teamsChatSettings
    if ($teamsChatSettings.enabled -and [string]::IsNullOrWhiteSpace($teamsChatDisabledReason)) {
        try {
            $chatResult = $null

            # Try SharePoint file attachment first (renders Markdown with links)
            $tmpDir = [System.IO.Path]::GetTempPath()
            $safeName = ($templateName -replace '[^a-zA-Z0-9_-]', '-')
            $tmpFile = Join-Path $tmpDir "ratatosk-$safeName-$(Get-Date -Format 'yyyyMMddHHmmss').md"
            $sendFileDelivered = $false
            try {
                [System.IO.File]::WriteAllText($tmpFile, $chatText, [System.Text.Encoding]::UTF8)
                $captionLine = ($chatText -split "`n")[0].Trim()
                $chatResult = Invoke-RatatoskTeamsChat -Action 'send-file' -Settings $teamsChatSettings `
                    -FilePath $tmpFile -Caption $captionLine
                # Only set after a clean return — if Invoke-RatatoskTeamsChat returned without throwing,
                # the file was delivered. Do not fall back even if $chatResult is null.
                $sendFileDelivered = $true
            } catch {
                $chatResult = $null
            } finally {
                if (Test-Path -LiteralPath $tmpFile) {
                    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
                }
            }

            # Fallback: send rich HTML directly — only when send-file never reached delivery.
            # If send-file threw AFTER delivering (e.g. node crashed before writing output), $sendFileDelivered
            # remains $false and we would fall back, but that is the safer trade-off: one lost notification
            # is preferable to a duplicate. Invoke-RatatoskTeamsChat throws on empty/invalid node output,
            # so a clean delivery always sets $sendFileDelivered = $true above.
            if ($null -eq $chatResult -and -not $sendFileDelivered) {
                $chatResult = Invoke-RatatoskTeamsChat -Action 'send-message' -Settings $teamsChatSettings -Content $chatHtml -Format $chatFallbackFormat
            }

            $channels += 'chat'
        } catch {
            $errors += "chat: $($_.Exception.Message)"
        }
    }

    # Require at least one channel succeeded
    if ($channels.Count -eq 0) {
        $allErrors = if ($errors.Count -gt 0) { $errors -join '; ' } else { 'No notification channel is configured (teams_chat_enabled must be true).' }
        throw $allErrors
    }

    [PSCustomObject]@{
        success = $true
        template = $templateName
        channel = ($channels -join ' + ')
    } | ConvertTo-Json -Depth 20
} catch {
    [PSCustomObject]@{
        success = $false
        template = $templateName
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 20
}
