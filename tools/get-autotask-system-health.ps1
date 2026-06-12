<#
.SYNOPSIS
Returns a structured Autotask readiness and health snapshot.

.DESCRIPTION
Reads merged Autotask configuration and current state to report whether the
local environment is ready, degraded, or blocked. The script is designed as a
shared primitive for preflight, wrapup, and dashboard health surfacing.

.OUTPUTS
PSCustomObject. Includes status, configuration, tool availability, notification
configuration, state-derived warnings, and any blocking reasons.

.EXAMPLE
.\tools\get-autotask-system-health.ps1 | ConvertTo-Json -Depth 10
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')

function Get-ConfigContent {
    $autotaskRoot = Get-AutotaskRootPath
    $paths = @(
        (Join-Path $autotaskRoot 'config.yaml'),
        (Join-Path $autotaskRoot 'config.local.yaml')
    )

    $chunks = foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path -Raw -Encoding UTF8
        }
    }

    return ($chunks -join [Environment]::NewLine)
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    $pattern = '{0}:\s*"?([^"\r\n]*)"?' -f [regex]::Escape($Key)
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -eq 0) {
        return $Default
    }

    return $matches[$matches.Count - 1].Groups[1].Value.Trim().Trim('"').Trim("'")
}

function Get-ConfigNumber {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [int]$Default
    )

    $value = Get-ConfigValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-ArrayValue {
    param(
        [Parameter(Mandatory)]
        $Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
        return @($Value)
    }

    return @($Value)
}

function Get-StaleWorkerCount {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Workers,

        [Parameter(Mandatory)]
        [int]$WorkerStaleGraceMs
    )

    $now = [DateTimeOffset]::UtcNow
    $count = 0
    foreach ($worker in $Workers) {
        $status = [string]$worker.status
        if ($status -eq 'paused') {
            continue
        }

        $heartbeatValue = ''
        if ($worker.PSObject.Properties['lastHeartbeatAt']) {
            $heartbeatValue = $worker.lastHeartbeatAt
        } elseif ($worker.PSObject.Properties['lastUpdated']) {
            $heartbeatValue = $worker.lastUpdated
        } else {
            $heartbeatValue = $worker.startedAt
        }
        $heartbeatText = [string]$heartbeatValue

        if ([string]::IsNullOrWhiteSpace($heartbeatText)) {
            continue
        }

        try {
            $heartbeat = [DateTimeOffset]::Parse($heartbeatText)
        } catch {
            continue
        }

        if (($now - $heartbeat).TotalMilliseconds -gt $WorkerStaleGraceMs) {
            $count++
        }
    }

    return $count
}

function Get-CleanupBlockedCount {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Jobs
    )

    return @(
        $Jobs | Where-Object {
            $_ -and (
                ($_.PSObject.Properties['cleanupBlockedReason'] -and -not [string]::IsNullOrWhiteSpace([string]$_.cleanupBlockedReason)) -or
                ([string]$_.activityMessage -match 'cleanup blocked')
            )
        }
    ).Count
}

function Get-RecentTokenError {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    $history = @(Get-ArrayValue -Value $State.commandHistory)
    foreach ($entry in ($history | Select-Object -Last 20)) {
        $message = if ($entry.PSObject.Properties['error']) { [string]$entry.error } else { '' }
        if ($message -match 'token is expired|linked token is expired') {
            return $message
        }
    }

    return ''
}

function Main {
    $configContent = Get-ConfigContent
    $state = Read-AutotaskState
    $workers = @(Get-ArrayValue -Value $state.workers)
    $completedJobs = @(Get-ArrayValue -Value $state.completedJobs)
    $failedJobs = @(Get-ArrayValue -Value $state.failedJobs)
    $workerCli = Get-ConfigValue -Content $configContent -Key 'worker_cli' -Default 'claude'
    $workerStaleGraceMs = Get-ConfigNumber -Content $configContent -Key 'worker_stale_grace_ms' -Default 1800000
    $teamsWebhookConfigured = -not [string]::IsNullOrWhiteSpace((Get-ConfigValue -Content $configContent -Key 'teams_webhook_url'))
    $teamsWebhookEnabled = (Get-ConfigValue -Content $configContent -Key 'teams_webhook_enabled' -Default 'true').ToLowerInvariant() -ne 'false'
    $teamsWebhookActive = $teamsWebhookConfigured -and $teamsWebhookEnabled
    $teamsChatEnabled = ((Get-ConfigValue -Content $configContent -Key 'teams_chat_enabled' -Default 'false').ToLowerInvariant() -eq 'true')
    $teamsChatTargetMode = (Get-ConfigValue -Content $configContent -Key 'teams_chat_target_mode' -Default 'self').ToLowerInvariant()
    $teamsChatTarget = Get-ConfigValue -Content $configContent -Key 'teams_chat_target'
    $teamsChatConfigured = $teamsChatEnabled -and (
        $teamsChatTargetMode -eq 'self' -or
        -not [string]::IsNullOrWhiteSpace($teamsChatTarget)
    )
    $teamsConfigured = $teamsWebhookActive -or $teamsChatConfigured
    $teamsChannel = if ($teamsChatConfigured -and $teamsWebhookActive) {
        'chat + webhook'
    } elseif ($teamsChatConfigured) {
        'chat'
    } elseif ($teamsWebhookActive) {
        'webhook'
    } else {
        'not configured'
    }
    $emailConfigured = (
        -not [string]::IsNullOrWhiteSpace((Get-ConfigValue -Content $configContent -Key 'smtp_from')) -and
        -not [string]::IsNullOrWhiteSpace((Get-ConfigValue -Content $configContent -Key 'smtp_to'))
    )

    $requiredTools = [ordered]@{
        node = Test-CommandAvailable -Name 'node'
        git = Test-CommandAvailable -Name 'git'
        gh = Test-CommandAvailable -Name 'gh'
        wt = Test-CommandAvailable -Name 'wt.exe'
    }

    switch ($workerCli.ToLowerInvariant()) {
        'copilot' { $requiredTools['copilot'] = Test-CommandAvailable -Name 'copilot' }
        'claude' { $requiredTools['claude'] = Test-CommandAvailable -Name 'claude' }
        default {
            $requiredTools['claudeOrCopilot'] = (
                (Test-CommandAvailable -Name 'claude') -or
                (Test-CommandAvailable -Name 'copilot')
            )
        }
    }

    $blockingReasons = @()
    foreach ($tool in $requiredTools.GetEnumerator()) {
        if (-not $tool.Value) {
            $blockingReasons += "Missing required tool: $($tool.Key)"
        }
    }

    $staleWorkers = Get-StaleWorkerCount -Workers $workers -WorkerStaleGraceMs $workerStaleGraceMs
    $cleanupBlocked = (Get-CleanupBlockedCount -Jobs $completedJobs) + (Get-CleanupBlockedCount -Jobs $failedJobs)
    $recentTokenError = Get-RecentTokenError -State $state

    $warnings = @()
    if (-not $teamsConfigured) { $warnings += 'Teams notifications are not configured.' }
    if (-not $emailConfigured) { $warnings += 'Email notifications are not configured.' }
    if ($staleWorkers -gt 0) { $warnings += "$staleWorkers worker(s) appear stale." }
    if ($cleanupBlocked -gt 0) { $warnings += "$cleanupBlocked completed/failed job(s) have cleanup blockers." }
    if (-not [string]::IsNullOrWhiteSpace($recentTokenError)) { $warnings += $recentTokenError }

    $status = if ($blockingReasons.Count -gt 0) {
        'blocked'
    } elseif ($warnings.Count -gt 0) {
        'degraded'
    } else {
        'ready'
    }

    [PSCustomObject]@{
        status = $status
        checkedAt = (Get-Date).ToUniversalTime().ToString('o')
        workerCli = $workerCli
        tools = [PSCustomObject]$requiredTools
        notifications = [PSCustomObject]@{
            teamsConfigured = $teamsConfigured
            teamsWebhookConfigured = $teamsWebhookConfigured
            teamsChatConfigured = $teamsChatConfigured
            teamsChannel = $teamsChannel
            emailConfigured = $emailConfigured
        }
        state = [PSCustomObject]@{
            workers = $workers.Count
            completedJobs = $completedJobs.Count
            failedJobs = $failedJobs.Count
            staleWorkers = $staleWorkers
            cleanupBlocked = $cleanupBlocked
        }
        warnings = $warnings
        blockingReasons = $blockingReasons
    } | ConvertTo-Json -Depth 10
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
