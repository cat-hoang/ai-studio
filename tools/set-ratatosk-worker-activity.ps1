[CmdletBinding()]
param(
    [string]$IssueId = '',

    [Alias('Activity')]
    [ValidateSet(
        'starting',
        'workspace-verify',
        'syncing',
        'planning',
        'thinking',
        'researching',
        'triaging',
        'designing',
        'implementing',
        'coding',
        'building',
        'validating',
        'testing',
        'documenting',
        'reviewing',
        'creating-pr',
        'waiting-review',
        'awaiting-user-input',
        'input-received',
        'retrying',
        'blocked',
        'completed',
        'failed'
    )]
    [string]$ActivityStatus,

    [Alias('Detail', 'Message')]
    [string]$ActivityMessage = '',
    [string]$Phase = '',
    [string]$Status = '',
    [string]$Description = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

# Auto-detect IssueId from workspace directory name if not provided
if ([string]::IsNullOrWhiteSpace($IssueId)) {
    $IssueId = Split-Path -Leaf (Get-Location).Path
    if ([string]::IsNullOrWhiteSpace($IssueId)) {
        throw 'IssueId not provided and could not be detected from the current directory.'
    }
}

$state = Read-RatatoskState
$worker = Get-RatatoskWorker -State $state -IssueId $IssueId
if (-not $worker) {
    throw "Worker not found for issue $IssueId"
}

Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value $ActivityStatus
Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value $ActivityMessage
$timestamp = Get-Date -Format 'o'
Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp $timestamp

if (-not [string]::IsNullOrWhiteSpace($Phase)) {
    Set-RatatoskProperty -Object $worker -Name 'phase' -Value $Phase
}

if (-not [string]::IsNullOrWhiteSpace($Status)) {
    Set-RatatoskProperty -Object $worker -Name 'status' -Value $Status
}

if (-not [string]::IsNullOrWhiteSpace($Description)) {
    # Only fill in description/summary when not already set — never overwrite the WI title.
    $existingDesc = [string](Get-ObjectPropertyValue -Object $worker -Name 'description' -Default '')
    $existingSummary = [string](Get-ObjectPropertyValue -Object $worker -Name 'summary' -Default '')
    if ([string]::IsNullOrWhiteSpace($existingDesc)) {
        Set-RatatoskProperty -Object $worker -Name 'description' -Value $Description
    }
    if ([string]::IsNullOrWhiteSpace($existingSummary)) {
        Set-RatatoskProperty -Object $worker -Name 'summary' -Value $Description
    }
}

Write-RatatoskState -State $state
$worker | ConvertTo-Json -Depth 20
