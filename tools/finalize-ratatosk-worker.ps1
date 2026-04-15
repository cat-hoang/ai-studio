[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$JobNumber = '',

    [string]$TaskSequence = '',

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

# Auto-detect JobNumber from workspace directory name if not provided
if ([string]::IsNullOrWhiteSpace($JobNumber)) {
    $dirName = Split-Path -Leaf (Get-Location).Path
    if ($dirName -match '^(WI|CS|PRJ)\d{8}$') {
        $JobNumber = $dirName
    } else {
        throw 'JobNumber not provided and could not be detected from the current directory.'
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
$worker = Get-RatatoskWorker -State $state -JobNumber $JobNumber -TaskSequence $TaskSequence
if (-not $worker) {
    $taskSuffix = if ([string]::IsNullOrWhiteSpace($TaskSequence)) { '' } else { " task $TaskSequence" }
    throw "Worker not found for job $JobNumber$taskSuffix"
}

# Idempotency guard: if this worker was already finalized, abort before sending any notifications.
# Write-RatatoskState runs before notifications, so finalReportedAt is set only when finalize has
# already completed at least through state-write. Re-running notifications would cause duplicates.
$existingFinalReportedAt = [string](Get-ObjectPropertyValue -Object $worker -Name 'finalReportedAt' -Default '')
if (-not [string]::IsNullOrWhiteSpace($existingFinalReportedAt)) {
    $taskSuffix = if ([string]::IsNullOrWhiteSpace($TaskSequence)) { '' } else { " task $TaskSequence" }
    Write-Warning "finalize: $JobNumber$taskSuffix was already finalized at $existingFinalReportedAt — skipping to prevent duplicate notifications."
    return
}

$effectiveWorkspacePath = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath } else { [string]$worker.workspacePath }
if ([string]::IsNullOrWhiteSpace($effectiveWorkspacePath)) {
    throw "Workspace path not available for job $JobNumber"
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
    jobNumber = $JobNumber
    jobGuid = [string]$worker.jobGuid
    taskSequence = [string]$worker.taskSequence
    taskType = [string]$worker.taskType
    zone = if ($null -ne $worker.zone) { [int]$worker.zone } else { 0 }
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

if (-not $PSCmdlet.ShouldProcess($JobNumber, "Finalize worker as $Status")) {
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

# Upload investigation report to ediProd for INV tasks (and incident-investigation work items).
# Best-effort: errors are logged but never break the finalize script.
$taskTypeForUpload = [string]$worker.taskType
$isInvTask = $taskTypeForUpload -eq 'INV'
if ($isInvTask -and $Status -eq 'done' -and -not [string]::IsNullOrWhiteSpace($JobNumber)) {
    try {
        $ediCmd = Get-Command 'edi' -ErrorAction SilentlyContinue
        if ($null -ne $ediCmd) {
            # Look for any HTML report files produced in the workspace
            $reportFiles = @(Get-ChildItem -Path $resolvedWorkspacePath -Filter '*report*.html' -File -ErrorAction SilentlyContinue)
            foreach ($reportFile in $reportFiles) {
                $uploadResult = & edi file upload $JobNumber $reportFile.FullName --type INT 2>&1 | Out-String
                Write-Verbose "finalize: uploaded $($reportFile.Name) to $JobNumber — $uploadResult"
            }
        }
    } catch {
        Write-Warning "finalize: could not upload investigation report to ediProd: $_"
    }
}

# Append completion/failure note to ediProd task — safety net in case the worker didn't do it.
# Best-effort: errors are logged but never break the finalize script.
# Fall back to worker state taskSequence when the parameter was not passed.
$effectiveTaskSequence = if (-not [string]::IsNullOrWhiteSpace($TaskSequence)) { $TaskSequence }
    elseif ($null -ne $worker -and -not [string]::IsNullOrWhiteSpace([string]$worker.taskSequence)) { [string]$worker.taskSequence }
    else { '' }
if (-not [string]::IsNullOrWhiteSpace($JobNumber) -and -not [string]::IsNullOrWhiteSpace($effectiveTaskSequence)) {
    try {
        $ediCmd = Get-Command 'edi' -ErrorAction SilentlyContinue
        if ($null -ne $ediCmd) {
            # Read staffCode from config
            $ratatoskRoot = Get-RatatoskRootPath
            $configBase  = Join-Path $ratatoskRoot 'config.yaml'
            $configLocal = Join-Path $ratatoskRoot 'config.local.yaml'
            $configText  = @($configBase, $configLocal) | Where-Object { Test-Path $_ } |
                           ForEach-Object { Get-Content $_ -Raw } | Join-String -Separator "`n"
            $staffCodeMatch = [regex]::Match($configText, '(?m)^\s*staff_code\s*:\s*[''"]?([^''"\s#]+)[''"]?')
            $staffCode = if ($staffCodeMatch.Success) { $staffCodeMatch.Groups[1].Value.Trim() } else { 'RAT' }

            # Find the taskId matching TaskSequence (jsonl = one flat task per line, easiest to parse)
            $ediListJson = & edi --format jsonl task list $JobNumber 2>&1 | Out-String
            $tasks = @($ediListJson -split "`r?`n" |
                Where-Object { $_ -match '^\s*\{' } |
                ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null } } |
                Where-Object { $_ -ne $null })
            $seqNum = [int]$effectiveTaskSequence
            $matchedTask = $tasks | Where-Object {
                $s = $_.sequence ?? $_.taskSequence ?? $_.seq ?? $_.Sequence
                $null -ne $s -and [int]$s -eq $seqNum
            } | Select-Object -First 1

            if ($null -ne $matchedTask) {
                $taskId = [string]($matchedTask.id ?? $matchedTask.taskId ?? $matchedTask.TaskId)
                if (-not [string]::IsNullOrWhiteSpace($taskId)) {
                    $nowLocal = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    $durationTag = if (-not [string]::IsNullOrWhiteSpace($duration)) { "$duration - " } else { '' }
                    $taskTypeTag = [string]($matchedTask.type ?? $matchedTask.taskType ?? '')

                    $noteLines = [System.Collections.Generic.List[string]]::new()

                    if ($Status -eq 'done') {
                        $noteLines.Add("[$staffCode] Completed: $nowLocal (${durationTag}Ratatosk)")

                        # Summary / root cause — always include
                        if (-not [string]::IsNullOrWhiteSpace($Summary)) {
                            $noteLines.Add($Summary.Trim())
                        }

                        # PR URLs — include for any task that produced them
                        if ($effectivePrUrls.Count -gt 0) {
                            $noteLines.Add("PRs: $($effectivePrUrls -join ', ')")
                        }

                        # Changes list — include for coding tasks
                        if ($changesList.Count -gt 0) {
                            $noteLines.Add("Changes: $($changesList -join '; ')")
                        }

                        # Report path — include for INV tasks
                        if ($taskTypeTag -eq 'INV' -and -not [string]::IsNullOrWhiteSpace($relativeWorkspacePath)) {
                            $reportFiles = @(Get-ChildItem -Path $resolvedWorkspacePath -Filter '*report*.html' -File -ErrorAction SilentlyContinue)
                            if ($reportFiles.Count -gt 0) {
                                $reportNames = $reportFiles | ForEach-Object { Join-Path $relativeWorkspacePath $_.Name }
                                $noteLines.Add("Report: $($reportNames -join ', ')")
                            }
                        }
                    } else {
                        $noteLines.Add("[$staffCode] Failed: $nowLocal (${durationTag}Ratatosk)")
                        $errText = if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { $ErrorMessage.Trim() } else { $Summary.Trim() }
                        if (-not [string]::IsNullOrWhiteSpace($errText)) {
                            $noteLines.Add($errText)
                        }
                        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage) -and -not [string]::IsNullOrWhiteSpace($Summary) -and $ErrorMessage.Trim() -ne $Summary.Trim()) {
                            $noteLines.Add("Summary: $($Summary.Trim())")
                        }
                    }

                    $noteContent = $noteLines -join "`n"
                    # Safety-net deduplication: skip appending if a completion/failure note for this
                    # staff code already exists (e.g. the worker appended notes manually before calling finalize).
                    $existingNotesText = & edi task notes read $taskId 2>&1 | Out-String
                    $completionMarker = if ($Status -eq 'done') { "[$staffCode] Completed:" } else { "[$staffCode] Failed:" }
                    if ($existingNotesText -notmatch [regex]::Escape($completionMarker)) {
                        & edi task notes append $taskId --content $noteContent 2>&1 | Out-Null
                    }
                }
            }
        }
    } catch {
        Write-Warning "finalize: could not append ediProd task note: $_"
    }
}

$toolsDir = Split-Path -Parent $PSCommandPath
$teamsScript = Join-Path $toolsDir 'send-teams-notification.ps1'
$emailScript = Join-Path $toolsDir 'send-email-notification.ps1'

# Resolve zone: use worker value; fall back to default_zone in config when 0
$effectiveZone = if ($null -ne $worker.zone -and [int]$worker.zone -ne 0) { [int]$worker.zone } else { 0 }
if ($effectiveZone -eq 0) {
    try {
        $ratatoskRootForZone = Get-RatatoskRootPath
        $cfgText = @(
            (Join-Path $ratatoskRootForZone 'config.yaml'),
            (Join-Path $ratatoskRootForZone 'config.local.yaml')
        ) | Where-Object { Test-Path $_ } | ForEach-Object { Get-Content $_ -Raw } | Join-String -Separator "`n"
        $zm = [regex]::Match($cfgText, '(?m)^\s*default_zone\s*:\s*(\d+)')
        if ($zm.Success) { $effectiveZone = [int]$zm.Groups[1].Value }
    } catch { }
}

# Resolve GUID: use worker value; fall back to edi CLI lookup
$effectiveJobGuid = [string]$worker.jobGuid
if ([string]::IsNullOrWhiteSpace($effectiveJobGuid)) {
    try {
        $ediCmd2 = Get-Command 'edi' -ErrorAction SilentlyContinue
        if ($null -ne $ediCmd2) {
            $wiJson2 = & edi workitem get $JobNumber --format json 2>$null | Out-String
            if (-not [string]::IsNullOrWhiteSpace($wiJson2)) {
                $wiObj2 = $wiJson2 | ConvertFrom-Json -ErrorAction Stop
                foreach ($doc2 in @($wiObj2.attachedDocuments)) {
                    $m2 = [regex]::Match([string]$doc2.url, 'ediprod:///I(?:WorkItem|SupportIncident|Project)/([0-9a-fA-F\-]{36})/')
                    if ($m2.Success) { $effectiveJobGuid = $m2.Groups[1].Value; break }
                }
            }
        }
    } catch { }
}

if ($Status -eq 'done') {
    $sharedData = @{
        jobNumber = $JobNumber
        jobGuid = $effectiveJobGuid
        jobTitle = [string]$worker.summary
        taskSequence = [string]$worker.taskSequence
        taskType = [string]$worker.taskType
        description = [string]$worker.description
        status = $Status
        prUrls = $effectivePrUrls
        duration = $duration
        zone = $effectiveZone
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
        -JobNumber $JobNumber `
        -JobGuid $effectiveJobGuid `
        -TaskSequence ([string]$worker.taskSequence) `
        -TaskType ([string]$worker.taskType) `
        -ErrorMessage $(if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $Summary.Trim() } else { $ErrorMessage }) `
        -Zone $effectiveZone `
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
    jobNumber = $JobNumber
    status = $Status
    reportPath = $reportPath
    teams = $teamsResult
    email = $emailResult
} | ConvertTo-Json -Depth 20
