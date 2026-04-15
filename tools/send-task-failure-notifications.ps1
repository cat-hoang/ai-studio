[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [string]$IssueId,

    [Parameter(Mandatory)]
    [string]$ErrorMessage,

    [string]$Logs = '',
    [string]$WorkerName = '',
    [string]$StartedAt = '',
    [string]$Timestamp = (Get-Date -Format 'o')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $PSCommandPath
$teamsScript = Join-Path $toolsDir 'send-teams-notification.ps1'
$emailScript = Join-Path $toolsDir 'send-email-notification.ps1'

if (-not (Test-Path -LiteralPath $teamsScript)) {
    throw "Teams notification script not found: $teamsScript"
}

if (-not (Test-Path -LiteralPath $emailScript)) {
    throw "Email notification script not found: $emailScript"
}

function Invoke-NotificationScript {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [hashtable]$Payload,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $resultText = @(& $ScriptPath -JsonPayload ($Payload | ConvertTo-Json -Depth 10 -Compress))
    if (-not $resultText -or $resultText.Count -eq 0) {
        throw "$Label notification script returned no result."
    }

    $result = $null
    $reversedResultText = @($resultText)
    [array]::Reverse($reversedResultText)

    foreach ($entry in $reversedResultText) {
        if ($null -eq $entry) {
            continue
        }

        try {
            $parsed = $entry | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }

        if ($parsed -and $parsed.PSObject.Properties.Name -contains 'success') {
            $result = $parsed
            break
        }
    }

    if ($null -eq $result) {
        $rawOutput = ($resultText | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "$Label notification script returned no structured result. Output: $rawOutput"
    }

    if (-not [bool]$result.success) {
        $message = if ($result.error) { $result.error } else { 'Unknown notification failure.' }
        throw "$Label notification failed: $message"
    }

    return $result
}

$effectiveDuration = ''
if (-not [string]::IsNullOrWhiteSpace($StartedAt)) {
    try {
        $start = [datetimeoffset]::Parse($StartedAt)
        $end = [datetimeoffset]::Parse($Timestamp)
        $span = $end - $start
        if ($span.TotalMinutes -ge 1) {
            $effectiveDuration = if ($span.TotalHours -ge 1) {
                '{0}h {1}m' -f [math]::Floor($span.TotalHours), $span.Minutes
            } else {
                '{0}m' -f [math]::Floor($span.TotalMinutes)
            }
        }
    } catch { }
}

$sharedData = @{
    issueId = $IssueId
    error = $ErrorMessage
    logs = $Logs
    worker = $WorkerName
    timestamp = $Timestamp
    duration = $effectiveDuration
}

$teamsPayload = @{
    templateName = 'task-failed'
    data = $sharedData
}

$emailPayload = @{
    templateName = 'failed-alert'
    data = $sharedData
}

if ($PSCmdlet.ShouldProcess($IssueId, 'Send Teams and email failure notifications')) {
    $teamsResult = Invoke-NotificationScript -ScriptPath $teamsScript -Payload $teamsPayload -Label 'Teams'
    $emailResult = Invoke-NotificationScript -ScriptPath $emailScript -Payload $emailPayload -Label 'Email'

    [PSCustomObject]@{
        success = $true
        issueId = $IssueId
        teams = $teamsResult
        email = $emailResult
    }
}
