[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = '',
    [string]$Source = 'manual-resume',
    # When set, skip all state manipulation and only write the prompt file + launch the
    # worker tab. Used by the dashboard /api/reopen endpoint which already moved the state.
    [switch]$LaunchOnly,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

function Get-FirstNonEmptyValue {
    param(
        [string[]]$Values
    )

    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ''
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-ResumePromptContent {
    param(
        [Parameter(Mandatory)]
        [psobject]$Worker,

        [Parameter(Mandatory)]
        [string]$WorkspaceRelativePath
    )

    $jobNumber = [string](Get-ObjectPropertyValue -Object $Worker -Name 'jobNumber' -Default '')
    $taskType = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'taskType' -Default ''),
        'unknown'
    )
    $taskSequence = [string](Get-ObjectPropertyValue -Object $Worker -Name 'taskSequence' -Default '')
    $zoneValue = Get-ObjectPropertyValue -Object $Worker -Name 'zone' -Default 0
    $zone = if ($null -ne $zoneValue -and "$zoneValue".Trim()) { [int]$zoneValue } else { 0 }
    $description = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'description' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'summary' -Default ''),
        $jobNumber
    )
    $existingPrUrls = @(Get-RatatoskUniqueStringArray -Values @((Get-ObjectPropertyValue -Object $Worker -Name 'prUrls' -Default @())))
    $repos = @(Get-RatatoskUniqueStringArray -Values @((Get-ObjectPropertyValue -Object $Worker -Name 'repos' -Default @())))
    $repoGroup = [string](Get-ObjectPropertyValue -Object $Worker -Name 'repoGroup' -Default '')
    $selectionMode = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'batchSelectionMode' -Default ''),
        'resume'
    )
    $selectionReason = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'batchSelectionReason' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'activityMessage' -Default ''),
        'Resuming paused work from retained workspace.'
    )
    $branch = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Worker -Name 'branch' -Default ''),
        'current workspace branch'
    )
    $finalSummary = [string](Get-ObjectPropertyValue -Object $Worker -Name 'finalReportSummary' -Default '')
    $elapsedMsOffset = [double](Get-ObjectPropertyValue -Object $Worker -Name 'elapsedMsOffset' -Default 0)

    @"
You are Ratatosk Task Worker for $jobNumber ($taskType).
Read your full instructions from `..\..\agents\task-worker.md`.
Your workspace is $WorkspaceRelativePath.
Your job number is $jobNumber, task sequence is $taskSequence, task type is $taskType, zone is $zone.
Prior elapsed time from previous sessions: ${elapsedMsOffset}ms — pass this as -PriorElapsedMs when appending finished/failed notes to get cumulative total.
Task description: $description
Existing PR URLs: $(if ($existingPrUrls.Count -gt 0) { $existingPrUrls -join ', ' } else { '(none)' })
Preferred repo branches: $branch
Selected repos: $(if ($repos.Count -gt 0) { $repos -join ', ' } else { '(use existing workspace repos)' })
Repo selection: $(if (-not [string]::IsNullOrWhiteSpace($repoGroup)) { "$repoGroup ($selectionMode)" } else { $selectionMode })
Repo selection reason: $selectionReason
Previous final summary: $(if (-not [string]::IsNullOrWhiteSpace($finalSummary)) { $finalSummary } else { '(none)' })
Keep the existing terminal tab title exactly as launched. Do not rename the terminal tab or set an application title.
Publish your live activity via `..\..\tools\set-ratatosk-worker-activity.ps1` using granular statuses such as starting, workspace-verify, syncing, planning, thinking, researching, triaging, designing, implementing, coding, building, validating, testing, documenting, reviewing, creating-pr, waiting-review, awaiting-user-input, input-received, retrying, blocked, completed, and failed. Update it often whenever your actual work changes.
When you choose a build/test scope or reuse/download shared Crikey artifacts, record it with `..\..\tools\update-ratatosk-build-plan.ps1` so Ratatosk can track targeted plans and shared artifact usage.
If a build or test failure appears unrelated to your targeted scope, environment, or baseline artifacts, run `..\..\tools\classify-ratatosk-build-failure.ps1` before finalizing so the failure is labelled correctly.
If you need a user decision, use `..\..\tools\request-ratatosk-user-input.ps1` and then wait with `..\..\tools\wait-for-ratatosk-user-input.ps1`.
When you finish or fail, do not stop silently. Run `..\..\tools\finalize-ratatosk-worker.ps1 -TaskSequence $taskSequence` (when task sequence is known) so Ratatosk always captures a final report, updates temp/state.json, and sends the completion or failure report.
Resume the paused work from the retained workspace and continue immediately.
"@
}

function Main {
    $resolvedJobNumber = $JobNumber.Trim().ToUpperInvariant()
    if ($resolvedJobNumber -notmatch '^(WI|CS|PRJ)\d{8}$') {
        throw "Invalid job number: $JobNumber"
    }

    $state = Read-RatatoskState
    $matchingWorkers = @($state.workers | Where-Object { Test-RatatoskJobMatch -Job $_ -JobNumber $resolvedJobNumber -TaskSequence $TaskSequence })
    $pausedWorkers = @($matchingWorkers | Where-Object {
            ([string](Get-ObjectPropertyValue -Object $_ -Name 'status' -Default '')).ToLowerInvariant() -eq 'paused' -or
            ([string](Get-ObjectPropertyValue -Object $_ -Name 'activityStatus' -Default '')).ToLowerInvariant() -eq 'paused'
        })
    $completedWorkers = @($state.completedJobs | Where-Object { Test-RatatoskJobMatch -Job $_ -JobNumber $resolvedJobNumber -TaskSequence $TaskSequence })
    $failedWorkers = @($state.failedJobs | Where-Object { Test-RatatoskJobMatch -Job $_ -JobNumber $resolvedJobNumber -TaskSequence $TaskSequence })

    $workerBucket = ''
    $worker = $null
    if ($pausedWorkers.Count -gt 0) {
        $workerBucket = 'workers'
        $worker = $pausedWorkers | Select-Object -First 1
    } elseif ($completedWorkers.Count -gt 0) {
        $workerBucket = 'completedJobs'
        $worker = $completedWorkers | Select-Object -First 1
    } elseif ($failedWorkers.Count -gt 0) {
        $workerBucket = 'failedJobs'
        $worker = $failedWorkers | Select-Object -First 1
    } elseif ($matchingWorkers.Count -gt 0) {
        throw "$resolvedJobNumber already has an active worker."
    } else {
        throw "$resolvedJobNumber does not have a worker to resume."
    }

    $status = [string](Get-ObjectPropertyValue -Object $worker -Name 'status' -Default '')
    $phase = [string](Get-ObjectPropertyValue -Object $worker -Name 'phase' -Default '')
    $activityStatus = [string](Get-ObjectPropertyValue -Object $worker -Name 'activityStatus' -Default '')
    $statusKey = $status.ToLowerInvariant()
    $phaseKey = $phase.ToLowerInvariant()
    $activityStatusKey = $activityStatus.ToLowerInvariant()

    $workspacePath = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $worker -Name 'workspacePath' -Default ''),
        ('workspaces\' + $resolvedJobNumber)
    )
    $resolvedWorkspacePath = Resolve-RatatoskPath -Path $workspacePath
    if (-not (Test-Path -LiteralPath $resolvedWorkspacePath)) {
        throw "Workspace path not found for ${resolvedJobNumber}: $resolvedWorkspacePath"
    }

    $workspaceRelativePath = ConvertTo-RatatoskRelativePath -Path $resolvedWorkspacePath
    $promptFilePath = Join-Path $resolvedWorkspacePath '.ratatosk-prompt.md'
    $promptContent = New-ResumePromptContent -Worker $worker -WorkspaceRelativePath $workspaceRelativePath
    Write-Utf8File -Path $promptFilePath -Content $promptContent
    $taskType = Get-FirstNonEmptyValue -Values @([string](Get-ObjectPropertyValue -Object $worker -Name 'taskType' -Default ''), 'unknown')
    $zoneRaw = Get-ObjectPropertyValue -Object $worker -Name 'zone' -Default $null
    $zone = if ($null -ne $zoneRaw -and "$zoneRaw".Trim()) { [int]$zoneRaw } else { 0 }

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $sourceText = Get-FirstNonEmptyValue -Values @($Source, 'manual-resume')
    $sources = @(Get-RatatoskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $worker -Name 'sources' -Default @()),
        @($sourceText)
    ))

    Set-RatatoskProperty -Object $worker -Name 'status' -Value 'running'
    Set-RatatoskProperty -Object $worker -Name 'phase' -Value 'starting'
    Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value 'starting'
    $resumeActivityMessage = if ($statusKey -eq 'done' -or $statusKey -eq 'completed' -or $phaseKey -eq 'completed') {
        'Relaunching retained workspace after previous completion.'
    } else {
        'Launching resumed worker from retained workspace.'
    }
    Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value $resumeActivityMessage
    Set-RatatoskProperty -Object $worker -Name 'source' -Value $sourceText
    Set-RatatoskProperty -Object $worker -Name 'sources' -Value $sources
    Set-RatatoskProperty -Object $worker -Name 'queuedVia' -Value $sourceText
    Set-RatatoskProperty -Object $worker -Name 'queuedAt' -Value $timestamp

    # Accumulate elapsed time from the completed/failed session before clearing the timestamps.
    # This preserves total working time across multiple Reopen cycles. The gap between completedAt
    # and the new startedAt is intentionally excluded — it was idle time, not work time.
    if ($workerBucket -ne 'workers') {
        $prevStartedAt = [string](Get-ObjectPropertyValue -Object $worker -Name 'startedAt' -Default '')
        $prevCompletedAt = [string](Get-ObjectPropertyValue -Object $worker -Name 'completedAt' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($prevStartedAt) -and -not [string]::IsNullOrWhiteSpace($prevCompletedAt)) {
            try {
                $prevStart = [datetimeoffset]::Parse($prevStartedAt)
                $prevEnd   = [datetimeoffset]::Parse($prevCompletedAt)
                $sessionMs = ($prevEnd - $prevStart).TotalMilliseconds
                if ($sessionMs -gt 0) {
                    $existingOffsetMs = [double](Get-ObjectPropertyValue -Object $worker -Name 'elapsedMsOffset' -Default 0)
                    Set-RatatoskProperty -Object $worker -Name 'elapsedMsOffset' -Value ([math]::Round($existingOffsetMs + $sessionMs))
                }
            } catch {
                # Non-fatal: if timestamps can't be parsed, skip accumulation and continue.
            }
        }
    }

    Set-RatatoskProperty -Object $worker -Name 'startedAt' -Value $timestamp
    Set-RatatoskProperty -Object $worker -Name 'completedAt' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'error' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'finalReportedAt' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'finalReportSummary' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'cleanupBlockedAt' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'cleanupBlockedReason' -Value ''
    Set-RatatoskProperty -Object $worker -Name 'userInputRequest' -Value $null
    Set-RatatoskProperty -Object $worker -Name 'lastUserInput' -Value $null
    if (-not (Get-ObjectPropertyValue -Object $worker -Name 'artifactUsage' -Default $null)) {
        Set-RatatoskProperty -Object $worker -Name 'artifactUsage' -Value (New-RatatoskArtifactUsage -Timestamp $timestamp)
    }
    if (-not (Get-ObjectPropertyValue -Object $worker -Name 'buildPlan' -Default $null)) {
        Set-RatatoskProperty -Object $worker -Name 'buildPlan' -Value (New-RatatoskBuildPlan -Timestamp $timestamp)
    }
    if (-not (Get-ObjectPropertyValue -Object $worker -Name 'buildFailure' -Default $null)) {
        Set-RatatoskProperty -Object $worker -Name 'buildFailure' -Value (New-RatatoskBuildFailure -Timestamp $timestamp)
    }
    Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp $timestamp
    $workerKey = Get-RatatoskJobObjectKey -Job $worker
    $originalWorkers = @($state.workers)
    $originalCompletedJobs = @($state.completedJobs)
    $originalFailedJobs = @($state.failedJobs)
    if ($workerBucket -ne 'workers') {
        $state.workers = @($state.workers | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey }) + $worker
        $state.completedJobs = @($state.completedJobs | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
        $state.failedJobs = @($state.failedJobs | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
    }
    Write-RatatoskState -State $state

    $launchResult = $null
    try {
        $launchResult = & (Join-Path $PSScriptRoot 'launch-ratatosk-worker.ps1') `
            -Cli 'auto' `
            -JobNumber $resolvedJobNumber `
            -TaskType $taskType `
            -Zone $zone `
            -WorkspacePath $resolvedWorkspacePath `
            -PromptFile $promptFilePath `
            -PluginDir (Get-RatatoskRootPath) `
            -PassThru
    } catch {
        Set-RatatoskProperty -Object $worker -Name 'status' -Value 'paused'
        Set-RatatoskProperty -Object $worker -Name 'phase' -Value 'paused'
        Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value 'paused'
        Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value 'Resume launch failed; worker remains paused.'
        Set-RatatoskProperty -Object $worker -Name 'error' -Value $_.Exception.Message
        Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp ((Get-Date).ToUniversalTime().ToString('o'))
        if ($workerBucket -ne 'workers') {
            $state.workers = $originalWorkers
            $state.completedJobs = $originalCompletedJobs
            $state.failedJobs = $originalFailedJobs
        }
        Write-RatatoskState -State $state
        throw
    }

    $result = [PSCustomObject]@{
        success = $true
        jobNumber = $resolvedJobNumber
        mode = 'resume'
        workerCli = if ($launchResult) { [string]$launchResult.Cli } else { 'auto' }
        workspacePath = $workspaceRelativePath
        promptFile = (ConvertTo-RatatoskRelativePath -Path $promptFilePath)
        launched = $true
        message = "Resumed worker for $resolvedJobNumber."
    }

    $json = $result | ConvertTo-Json -Depth 10
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output $json

    if ($PassThru) {
        [PSCustomObject]@{
            Json = $json
            Result = $result
        }
    }
}

# MainLaunchOnly: skips all state manipulation. The dashboard /api/reopen endpoint already
# moved the job to workers before calling this. We only write the prompt file and launch.
function MainLaunchOnly {
    $resolvedJobNumber = $JobNumber.Trim().ToUpperInvariant()

    $state = Read-RatatoskState
    $worker = @($state.workers | Where-Object { Test-RatatoskJobMatch -Job $_ -JobNumber $resolvedJobNumber -TaskSequence $TaskSequence }) | Select-Object -First 1
    if (-not $worker) {
        throw "$resolvedJobNumber was not found in workers (state may not have been updated yet)."
    }

    $workspacePath = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $worker -Name 'workspacePath' -Default ''),
        ('workspaces\' + $resolvedJobNumber)
    )
    $resolvedWorkspacePath = Resolve-RatatoskPath -Path $workspacePath
    if (-not (Test-Path -LiteralPath $resolvedWorkspacePath)) {
        throw "Workspace path not found for ${resolvedJobNumber}: $resolvedWorkspacePath"
    }

    $workspaceRelativePath = ConvertTo-RatatoskRelativePath -Path $resolvedWorkspacePath
    $promptFilePath = Join-Path $resolvedWorkspacePath '.ratatosk-prompt.md'
    $promptContent = New-ResumePromptContent -Worker $worker -WorkspaceRelativePath $workspaceRelativePath
    Write-Utf8File -Path $promptFilePath -Content $promptContent

    $taskType = Get-FirstNonEmptyValue -Values @([string](Get-ObjectPropertyValue -Object $worker -Name 'taskType' -Default ''), 'unknown')
    $zoneRaw = Get-ObjectPropertyValue -Object $worker -Name 'zone' -Default $null
    $zone = if ($null -ne $zoneRaw -and "$zoneRaw".Trim()) { [int]$zoneRaw } else { 0 }

    $launchResult = & (Join-Path $PSScriptRoot 'launch-ratatosk-worker.ps1') `
        -Cli 'auto' `
        -JobNumber $resolvedJobNumber `
        -TaskType $taskType `
        -Zone $zone `
        -WorkspacePath $resolvedWorkspacePath `
        -PromptFile $promptFilePath `
        -PluginDir (Get-RatatoskRootPath) `
        -PassThru

    $result = [PSCustomObject]@{
        success       = $true
        jobNumber     = $resolvedJobNumber
        mode          = 'reopen-launch'
        workerCli     = if ($launchResult) { [string]$launchResult.Cli } else { 'auto' }
        workspacePath = $workspaceRelativePath
        promptFile    = (ConvertTo-RatatoskRelativePath -Path $promptFilePath)
        launched      = $true
        message       = "Launched worker tab for $resolvedJobNumber."
    }

    $json = $result | ConvertTo-Json -Depth 10
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output $json
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($LaunchOnly) {
        MainLaunchOnly
    } else {
        Main
    }
}
