[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$IssueId = '',

    [Parameter(Mandatory)]
    [ValidateSet('done', 'failed')]
    [string]$Status,

    [Parameter(Mandatory)]
    [string]$Summary,

    [string[]]$Changes = @(),
    [string[]]$Testing = @(),
    [string[]]$PrUrls = @(),
    [string]$ErrorMessage = '',
    [string]$Logs = '',
    [string]$WorkspacePath = '',
    [string]$StartedAt = '',
    [string]$Timestamp = (Get-Date -Format 'o')
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

function Get-UniqueStringArray {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Values
    )
    if ($null -eq $Values) { return @() }

    return @(
        $Values |
            Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    )
}

function Format-RatatoskDuration {
    param(
        [object]$StartedAt,
        [object]$FinishedAt
    )

    if ($null -eq $StartedAt -or [string]::IsNullOrWhiteSpace([string]$StartedAt)) {
        return ''
    }
    if ($null -eq $FinishedAt -or [string]::IsNullOrWhiteSpace([string]$FinishedAt)) {
        return ''
    }

    try {
        # ConvertFrom-Json deserialises ISO datetime strings as [DateTime] objects.
        # Casting them to [string] via ToString() uses the current culture, producing
        # locale-specific formats (e.g. MM/dd vs dd/MM) that DateTimeOffset.Parse()
        # then re-reads with the system culture — causing a month/day swap on en-AU.
        # Always go through UTC to avoid this ambiguity.
        $start = if ($StartedAt -is [datetimeoffset]) {
            $StartedAt
        } elseif ($StartedAt -is [datetime]) {
            [datetimeoffset]::new($StartedAt.ToUniversalTime(), [timespan]::Zero)
        } else {
            [datetimeoffset]::Parse([string]$StartedAt)
        }
        $end = if ($FinishedAt -is [datetimeoffset]) {
            $FinishedAt
        } elseif ($FinishedAt -is [datetime]) {
            [datetimeoffset]::new($FinishedAt.ToUniversalTime(), [timespan]::Zero)
        } else {
            [datetimeoffset]::Parse([string]$FinishedAt)
        }
    } catch {
        return ''
    }

    $span = $end - $start
    if ($span.TotalMinutes -lt 1) {
        return '0m'
    }

    if ($span.TotalHours -ge 1) {
        return ('{0}h {1}m' -f [math]::Floor($span.TotalHours), $span.Minutes)
    }

    return ('{0}m' -f [math]::Floor($span.TotalMinutes))
}

function Set-OrAddRatatoskJob {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [psobject]$Job
    )

    $jobKey = Get-RatatoskJobObjectKey -Job $Job
    $remaining = @($Items | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $jobKey })
    return @($remaining + $Job)
}

$state = Read-RatatoskState
$worker = Get-RatatoskWorker -State $state -IssueId $IssueId
if (-not $worker) {
    throw "Worker not found for issue $IssueId"
}

# Idempotency guard: if this worker was already finalized, abort before sending any notifications.
$existingFinalReportedAt = [string](Get-ObjectPropertyValue -Object $worker -Name 'finalReportedAt' -Default '')
if (-not [string]::IsNullOrWhiteSpace($existingFinalReportedAt)) {
    Write-Warning "finalize: $IssueId was already finalized at $existingFinalReportedAt — skipping to prevent duplicate notifications."
    return
}

$effectiveWorkspacePath = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath } else { [string]$worker.workspacePath }
if ([string]::IsNullOrWhiteSpace($effectiveWorkspacePath)) {
    throw "Workspace path not available for issue $IssueId"
}
$resolvedWorkspacePath = Resolve-RatatoskPath -Path $effectiveWorkspacePath
$relativeWorkspacePath = ConvertTo-RatatoskRelativePath -Path $resolvedWorkspacePath

$effectivePrUrls = Get-UniqueStringArray -Values @(@($PrUrls) + @(if ($worker.prUrls) { @($worker.prUrls) } else { @() }) + @(if ($worker.prs) { @($worker.prs) } else { @() }))
$effectiveLogs = Get-UniqueStringArray -Values @(
    $(if (-not [string]::IsNullOrWhiteSpace($Logs)) { $Logs })
    @(if ($worker.logs) { @($worker.logs) } else { @() })
)
$changesList = Get-UniqueStringArray -Values $Changes
$testingList = Get-UniqueStringArray -Values $Testing
$finishedPhase = if ($Status -eq 'done') { 'completed' } else { 'failed' }
$activityStatus = if ($Status -eq 'done') { 'completed' } else { 'failed' }

# Safely convert worker.startedAt to UTC ISO string regardless of how ConvertFrom-Json deserialized it.
# ConvertFrom-Json turns ISO datetime strings into [DateTime] objects; [string]$dt then uses DateTime.ToString()
# with InvariantCulture (MM/dd/yyyy) which DateTimeOffset.Parse() on en-AU systems misreads as dd/MM/yyyy.
$rawWorkerStartedAt = $worker.startedAt
$workerStartedAtIso = if ($null -eq $rawWorkerStartedAt -or [string]::IsNullOrWhiteSpace([string]$rawWorkerStartedAt)) {
    ''
} elseif ($rawWorkerStartedAt -is [datetime]) {
    $rawWorkerStartedAt.ToUniversalTime().ToString('o')
} elseif ($rawWorkerStartedAt -is [datetimeoffset]) {
    $rawWorkerStartedAt.UtcDateTime.ToString('o')
} else {
    [string]$rawWorkerStartedAt
}

$effectiveStartedAt = if (-not [string]::IsNullOrWhiteSpace($StartedAt)) { $StartedAt } else { $workerStartedAtIso }
$duration = Format-RatatoskDuration -StartedAt $effectiveStartedAt -FinishedAt $Timestamp
$artifactUsage = Get-ObjectPropertyValue -Object $worker -Name 'artifactUsage' -Default (New-RatatoskArtifactUsage -Branch ([string]$worker.branch) -Timestamp ([string]$worker.startedAt))
$buildPlan = Get-ObjectPropertyValue -Object $worker -Name 'buildPlan' -Default (New-RatatoskBuildPlan -Timestamp ([string]$worker.startedAt))
$buildFailure = Get-ObjectPropertyValue -Object $worker -Name 'buildFailure' -Default (New-RatatoskBuildFailure)

if ($Status -eq 'failed') {
    $existingClassification = [string](Get-ObjectPropertyValue -Object $buildFailure -Name 'classification' -Default 'none')
    if ([string]::IsNullOrWhiteSpace($existingClassification) -or $existingClassification -eq 'none') {
        $failureText = (Get-UniqueStringArray -Values @($ErrorMessage, $Summary, $effectiveLogs)) -join [Environment]::NewLine
        $buildFailure = Get-RatatoskBuildFailureAssessment `
            -FailureText $failureText `
            -Phase ([string]$worker.phase) `
            -TargetProjects @((Get-ObjectPropertyValue -Object $buildPlan -Name 'targetProjects' -Default @())) `
            -FailedProjects @((Get-ObjectPropertyValue -Object $buildFailure -Name 'failedProjects' -Default @())) `
            -TargetTests @((Get-ObjectPropertyValue -Object $buildPlan -Name 'targetTests' -Default @())) `
            -FailedTests @((Get-ObjectPropertyValue -Object $buildFailure -Name 'failedTests' -Default @()))
    }
}

$report = [PSCustomObject]@{
    issueId = $IssueId
    description = [string]$worker.description
    status = $Status
    phase = $finishedPhase
    summary = $Summary.Trim()
    changes = $changesList
    testing = $testingList
    prUrls = $effectivePrUrls
    artifactUsage = $artifactUsage
    buildPlan = $buildPlan
    buildFailure = $buildFailure
    error = $ErrorMessage
    logs = $effectiveLogs
    startedAt = $effectiveStartedAt
    finishedAt = $Timestamp
    duration = $duration
    workspacePath = $relativeWorkspacePath
    branch = [string]$worker.branch
}

if (-not $PSCmdlet.ShouldProcess($IssueId, "Finalize worker as $Status")) {
    return
}

$reportPath = Save-RatatoskWorkspaceArtifact -WorkspacePath $resolvedWorkspacePath -FileName 'final-report.json' -Content $report

Set-RatatoskProperty -Object $worker -Name 'status' -Value $Status
Set-RatatoskProperty -Object $worker -Name 'phase' -Value $finishedPhase
Set-RatatoskProperty -Object $worker -Name 'prUrls' -Value $effectivePrUrls
Set-RatatoskProperty -Object $worker -Name 'prs' -Value $effectivePrUrls
Set-RatatoskProperty -Object $worker -Name 'logs' -Value $effectiveLogs
Set-RatatoskProperty -Object $worker -Name 'error' -Value $ErrorMessage
Set-RatatoskProperty -Object $worker -Name 'artifactUsage' -Value $artifactUsage
Set-RatatoskProperty -Object $worker -Name 'buildPlan' -Value $buildPlan
Set-RatatoskProperty -Object $worker -Name 'buildFailure' -Value $buildFailure
Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value $activityStatus
Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value 'final report captured'
Set-RatatoskProperty -Object $worker -Name 'workspacePath' -Value $relativeWorkspacePath
Set-RatatoskProperty -Object $worker -Name 'finalReportPath' -Value $reportPath
Set-RatatoskProperty -Object $worker -Name 'finalReportSummary' -Value $Summary.Trim()
Set-RatatoskProperty -Object $worker -Name 'finalReportedAt' -Value $Timestamp
Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp $Timestamp

if ($Status -eq 'done') {
    Set-RatatoskProperty -Object $worker -Name 'completedAt' -Value $Timestamp
    $workerKey = Get-RatatoskJobObjectKey -Job $worker
    $state.workers = @($state.workers | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
    $state.failedJobs = @($state.failedJobs | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
    $state.completedJobs = Set-OrAddRatatoskJob -Items $state.completedJobs -Job $worker
} else {
    Set-RatatoskProperty -Object $worker -Name 'failedAt' -Value $Timestamp
    Set-RatatoskProperty -Object $worker -Name 'retryCount' -Value $(
        if ($null -ne $worker.retryCount -and "$($worker.retryCount)".Trim()) { [int]$worker.retryCount } else { 0 }
    )
    $workerKey = Get-RatatoskJobObjectKey -Job $worker
    $state.workers = @($state.workers | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
    $state.completedJobs = @($state.completedJobs | Where-Object { (Get-RatatoskJobObjectKey -Job $_) -ne $workerKey })
    $state.failedJobs = Set-OrAddRatatoskJob -Items $state.failedJobs -Job $worker
}

Write-RatatoskState -State $state

$toolsDir = Split-Path -Parent $PSCommandPath
$teamsScript = Join-Path $toolsDir 'send-teams-notification.ps1'
$emailScript = Join-Path $toolsDir 'send-email-notification.ps1'

if ($Status -eq 'done') {
    $sharedData = @{
        issueId = $IssueId
        jobTitle = [string]$worker.summary
        description = [string]$worker.description
        status = $Status
        prUrls = $effectivePrUrls
        duration = $duration
        summary = $Summary.Trim()
        changes = $changesList
        testing = $testingList
        reportPath = $reportPath
    }

    $teamsResultText = & $teamsScript -JsonPayload (@{
            templateName = 'task-completed'
            data = $sharedData
        } | ConvertTo-Json -Depth 10 -Compress)
    $emailResultText = & $emailScript -JsonPayload (@{
            templateName = 'task-summary'
            data = $sharedData
        } | ConvertTo-Json -Depth 10 -Compress)

    $teamsResult = if ($teamsResultText) { $teamsResultText | ConvertFrom-Json } else { $null }
    $emailResult = if ($emailResultText) { $emailResultText | ConvertFrom-Json } else { $null }

    # Record last email result for auditing in state.json (best-effort)
    try {
        $jobKey = Get-RatatoskJobObjectKey -Job $worker
        $updated = $false
        if ($state.completedJobs) {
            $cj = @($state.completedJobs)
            for ($i = 0; $i -lt $cj.Count; $i++) {
                if ((Get-RatatoskJobObjectKey -Job $cj[$i]) -eq $jobKey) {
                    Set-RatatoskProperty -Object $cj[$i] -Name 'lastEmailResult' -Value $emailResult
                    $state.completedJobs = @($cj)
                    $updated = $true
                    break
                }
            }
        }
        if (-not $updated -and $state.failedJobs) {
            $fj = @($state.failedJobs)
            for ($i = 0; $i -lt $fj.Count; $i++) {
                if ((Get-RatatoskJobObjectKey -Job $fj[$i]) -eq $jobKey) {
                    Set-RatatoskProperty -Object $fj[$i] -Name 'lastEmailResult' -Value $emailResult
                    $state.failedJobs = @($fj)
                    $updated = $true
                    break
                }
            }
        }
        if ($updated) { Write-RatatoskState -State $state }
    } catch {
        Write-Warning "finalize: could not record email result to state: $_"
    }
} else {
    $failureScript = Join-Path $toolsDir 'send-task-failure-notifications.ps1'
    $notificationResult = & $failureScript `
        -IssueId $IssueId `
        -ErrorMessage $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $Summary.Trim() } else { $ErrorMessage }) `
        -Logs ($effectiveLogs -join [Environment]::NewLine) `
        -StartedAt $effectiveStartedAt `
        -Timestamp $Timestamp
    $teamsResult = $notificationResult.teams
    $emailResult = $notificationResult.email

    # Record last email result for auditing in state.json (best-effort)
    try {
        $jobKey = Get-RatatoskJobObjectKey -Job $worker
        $updated = $false
        if ($state.completedJobs) {
            $cj = @($state.completedJobs)
            for ($i = 0; $i -lt $cj.Count; $i++) {
                if ((Get-RatatoskJobObjectKey -Job $cj[$i]) -eq $jobKey) {
                    Set-RatatoskProperty -Object $cj[$i] -Name 'lastEmailResult' -Value $emailResult
                    $state.completedJobs = @($cj)
                    $updated = $true
                    break
                }
            }
        }
        if (-not $updated -and $state.failedJobs) {
            $fj = @($state.failedJobs)
            for ($i = 0; $i -lt $fj.Count; $i++) {
                if ((Get-RatatoskJobObjectKey -Job $fj[$i]) -eq $jobKey) {
                    Set-RatatoskProperty -Object $fj[$i] -Name 'lastEmailResult' -Value $emailResult
                    $state.failedJobs = @($fj)
                    $updated = $true
                    break
                }
            }
        }
        if ($updated) { Write-RatatoskState -State $state }
    } catch {
        Write-Warning "finalize: could not record email result to state: $_"
    }
}

[PSCustomObject]@{
    success = $true
    issueId = $IssueId
    status = $Status
    reportPath = $reportPath
    teams = $teamsResult
    email = $emailResult
} | ConvertTo-Json -Depth 20
