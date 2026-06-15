[CmdletBinding()]
param(
    [int]$Top = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$autotaskRoot = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $autotaskRoot 'temp\state.json'

. (Join-Path $PSScriptRoot 'graph-mail-common.ps1')
. (Join-Path $PSScriptRoot 'autotask-link-common.ps1')

function Get-ConfigContent {
    $autotaskRoot = Split-Path -Parent $PSScriptRoot
    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($configPath in @(
        (Join-Path $autotaskRoot 'config.yaml'),
        (Join-Path $autotaskRoot 'config.local.yaml')
    )) {
        if (-not (Test-Path -LiteralPath $configPath)) {
            continue
        }

        $chunks.Add([System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8))
    }

    return [string]::Join([Environment]::NewLine, $chunks)
}

function Get-ConfigTextValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    $lines = $Content -split "`r?`n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        $line = $lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^(?<name>[^:]+):\s*(?<value>.*)$') {
            continue
        }

        if ($matches['name'].Trim() -ne $Key) {
            continue
        }

        $value = $matches['value'].Trim()
        if ($value.Contains('#')) {
            $value = $value.Split('#', 2)[0].Trim()
        }

        return $value.Trim("'`"")
    }

    return $Default
}

function Get-ConfigBooleanValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [bool]$Default = $false
    )

    $rawValue = Get-ConfigTextValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $Default
    }

    switch ($rawValue.Trim().ToLowerInvariant()) {
        'true' { return $true }
        'yes' { return $true }
        '1' { return $true }
        'false' { return $false }
        'no' { return $false }
        '0' { return $false }
        default { return $Default }
    }
}

function Get-ConfigListValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $rawValue = Get-ConfigTextValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return @()
    }

    return @($rawValue.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if (-not $Object.PSObject.Properties[$Name]) {
        return $Default
    }

    return $Object.$Name
}

function Get-ReplyText {
    param(
        [string]$BodyHtml
    )

    $text = ConvertFrom-HtmlToPlainText -Html $BodyHtml
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    $lines = $text -split "`n"
    $replyLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^(From:|Sent:|Subject:|To:|Cc:|On .+ wrote:|________________________________)') {
            break
        }

        if ($replyLines.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($trimmed)) {
            [void]$replyLines.Add($trimmed)
        }
    }

    # Remove trailing blank lines; preserve internal blank lines
    while ($replyLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($replyLines[$replyLines.Count - 1])) {
        $replyLines.RemoveAt($replyLines.Count - 1)
    }

    return ($replyLines -join "`n")
}

function Test-AllowedSender {
    param(
        [string]$Sender,
        [string[]]$AllowedSenders
    )

    if ($AllowedSenders.Count -eq 0) {
        return $false
    }

    foreach ($allowedSender in $AllowedSenders) {
        if ($Sender.Equals($allowedSender, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-CommandTextFromMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$ReplyText,

        [Parameter(Mandatory)]
        [string]$SubjectPrefix
    )

    $escapedPrefix = [regex]::Escape($SubjectPrefix.Trim())
    $match = [regex]::Match($Subject, "^\s*$escapedPrefix\s*:?\s*(?<command>.*)$", 'IgnoreCase')
    if (-not $match.Success) {
        return ''
    }

    $commandFromSubject = [string]$match.Groups['command'].Value
    if (-not [string]::IsNullOrWhiteSpace($commandFromSubject)) {
        # Subject has the command header. Append the reply body so multi-line commands
        # (e.g. setnotes) can include their content. Single-line parsers only read line 1.
        $header = $commandFromSubject.Trim()
        if ([string]::IsNullOrWhiteSpace($ReplyText)) {
            return $header
        }
        return ($header + "`n" + $ReplyText)
    }

    if ([string]::IsNullOrWhiteSpace($ReplyText)) {
        return ''
    }

    # No command in subject — treat the full body as the command text. The first
    # non-blank line is the action line; subsequent lines are content (e.g. setnotes body).
    $bodyLines = $ReplyText -split "`r?`n"
    $firstNonBlankIdx = -1
    for ($i = 0; $i -lt $bodyLines.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace($bodyLines[$i])) {
            $firstNonBlankIdx = $i
            break
        }
    }
    if ($firstNonBlankIdx -lt 0) {
        return ''
    }
    return ($bodyLines[$firstNonBlankIdx..($bodyLines.Count - 1)] -join "`n").TrimEnd()
}

function Mark-MessageRead {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$MessageId
    )

    Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/me/messages/$MessageId" `
        -Headers $Headers `
        -Method PATCH `
        -ContentType 'application/json' `
        -Body (@{ isRead = $true } | ConvertTo-Json) | Out-Null
}

function Get-MailFolderPathSegments {
    param(
        [string]$FolderPath
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        return @('Inbox')
    }

    $segments = $FolderPath -split '[\\/]+'
    return @($segments | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ChildMailFolders {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$ParentIdentifier
    )

    $uri = "https://graph.microsoft.com/v1.0/me/mailFolders/$ParentIdentifier/childFolders?`$select=id,displayName&`$top=200"
    $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET
    return @($response.value)
}

function Resolve-MailFolder {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [string]$FolderPath = 'Inbox'
    )

    $segments = @(Get-MailFolderPathSegments -FolderPath $FolderPath)
    $wellKnownFolders = @{
        inbox = 'Inbox'
        archive = 'Archive'
        drafts = 'Drafts'
        sentitems = 'SentItems'
        deleteditems = 'DeletedItems'
        junkemail = 'JunkEmail'
    }

    $firstSegment = $segments[0]
    $firstKey = $firstSegment.ToLowerInvariant()
    if ($wellKnownFolders.ContainsKey($firstKey)) {
        $currentIdentifier = $wellKnownFolders[$firstKey]
        $currentDisplayPath = $firstSegment
        $remainingSegments = if ($segments.Count -gt 1) { @($segments[1..($segments.Count - 1)]) } else { @() }
    } else {
        $rootFolders = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me/mailFolders?`$select=id,displayName&`$top=200" -Headers $Headers -Method GET
        $rootFolder = @($rootFolders.value | Where-Object { ([string]$_.displayName).Equals($firstSegment, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if (-not $rootFolder) {
            throw "Mailbox folder '$firstSegment' was not found."
        }

        $currentIdentifier = [string]$rootFolder.id
        $currentDisplayPath = [string]$rootFolder.displayName
        $remainingSegments = if ($segments.Count -gt 1) { @($segments[1..($segments.Count - 1)]) } else { @() }
    }

    foreach ($segment in $remainingSegments) {
        $childFolder = @(Get-ChildMailFolders -Headers $Headers -ParentIdentifier $currentIdentifier | Where-Object {
                ([string]$_.displayName).Equals($segment, [System.StringComparison]::OrdinalIgnoreCase)
            }) | Select-Object -First 1
        if (-not $childFolder) {
            throw "Mailbox folder path '$FolderPath' was not found. Missing segment '$segment'."
        }

        $currentIdentifier = [string]$childFolder.id
        $currentDisplayPath = "$currentDisplayPath/$([string]$childFolder.displayName)"
    }

    return [PSCustomObject]@{
        id = $currentIdentifier
        displayPath = $currentDisplayPath
    }
}

function Send-CommandReplyEmail {
    param(
        [Parameter(Mandatory)]
        [string]$Recipient,

        [Parameter(Mandatory)]
        [string]$OriginalCommand,

        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$SubjectPrefix = 'Autotask',
        [string]$JobNumber = '',
        [string]$Action = '',
        [bool]$Duplicate = $false,
        $Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($Recipient)) {
        return
    }

    function ConvertTo-HtmlText {
        param([string]$Value)
        return [System.Net.WebUtility]::HtmlEncode($Value)
    }

    function Get-JobLinkHtml {
        param(
            [string]$JobNumber,
            [string]$JobGuid = ''
        )

        $safeJobNumber = ConvertTo-HtmlText $JobNumber
        $jobLink = Get-IssueWebLink -JobNumber $JobNumber -StatePath $statePath
        if ([string]::IsNullOrWhiteSpace($jobLink)) {
            return $safeJobNumber
        }

        return "<a href='$jobLink'>$safeJobNumber</a>"
    }

    function Get-PropertyValues {
        param(
            [object]$Object,
            [string]$Name
        )

        $value = Get-ObjectPropertyValue -Object $Object -Name $Name -Default @()
        if ($null -eq $value) {
            return @()
        }

        return @($value)
    }

    function Get-StatusMetricCardHtml {
        param(
            [string]$Label,
            [string]$Value
        )

        return "<div style='display:inline-block;vertical-align:top;min-width:130px;margin:0 12px 12px 0;padding:12px 14px;border:1px solid #d8e0ef;border-radius:10px;background:#f8fbff;'><div style='font-size:12px;color:#5b6b82;text-transform:uppercase;letter-spacing:0.04em;'>$(ConvertTo-HtmlText $Label)</div><div style='font-size:24px;font-weight:700;color:#17324d;margin-top:4px;'>$(ConvertTo-HtmlText $Value)</div></div>"
    }

    function Get-StatusListHtml {
        param(
            [object[]]$Items,
            [string]$CommandPrefix = 'autotask:',
            [bool]$ShowStartCommand = $false
        )

        $rows = @($Items)
        if ($rows.Count -eq 0) {
            return '<p style="margin:0;color:#667085;">(none)</p>'
        }

        $parts = foreach ($item in $rows) {
            $job = Get-JobLinkHtml -JobNumber ([string]$item.jobNumber) -JobGuid ([string]$item.jobGuid)
            $summary = ConvertTo-HtmlText ([string]$item.summary)
            $type = ConvertTo-HtmlText ([string]$item.taskType)
            $taskSequence = ConvertTo-HtmlText ([string]$item.taskSequence)
            $taskLabel = if (-not [string]::IsNullOrWhiteSpace([string]$item.taskSequence)) { " <span style='display:inline-block;padding:1px 8px;border-radius:999px;background:#f6f3ff;color:#53389e;font-size:11px;font-weight:700;'>Task $taskSequence</span>" } else { '' }
            $neverAutoLabel = if ([bool](Get-ObjectPropertyValue -Object $item -Name 'neverAutoStart' -Default $false)) {
                " <span style='display:inline-block;padding:1px 8px;border-radius:999px;background:#fdf4ff;color:#c026d3;font-size:11px;font-weight:700;'>🚫 Never Auto</span>"
            } else { '' }
            $startCmdHtml = if ($ShowStartCommand) {
                $taskSeqPart = if (-not [string]::IsNullOrWhiteSpace([string]$item.taskSequence)) { " --task $([string]$item.taskSequence)" } else { '' }
                $startCmd = ConvertTo-HtmlText "$CommandPrefix start $([string]$item.jobNumber)$taskSeqPart"
                "<br><span style='font-family:Consolas,monospace;font-size:12px;background:#f8f9fa;padding:2px 6px;border-radius:4px;color:#344054;cursor:text;user-select:all;'>$startCmd</span>"
            } else { '' }
            "<li style='margin:0 0 8px 18px;'><span style='font-family:Consolas,monospace;font-weight:700;'>$job</span>$taskLabel$neverAutoLabel - $summary <span style='color:#667085;'>($type)</span>$startCmdHtml</li>"
        }

        return "<ul style='margin:0;padding:0;'>$($parts -join '')</ul>"
    }

    function Get-StatusJobCardsHtml {
        param(
            [string]$Title,
            [object[]]$Items,
            [bool]$PromoteFinalSummary = $false
        )

        $rows = @($Items)
        if ($rows.Count -eq 0) {
            return "<h3 style='margin:20px 0 8px;'>$(ConvertTo-HtmlText $Title)</h3><p style='margin:0;color:#667085;'>(none)</p>"
        }

        $cards = foreach ($item in $rows) {
            $job = Get-JobLinkHtml -JobNumber ([string]$item.jobNumber) -JobGuid ([string]$item.jobGuid)
            $summary = ConvertTo-HtmlText ([string]$item.summary)
            $taskType = ConvertTo-HtmlText ([string]$item.taskType)
            $phase = ConvertTo-HtmlText ([string]$item.phase)
            $activityStatus = ConvertTo-HtmlText ([string]$item.activityStatus)
            $activityMessage = ConvertTo-HtmlText ([string]$item.activityMessage)
            $taskSequence = ConvertTo-HtmlText ([string]$item.taskSequence)
            $branch = ConvertTo-HtmlText ([string]$item.branch)
            $queuedAt = ConvertTo-HtmlText ([string]$item.queuedAt)
            $startedAt = ConvertTo-HtmlText ([string]$item.startedAt)
            $completedAt = ConvertTo-HtmlText ([string]$item.completedAt)
            $finalSummary = ConvertTo-HtmlText ([string]$item.finalReportSummary)
            $error = ConvertTo-HtmlText ([string]$item.error)
            $prValues = @(Get-PropertyValues -Object $item -Name 'prUrls')
            $prHtml = ''
            if ($prValues.Count -gt 0) {
                $prLinks = foreach ($pr in $prValues) {
                    $safePr = ConvertTo-HtmlText ([string]$pr)
                    "<li style='margin:0 0 4px 18px;'><a href='$safePr'>$safePr</a></li>"
                }
                $prHtml = "<div style='margin-top:10px;'><div style='font-weight:600;color:#344054;'>PRs</div><ul style='margin:4px 0 0;padding:0;'>$($prLinks -join '')</ul></div>"
            }

            $metaRows = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$item.taskSequence)) { $metaRows += "<div><strong>Task:</strong> $taskSequence</div>" }
            if (-not [string]::IsNullOrWhiteSpace($taskType)) { $metaRows += "<div><strong>Type:</strong> $taskType</div>" }
            if (-not [string]::IsNullOrWhiteSpace($phase)) { $metaRows += "<div><strong>Phase:</strong> $phase</div>" }
            if (-not [string]::IsNullOrWhiteSpace($activityStatus)) { $metaRows += "<div><strong>Activity:</strong> $activityStatus</div>" }
            if (-not [string]::IsNullOrWhiteSpace($activityMessage)) { $metaRows += "<div><strong>Detail:</strong> $activityMessage</div>" }
            if (-not [string]::IsNullOrWhiteSpace($branch)) { $metaRows += "<div><strong>Branch:</strong> <span style='font-family:Consolas,monospace;'>$branch</span></div>" }
            if (-not [string]::IsNullOrWhiteSpace($queuedAt)) { $metaRows += "<div><strong>Queued:</strong> $queuedAt</div>" }
            if (-not [string]::IsNullOrWhiteSpace($startedAt)) { $metaRows += "<div><strong>Started:</strong> $startedAt</div>" }
            if (-not [string]::IsNullOrWhiteSpace($completedAt)) { $metaRows += "<div><strong>Completed:</strong> $completedAt</div>" }
            if (-not [string]::IsNullOrWhiteSpace($error)) { $metaRows += "<div><strong>Error:</strong> $error</div>" }

            $summaryHtml = if ($PromoteFinalSummary -and -not [string]::IsNullOrWhiteSpace($finalSummary)) {
                "<div style='margin-top:10px;padding:10px 12px;border-left:4px solid #7f56d9;background:#f6f3ff;'><div style='font-weight:600;color:#53389e;'>Final summary</div><div style='margin-top:4px;'>$finalSummary</div></div>"
            } else {
                ''
            }

            "<div style='margin:0 0 14px;padding:14px 16px;border:1px solid #d8e0ef;border-radius:12px;background:#fff;'>" +
                "<div style='font-size:18px;font-weight:700;color:#17324d;font-family:Consolas,monospace;'>$job</div>" +
                "<div style='margin-top:4px;font-size:15px;font-weight:600;color:#101828;'>$summary</div>" +
                "<div style='margin-top:10px;line-height:1.55;color:#344054;'>$($metaRows -join '')</div>" +
                $summaryHtml +
                $prHtml +
                '</div>'
        }

        return "<h3 style='margin:20px 0 8px;'>$(ConvertTo-HtmlText $Title)</h3>$($cards -join '')"
    }

    $resolvedAction = if ([string]::IsNullOrWhiteSpace($Action)) { 'command' } else { $Action }
    $statusText = if ($Success) { 'Succeeded' } else { 'Failed' }
    $safeCommand = ConvertTo-HtmlText $OriginalCommand
    $safeMessage = ConvertTo-HtmlText $Message
    $safeRecipient = ConvertTo-HtmlText $Recipient
    $safeJobNumber = ConvertTo-HtmlText $JobNumber
    $safeAction = ConvertTo-HtmlText $resolvedAction
    $duplicateText = if ($Duplicate) {
        if ($resolvedAction -eq 'status') {
            '<p style="margin-top:16px;padding:10px 12px;border-left:4px solid #f79009;background:#fffaeb;"><strong>Duplicate command:</strong> the original email was already processed, but the status snapshot below was refreshed from the current Autotask state.</p>'
        } else {
            '<p style="margin-top:16px;padding:10px 12px;border-left:4px solid #f79009;background:#fffaeb;"><strong>Duplicate command:</strong> this email matched a previously processed message and was not executed again.</p>'
        }
    } else { '' }
    $jobRow = if ([string]::IsNullOrWhiteSpace($JobNumber)) { '' } else { "<tr><td style='padding:6px;font-weight:bold;'>Job</td><td style='padding:6px;'>$safeJobNumber</td></tr>" }
    $detailSection = ''

    if ($resolvedAction -eq 'status' -and $null -ne $Data) {
        $counts = Get-ObjectPropertyValue -Object $Data -Name 'counts' -Default $null
        $warnings = @((Get-ObjectPropertyValue -Object $Data -Name 'warnings' -Default @()))
        $startableError = [string](Get-ObjectPropertyValue -Object $Data -Name 'startableError' -Default '')
        $startableItems = @((Get-ObjectPropertyValue -Object $Data -Name 'startableJobs' -Default @()))
        $neverAutoCount = @($startableItems | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name 'neverAutoStart' -Default $false) }).Count
        $detailSection = '<div style="margin-top:18px;"><h3 style="margin:0 0 10px;">Status Snapshot</h3>'
        if ($counts) {
            $detailSection +=
                (Get-StatusMetricCardHtml -Label 'Startable' -Value ([string]$counts.startableJobs)) +
                (Get-StatusMetricCardHtml -Label 'Waiting' -Value ([string]$counts.waitingQueue)) +
                (Get-StatusMetricCardHtml -Label 'Running' -Value ([string]$counts.workers)) +
                (Get-StatusMetricCardHtml -Label 'Completed' -Value ([string]$counts.completedJobs)) +
                (Get-StatusMetricCardHtml -Label 'Failed' -Value ([string]$counts.failedJobs))
        }
        if ($neverAutoCount -gt 0) {
            $detailSection += "<p style='margin-top:6px;padding:8px 12px;border-left:4px solid #c026d3;background:#fdf4ff;'><strong>🚫 Never Auto:</strong> $neverAutoCount startable task(s) are marked Never Auto Start and will not be launched automatically.</p>"
        }
        if (-not [string]::IsNullOrWhiteSpace($startableError)) {
            $detailSection += '<p style="margin-top:6px;padding:10px 12px;border-left:4px solid #d92d20;background:#fef3f2;"><strong>Startable poll error:</strong> ' + (ConvertTo-HtmlText $startableError) + '</p>'
        }
        if ($warnings.Count -gt 0) {
            $detailSection += '<p style="margin-top:6px;padding:10px 12px;border-left:4px solid #f79009;background:#fffaeb;"><strong>Warnings:</strong> ' + (ConvertTo-HtmlText ($warnings -join ' | ')) + '</p>'
        }
        $detailSection += '</div>'
        $detailSection += "<h3 style='margin:20px 0 8px;'>Startable Jobs</h3>" + (Get-StatusListHtml -Items $startableItems -CommandPrefix 'autotask:' -ShowStartCommand $true)
        $detailSection += "<h3 style='margin:20px 0 8px;'>Waiting Queue</h3>" + (Get-StatusListHtml -Items @((Get-ObjectPropertyValue -Object $Data -Name 'waitingQueue' -Default @())))
        $detailSection += Get-StatusJobCardsHtml -Title 'Running Jobs' -Items @((Get-ObjectPropertyValue -Object $Data -Name 'workers' -Default @())) -PromoteFinalSummary $true
        $detailSection += Get-StatusJobCardsHtml -Title 'Completed Jobs' -Items @((Get-ObjectPropertyValue -Object $Data -Name 'completedJobs' -Default @())) -PromoteFinalSummary $true
        $detailSection += Get-StatusJobCardsHtml -Title 'Failed Jobs' -Items @((Get-ObjectPropertyValue -Object $Data -Name 'failedJobs' -Default @())) -PromoteFinalSummary $true
    } elseif ($resolvedAction -eq 'notes' -and $null -ne $Data) {
        $notesText = [string](Get-ObjectPropertyValue -Object $Data -Name 'notes' -Default '')
        $hasNotes = -not [string]::IsNullOrWhiteSpace($notesText)
        $taskId = [string](Get-ObjectPropertyValue -Object $Data -Name 'taskId' -Default '')
        $detailSection = '<div style="margin-top:18px;">'
        if (-not [string]::IsNullOrWhiteSpace($taskId)) {
            $detailSection += "<p style='margin:0 0 8px;color:#667085;font-size:13px;'>Task ID: $(ConvertTo-HtmlText $taskId)</p>"
        }
        if ($hasNotes) {
            $escapedNotes = ConvertTo-HtmlText $notesText
            $detailSection += "<h3 style='margin:0 0 8px;'>Notes</h3><pre style='margin:0;padding:14px 16px;background:#f8f9fa;border:1px solid #d8e0ef;border-radius:8px;font-family:Consolas,monospace;font-size:13px;white-space:pre-wrap;word-break:break-word;'>$escapedNotes</pre>"
        } else {
            $detailSection += "<p style='margin:0;color:#667085;font-style:italic;'>No notes found for this task.</p>"
        }
        $detailSection += '</div>'
    }

    $subject = "Autotask Reply: $resolvedAction $statusText"
    $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;background:#f5f7fb;margin:0;padding:24px;">' +
        '<div style="max-width:980px;margin:0 auto;background:#ffffff;border:1px solid #e4e7ec;border-radius:16px;padding:24px;">' +
        "<h2 style='margin-top:0;'>Autotask command $statusText</h2>" +
        '<table style="border-collapse:collapse;width:100%;max-width:760px;">' +
        "<tr><td style='padding:6px;font-weight:bold;'>Command</td><td style='padding:6px;font-family:Consolas,monospace;'>$safeCommand</td></tr>" +
        "<tr><td style='padding:6px;font-weight:bold;'>Action</td><td style='padding:6px;'>$safeAction</td></tr>" +
        $jobRow +
        "<tr><td style='padding:6px;font-weight:bold;'>Sender</td><td style='padding:6px;'>$safeRecipient</td></tr>" +
        "<tr><td style='padding:6px;font-weight:bold;'>Result</td><td style='padding:6px;'>$safeMessage</td></tr>" +
        '</table>' +
        $detailSection +
        $duplicateText +
        '</div></body></html>'

    Send-GraphMail -ToRecipients @($Recipient) -Subject $subject -HtmlBody $body
}

$token = Get-GraphAccessToken -Scopes @('https://graph.microsoft.com/Mail.ReadWrite', 'https://graph.microsoft.com/Mail.Send', 'offline_access')
$headers = @{
    Authorization = "Bearer $token"
}

$configContent = Get-ConfigContent
$commandIntakeEnabled = Get-ConfigBooleanValue -Content $configContent -Key 'email_command_intake_enabled' -Default $false
$commandSendReplies = Get-ConfigBooleanValue -Content $configContent -Key 'email_command_send_replies' -Default $true
$commandSubjectPrefix = Get-ConfigTextValue -Content $configContent -Key 'email_command_subject_prefix' -Default 'Autotask Command'
$mailFolderPath = Get-ConfigTextValue -Content $configContent -Key 'email_poll_folder_path' -Default 'Inbox'
$smtpTo = Get-ConfigTextValue -Content $configContent -Key 'smtp_to' -Default ''
$allowedSenders = @(Get-ConfigListValue -Content $configContent -Key 'email_command_allowed_senders')
if ($allowedSenders.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($smtpTo)) {
        $allowedSenders = @($smtpTo.Trim())
    }
}

$mailFolder = Resolve-MailFolder -Headers $headers -FolderPath $mailFolderPath
$uri = "https://graph.microsoft.com/v1.0/me/mailFolders/$($mailFolder.id)/messages?`$select=id,subject,from,receivedDateTime,body,isRead&`$filter=isRead eq false&`$orderby=receivedDateTime desc&`$top=$Top"
$response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
$processed = @()
$commandsProcessed = @()
$rejectedCommands = @()

foreach ($message in @($response.value)) {
    $subject = [string]$message.subject
    $messageId = [string]$message.id
    $sender = if ($message.from.emailAddress.address) { [string]$message.from.emailAddress.address } elseif ($message.sender.emailAddress.address) { [string]$message.sender.emailAddress.address } else { '' }
    $replyText = Get-ReplyText -BodyHtml ([string]$message.body.content)

    $match = [regex]::Match($subject, 'Autotask Input Needed:\s*(?<job>(WI|CS|PRJ)\d{8})\s*\[(?<request>[0-9a-fA-F-]{36})\]', 'IgnoreCase')
    if ($match.Success) {
        $jobNumber = $match.Groups['job'].Value.ToUpperInvariant()
        $requestId = $match.Groups['request'].Value
        if ([string]::IsNullOrWhiteSpace($replyText)) {
            continue
        }

        & (Join-Path $PSScriptRoot 'submit-autotask-user-input.ps1') `
            -JobNumber $jobNumber `
            -RequestId $requestId `
            -Response $replyText `
            -Source email `
            -Responder $sender `
            -MessageId $messageId | Out-Null

        Mark-MessageRead -Headers $headers -MessageId $messageId
        $processed += [PSCustomObject]@{
            jobNumber = $jobNumber
            requestId = $requestId
            from = $sender
            receivedDateTime = [string]$message.receivedDateTime
            messageId = $messageId
        }
        continue
    }

    if (-not $commandIntakeEnabled) {
        continue
    }

    $commandText = Get-CommandTextFromMessage -Subject $subject -ReplyText $replyText -SubjectPrefix $commandSubjectPrefix
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        continue
    }

    if (-not (Test-AllowedSender -Sender $sender -AllowedSenders $allowedSenders)) {
        Mark-MessageRead -Headers $headers -MessageId $messageId
        $replyError = ''
        if ($commandSendReplies) {
            try {
                Send-CommandReplyEmail -Recipient $sender -OriginalCommand $commandText -Success $false -Message 'Sender is not allowlisted for email-command intake.' -SubjectPrefix $commandSubjectPrefix
            } catch {
                $replyError = $_.Exception.Message
            }
        }

        $rejectedCommands += [PSCustomObject]@{
            command = $commandText
            from = $sender
            receivedDateTime = [string]$message.receivedDateTime
            messageId = $messageId
            reason = 'Sender is not allowlisted for email-command intake.'
            replySent = ($commandSendReplies -and ($replyError -eq ''))
            replyError = $replyError
        }
        continue
    }

    $commandResultText = & (Join-Path $PSScriptRoot 'invoke-autotask-command.ps1') `
        -CommandText $commandText `
        -Source 'email-command' `
        -Responder $sender `
        -MessageId $messageId

    $commandResult = if ($commandResultText) { $commandResultText | ConvertFrom-Json } else { $null }
    Mark-MessageRead -Headers $headers -MessageId $messageId

    if ($null -eq $commandResult -or -not $commandResult.success) {
        $replyError = ''
        $replyReason = if ($null -ne $commandResult -and $commandResult.error) { [string]$commandResult.error } else { 'Unknown command failure.' }
        if ($commandSendReplies) {
            try {
                Send-CommandReplyEmail -Recipient $sender -OriginalCommand $commandText -Success $false -Message $replyReason -SubjectPrefix $commandSubjectPrefix
            } catch {
                $replyError = $_.Exception.Message
            }
        }

        $rejectedCommands += [PSCustomObject]@{
            command = $commandText
            from = $sender
            receivedDateTime = [string]$message.receivedDateTime
            messageId = $messageId
            reason = $replyReason
            replySent = ($commandSendReplies -and ($replyError -eq ''))
            replyError = $replyError
        }
        continue
    }

    $successReplyError = ''
    if ($commandSendReplies) {
        try {
            Send-CommandReplyEmail `
                -Recipient $sender `
                -OriginalCommand $commandText `
                -Success $true `
                -Message ([string]$commandResult.message) `
                -SubjectPrefix $commandSubjectPrefix `
                -JobNumber ([string]$commandResult.jobNumber) `
                -Action ([string]$commandResult.action) `
                -Duplicate ([bool]$commandResult.duplicate) `
                -Data (Get-ObjectPropertyValue -Object $commandResult -Name 'data' -Default $null)
        } catch {
            $successReplyError = $_.Exception.Message
        }
    }

    # For status commands, also send Teams notification so the user gets it regardless of where they check
    if ([string]$commandResult.action -eq 'status') {
        $statusData = Get-ObjectPropertyValue -Object $commandResult -Name 'data' -Default $null
        if ($null -ne $statusData) {
            $statusReport = [string](Get-ObjectPropertyValue -Object $statusData -Name 'statusReport' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($statusReport)) {
                $broadcastPayload = [PSCustomObject]@{
                    templateName = 'status-report'
                    data = $statusData
                } | ConvertTo-Json -Depth 20
                $teamsScript = Join-Path $PSScriptRoot 'send-teams-notification.ps1'
                if (Test-Path -LiteralPath $teamsScript) {
                    try { & $teamsScript -JsonPayload $broadcastPayload 2>&1 | Out-Null } catch { }
                }
            }
        }
    }

    $commandsProcessed += [PSCustomObject]@{
        command = $commandText
        action = [string]$commandResult.action
        jobNumber = [string]$commandResult.jobNumber
        from = $sender
        receivedDateTime = [string]$message.receivedDateTime
        messageId = $messageId
        duplicate = [bool]$commandResult.duplicate
        message = [string]$commandResult.message
        replySent = ($commandSendReplies -and ($successReplyError -eq ''))
        replyError = $successReplyError
    }
}

[PSCustomObject]@{
    success = $true
    processed = $processed
    commandsProcessed = $commandsProcessed
    rejectedCommands = $rejectedCommands
} | ConvertTo-Json -Depth 10
