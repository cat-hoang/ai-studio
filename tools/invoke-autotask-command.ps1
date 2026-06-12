[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CommandText,

    [string]$Source = 'manual',
    [string]$Responder = '',
    [string]$MessageId = '',
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')

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

function Ensure-CommandHistory {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    if (-not $State.PSObject.Properties['commandHistory']) {
        Set-AutotaskProperty -Object $State -Name 'commandHistory' -Value @()
    }
}

function Get-CommandHistoryEntry {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [string]$MessageId
    )

    if ([string]::IsNullOrWhiteSpace($MessageId)) {
        return $null
    }

    Ensure-CommandHistory -State $State
    return @($State.commandHistory | Where-Object { $_.messageId -eq $MessageId }) | Select-Object -First 1
}

function Add-CommandHistoryEntry {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [object]$Entry
    )

    Ensure-CommandHistory -State $State
    $history = @($State.commandHistory) + @($Entry)
    if ($history.Count -gt 100) {
        $history = @($history | Select-Object -Last 100)
    }

    Set-AutotaskProperty -Object $State -Name 'commandHistory' -Value $history
}

function Get-JobStateEntry {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [string]$JobNumber,

        [string]$TaskSequence = ''
    )

    foreach ($bucketName in @('waitingQueue', 'workers', 'completedJobs', 'failedJobs')) {
        $job = @($State.$bucketName | Where-Object { Test-AutotaskJobMatch -Job $_ -JobNumber $JobNumber -TaskSequence $TaskSequence }) | Select-Object -First 1
        if ($job) {
            return [PSCustomObject]@{
                bucketName = $bucketName
                job = $job
            }
        }
    }

    return $null
}

function Remove-JobFromBucket {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [string]$BucketName,

        [Parameter(Mandatory)]
        [string]$JobNumber,

        [string]$TaskSequence = ''
    )

    $items = @($State.$BucketName | Where-Object { -not (Test-AutotaskJobMatch -Job $_ -JobNumber $JobNumber -TaskSequence $TaskSequence) })
    Set-AutotaskProperty -Object $State -Name $BucketName -Value $items
}

function ConvertTo-StatusJobSummary {
    param(
        [Parameter(Mandatory)]
        [object]$Job,

        [Parameter(Mandatory)]
        [string]$Bucket
    )

    return [PSCustomObject]@{
        jobNumber = [string](Get-ObjectPropertyValue -Object $Job -Name 'jobNumber' -Default '')
        jobGuid = [string](Get-ObjectPropertyValue -Object $Job -Name 'jobGuid' -Default '')
        taskSequence = [string](Get-ObjectPropertyValue -Object $Job -Name 'taskSequence' -Default '')
        taskType = [string](Get-ObjectPropertyValue -Object $Job -Name 'taskType' -Default '')
        summary = Get-FirstNonEmptyValue -Values @(
            [string](Get-ObjectPropertyValue -Object $Job -Name 'summary' -Default ''),
            [string](Get-ObjectPropertyValue -Object $Job -Name 'description' -Default ''),
            [string](Get-ObjectPropertyValue -Object $Job -Name 'jobNumber' -Default '')
        )
        description = [string](Get-ObjectPropertyValue -Object $Job -Name 'description' -Default '')
        zone = if ($null -ne (Get-ObjectPropertyValue -Object $Job -Name 'zone' -Default $null) -and "$((Get-ObjectPropertyValue -Object $Job -Name 'zone' -Default ''))".Trim()) { [int](Get-ObjectPropertyValue -Object $Job -Name 'zone' -Default 0) } else { 0 }
        bucket = $Bucket
        status = [string](Get-ObjectPropertyValue -Object $Job -Name 'status' -Default '')
        phase = [string](Get-ObjectPropertyValue -Object $Job -Name 'phase' -Default '')
        activityStatus = [string](Get-ObjectPropertyValue -Object $Job -Name 'activityStatus' -Default '')
        activityMessage = [string](Get-ObjectPropertyValue -Object $Job -Name 'activityMessage' -Default '')
        source = [string](Get-ObjectPropertyValue -Object $Job -Name 'source' -Default '')
        sources = @((Get-ObjectPropertyValue -Object $Job -Name 'sources' -Default @()))
        queuedAt = [string](Get-ObjectPropertyValue -Object $Job -Name 'queuedAt' -Default '')
        startedAt = [string](Get-ObjectPropertyValue -Object $Job -Name 'startedAt' -Default '')
        completedAt = [string](Get-ObjectPropertyValue -Object $Job -Name 'completedAt' -Default '')
        prUrls = @((Get-ObjectPropertyValue -Object $Job -Name 'prUrls' -Default @()))
        workspacePath = [string](Get-ObjectPropertyValue -Object $Job -Name 'workspacePath' -Default '')
        branch = [string](Get-ObjectPropertyValue -Object $Job -Name 'branch' -Default '')
        error = [string](Get-ObjectPropertyValue -Object $Job -Name 'error' -Default '')
        finalReportSummary = [string](Get-ObjectPropertyValue -Object $Job -Name 'finalReportSummary' -Default '')
        neverAutoStart = [bool](Get-ObjectPropertyValue -Object $Job -Name 'neverAutoStart' -Default $false)
    }
}

function Get-StartableJobsSnapshot {
    $scriptPath = Join-Path $PSScriptRoot 'get-autotask-startable-jobs.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [PSCustomObject]@{
            warnings = @('Startable-jobs script not found.')
            startableJobs = @()
            error = ''
        }
    }

    try {
        $rawOutput = & $scriptPath 2>&1 | Out-String
        $payload = $rawOutput | ConvertFrom-Json -ErrorAction Stop
        $jobs = @((Get-ObjectPropertyValue -Object $payload -Name 'startableJobs' -Default @()))

        # Enrich each job with neverAutoStart from state.autoStartPreferences
        try {
            $state = Read-AutotaskState
            $prefs = Get-ObjectPropertyValue -Object $state -Name 'autoStartPreferences' -Default $null
            if ($null -ne $prefs) {
                foreach ($job in $jobs) {
                    $jobNum = [string](Get-ObjectPropertyValue -Object $job -Name 'jobNumber' -Default '')
                    $taskSeq = [string](Get-ObjectPropertyValue -Object $job -Name 'taskSequence' -Default '')
                    $key = Get-AutotaskJobKey -JobNumber $jobNum -TaskSequence $taskSeq
                    $pref = Get-ObjectPropertyValue -Object $prefs -Name $key -Default $null
                    $neverAuto = ($pref -eq $true) -or ($null -ne $pref -and [bool](Get-ObjectPropertyValue -Object $pref -Name 'neverAutoStart' -Default $false))
                    Set-AutotaskProperty -Object $job -Name 'neverAutoStart' -Value ([bool]$neverAuto)
                }
            }
        } catch {
            # Non-critical: neverAutoStart enrichment is best-effort
        }

        return [PSCustomObject]@{
            warnings = @((Get-ObjectPropertyValue -Object $payload -Name 'warnings' -Default @()))
            startableJobs = $jobs
            error = [string](Get-ObjectPropertyValue -Object $payload -Name 'error' -Default '')
        }
    } catch {
        return [PSCustomObject]@{
            warnings = @()
            startableJobs = @()
            error = $_.Exception.Message
        }
    }
}

function Format-StatusMarkdownReport {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Data,

        [string]$CommandPrefix = 'autotask:'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $counts = $Data.counts

    # Summary header line
    $summaryParts = New-Object System.Collections.Generic.List[string]
    $summaryParts.Add("Startable: **$($counts.startableJobs)**")
    $summaryParts.Add("Queue: **$($counts.waitingQueue)**")
    $summaryParts.Add("Workers: **$($counts.workers)**")
    $summaryParts.Add("Completed: **$($counts.completedJobs)**")
    if ([int]$counts.failedJobs -gt 0) {
        $summaryParts.Add("Failed: **$($counts.failedJobs)** ⚠️")
    } else {
        $summaryParts.Add("Failed: **$($counts.failedJobs)**")
    }
    $lines.Add($summaryParts -join '  ·  ')

    # Startable jobs — the most actionable section
    $startableJobs = @($Data.startableJobs)
    if ($startableJobs.Count -gt 0) {
        $lines.Add('')
        $neverAutoCount = @($startableJobs | Where-Object { [bool]$_.neverAutoStart }).Count
        $neverAutoNote = if ($neverAutoCount -gt 0) { "  *(${neverAutoCount} marked 🚫 Never Auto)*" } else { '' }
        $lines.Add("**⚡ Startable Tasks**${neverAutoNote}")
        $index = 1
        foreach ($job in $startableJobs) {
            $neverAutoLabel = if ([bool]$job.neverAutoStart) { ' 🚫' } else { '' }
            $taskSeq = [string]$job.taskSequence
            $taskSeqLabel = if (-not [string]::IsNullOrWhiteSpace($taskSeq)) { " · task $taskSeq" } else { '' }
            $taskSeqPart = if (-not [string]::IsNullOrWhiteSpace($taskSeq)) { " --task $taskSeq" } else { '' }
            $startCmd = "$CommandPrefix start $($job.jobNumber)$taskSeqPart"
            $summary = [string]$job.summary
            if ($summary.Length -gt 65) { $summary = $summary.Substring(0, 62) + '...' }
            $lines.Add("${index}. **$($job.jobNumber)**${taskSeqLabel}$neverAutoLabel  $($job.taskType)  ·  $summary")
            $lines.Add("   ``$startCmd``")
            $index++
        }
    }

    # Active workers — show full description so each line is self-identifying
    $workers = @($Data.workers)
    if ($workers.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**🔄 Active Workers**')
        foreach ($job in $workers) {
            $taskSeqLabel = if (-not [string]::IsNullOrWhiteSpace([string]$job.taskSequence)) { " · task $($job.taskSequence)" } else { '' }
            $summaryText = [string]$job.summary
            if ($summaryText.Length -gt 65) { $summaryText = $summaryText.Substring(0, 62) + '...' }
            $summaryPart = if (-not [string]::IsNullOrWhiteSpace($summaryText)) { "  ·  $summaryText" } else { '' }
            $actLabel = if (-not [string]::IsNullOrWhiteSpace([string]$job.activityStatus)) { "  ·  $($job.activityStatus)" } else { '' }
            $lines.Add("• **$($job.jobNumber)**${taskSeqLabel}  $($job.taskType)$summaryPart$actLabel")
        }
    }

    # Waiting queue
    $waitingQueue = @($Data.waitingQueue)
    if ($waitingQueue.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**📥 Waiting Queue**')
        foreach ($job in $waitingQueue) {
            $taskSeqLabel = if (-not [string]::IsNullOrWhiteSpace([string]$job.taskSequence)) { " · task $($job.taskSequence)" } else { '' }
            $summaryText = [string]$job.summary
            if ($summaryText.Length -gt 65) { $summaryText = $summaryText.Substring(0, 62) + '...' }
            $summaryPart = if (-not [string]::IsNullOrWhiteSpace($summaryText)) { "  ·  $summaryText" } else { '' }
            $lines.Add("• **$($job.jobNumber)**${taskSeqLabel}  $($job.taskType)$summaryPart")
        }
    }

    # Completed jobs
    $completedJobs = @($Data.completedJobs)
    if ($completedJobs.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**✅ Completed**')
        foreach ($job in $completedJobs) {
            $taskSeqLabel = if (-not [string]::IsNullOrWhiteSpace([string]$job.taskSequence)) { " · task $($job.taskSequence)" } else { '' }
            $summaryText = [string]$job.summary
            if ($summaryText.Length -gt 65) { $summaryText = $summaryText.Substring(0, 62) + '...' }
            $summaryPart = if (-not [string]::IsNullOrWhiteSpace($summaryText)) { "  ·  $summaryText" } else { '' }
            $lines.Add("• **$($job.jobNumber)**${taskSeqLabel}  $($job.taskType)$summaryPart")
        }
    }

    # Failed jobs
    $failedJobs = @($Data.failedJobs)
    if ($failedJobs.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**❌ Failed**')
        foreach ($job in $failedJobs) {
            $taskSeqLabel = if (-not [string]::IsNullOrWhiteSpace([string]$job.taskSequence)) { " · task $($job.taskSequence)" } else { '' }
            $summaryText = [string]$job.summary
            if ($summaryText.Length -gt 65) { $summaryText = $summaryText.Substring(0, 62) + '...' }
            $summaryPart = if (-not [string]::IsNullOrWhiteSpace($summaryText)) { "  ·  $summaryText" } else { '' }
            $errSnippet = [string]$job.error
            if ($errSnippet.Length -gt 60) { $errSnippet = $errSnippet.Substring(0, 57) + '...' }
            $errPart = if (-not [string]::IsNullOrWhiteSpace($errSnippet)) { "  ·  $errSnippet" } else { '' }
            $lines.Add("• **$($job.jobNumber)**${taskSeqLabel}  $($job.taskType)$summaryPart$errPart")
        }
    }

    return (@($lines) -join "`n")
}

function New-QueuedJob {
    param(
        [Parameter(Mandatory)]
        [string]$JobNumber,

        [string]$TaskType = '',
        [string]$Description = '',
        [string]$JobGuid = '',
        [string]$TaskSequence = '',
        [int]$Zone = 0,
        [string]$CommandSource = '',
        [string[]]$Sources = @(),
        [int]$RetryCount = 0
    )

    $resolvedDescription = Get-FirstNonEmptyValue -Values @($Description, $JobNumber)
    $resolvedTaskType = Get-FirstNonEmptyValue -Values @($TaskType, 'unknown')
    $resolvedSource = Get-FirstNonEmptyValue -Values @($CommandSource, 'manual-command')
    $resolvedSources = @($Sources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($resolvedSources.Count -eq 0) {
        $resolvedSources = @($resolvedSource)
    } elseif ($resolvedSources -notcontains $resolvedSource) {
        $resolvedSources += $resolvedSource
    }

    return [PSCustomObject]@{
        jobNumber = $JobNumber
        jobGuid = $JobGuid
        taskSequence = $TaskSequence
        taskType = $resolvedTaskType
        summary = $resolvedDescription
        description = $resolvedDescription
        zone = $Zone
        source = $resolvedSource
        sources = @($resolvedSources)
        queuedVia = $resolvedSource
        queuedAt = (Get-Date).ToUniversalTime().ToString('o')
        retryCount = $RetryCount
    }
}

function Get-QueueCommandParts {
    param(
        [Parameter(Mandatory)]
        [string[]]$Parts
    )

    $taskType = ''
    $description = ''
    if ($Parts.Count -ge 3) {
        if ($Parts[2] -match '^[A-Z0-9]{2,6}$') {
            $taskType = $Parts[2]
            if ($Parts.Count -ge 4) {
                $description = ($Parts[3..($Parts.Count - 1)] -join ' ').Trim()
            }
        } else {
            $description = ($Parts[2..($Parts.Count - 1)] -join ' ').Trim()
        }
    }

    return [PSCustomObject]@{
        taskType = $taskType
        description = $description
    }
}

function Get-CommandOptionParts {
    param(
        [Parameter(Mandatory)]
        [string[]]$Parts
    )

    $taskSequence = ''
    $remaining = New-Object System.Collections.Generic.List[string]

    for ($index = 0; $index -lt $Parts.Count; $index++) {
        $part = [string]$Parts[$index]
        if ($part -eq '--task') {
            if (($index + 1) -ge $Parts.Count) {
                throw 'Usage: --task <taskSequence>'
            }

            $candidate = [string]$Parts[$index + 1]
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                throw 'Usage: --task <taskSequence>'
            }

            $taskSequence = $candidate.Trim()
            $index++
            continue
        }

        [void]$remaining.Add($part)
    }

    return [PSCustomObject]@{
        taskSequence = $taskSequence
        parts = @($remaining)
    }
}

function Parse-AutotaskCommand {
    param(
        [Parameter(Mandatory)]
        [string]$RawCommand
    )

    # Use only the first line for the header parts — multi-line bodies are handled
    # per-command using $RawCommand directly (e.g. setnotes).
    $firstLine = ($RawCommand -split "`r?`n")[0]
    $trimmedCommand = $firstLine.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedCommand)) {
        throw 'Command text is empty.'
    }

    $rawParts = @($trimmedCommand -split '\s+' | Where-Object { $_ -ne '' })
    $action = $rawParts[0].ToLowerInvariant()
    $parts = @($rawParts)
    $taskSequence = ''
    if ($action -in @('status', 'queue', 'start', 'resume', 'retry', 'cleanup', 'notes', 'setnotes')) {
        $optionParts = Get-CommandOptionParts -Parts $rawParts
        $parts = @($optionParts.parts)
        $taskSequence = [string]$optionParts.taskSequence
    }

    switch ($action) {
        'help' {
            return [PSCustomObject]@{
                action = 'help'
                jobNumber = ''
            }
        }

        'status' {
            return [PSCustomObject]@{
                action = 'status'
                jobNumber = if ($Parts.Count -ge 2) { $Parts[1].ToUpperInvariant() } else { '' }
                taskSequence = $taskSequence
            }
        }

        'queue' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: queue <jobNumber> [--task <taskSequence>] [taskType] [description]'
            }

            $queueParts = Get-QueueCommandParts -Parts $Parts
            return [PSCustomObject]@{
                action = 'queue'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
                taskType = $queueParts.taskType
                description = $queueParts.description
            }
        }

        'start' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: start <jobNumber> [--task <taskSequence>]'
            }

            return [PSCustomObject]@{
                action = 'start'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
                taskType = ''
                description = ''
            }
        }

        'resume' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: resume <jobNumber> [--task <taskSequence>]'
            }

            return [PSCustomObject]@{
                action = 'resume'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
            }
        }

        'retry' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: retry <jobNumber> [--task <taskSequence>]'
            }

            return [PSCustomObject]@{
                action = 'retry'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
            }
        }

        'cleanup' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: cleanup <jobNumber> [--task <taskSequence>]'
            }

            return [PSCustomObject]@{
                action = 'cleanup'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
            }
        }

        'notes' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: notes <jobNumber> --task <taskSequence>'
            }
            if ([string]::IsNullOrWhiteSpace($taskSequence)) {
                throw 'Usage: notes <jobNumber> --task <taskSequence>'
            }
            return [PSCustomObject]@{
                action = 'notes'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
            }
        }

        'setnotes' {
            if ($Parts.Count -lt 2) {
                throw 'Usage: setnotes <jobNumber> --task <taskSequence> <content>'
            }
            if ([string]::IsNullOrWhiteSpace($taskSequence)) {
                throw 'Usage: setnotes <jobNumber> --task <taskSequence> <content>'
            }

            # Content is everything after the first line (multi-line body), falling back to
            # any remaining words on the header line for single-line use.
            $newlinePos = $RawCommand.IndexOfAny([char[]]@("`n", "`r"))
            if ($newlinePos -ge 0) {
                # Skip the line ending itself (handle both \n and \r\n)
                $afterNewline = $RawCommand.Substring($newlinePos).TrimStart("`r`n")
                $notesContent = $afterNewline.TrimEnd()
            } elseif ($Parts.Count -ge 3) {
                $notesContent = ($Parts[2..($Parts.Count - 1)] -join ' ').Trim()
            } else {
                $notesContent = ''
            }

            return [PSCustomObject]@{
                action = 'setnotes'
                jobNumber = $Parts[1].ToUpperInvariant()
                taskSequence = $taskSequence
                content = $notesContent
            }
        }

        'reply' {
            if ($trimmedCommand -notmatch '^(reply|answer)\s+(?<job>(WI|CS|PRJ)\d{8})\s+(?<response>.+)$') {
                throw 'Usage: reply <jobNumber> <message>'
            }

            return [PSCustomObject]@{
                action = 'reply'
                jobNumber = $matches['job'].ToUpperInvariant()
                response = $matches['response'].Trim()
            }
        }

        'answer' {
            if ($trimmedCommand -notmatch '^(reply|answer)\s+(?<job>(WI|CS|PRJ)\d{8})\s+(?<response>.+)$') {
                throw 'Usage: answer <jobNumber> <message>'
            }

            return [PSCustomObject]@{
                action = 'reply'
                jobNumber = $matches['job'].ToUpperInvariant()
                response = $matches['response'].Trim()
            }
        }

        default {
            throw "Unsupported command '$action'. Supported commands: help, status, queue, start, resume, retry, cleanup, reply, answer."
        }
    }
}

function Invoke-QueueLikeCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [string]$CommandSource
    )

    $existingEntry = Get-JobStateEntry -State $State -JobNumber $ParsedCommand.jobNumber -TaskSequence ([string]$ParsedCommand.taskSequence)
    if ($existingEntry) {
        switch ($existingEntry.bucketName) {
            'waitingQueue' {
                return [PSCustomObject]@{
                    state = $State
                    stateChanged = $false
                    message = if ($ParsedCommand.action -eq 'start') {
                        "$($ParsedCommand.jobNumber) is already queued. Run /autotask-start to spawn workers."
                    } else {
                        "$($ParsedCommand.jobNumber) is already queued."
                    }
                    jobNumber = $ParsedCommand.jobNumber
                    action = $ParsedCommand.action
                    requiresAutotaskStart = $true
                }
            }

            'workers' {
                throw "$($ParsedCommand.jobNumber) already has an active worker."
            }

            'completedJobs' {
                throw "$($ParsedCommand.jobNumber) is already completed. Clean it up before queueing again."
            }

            'failedJobs' {
                throw "$($ParsedCommand.jobNumber) is currently failed. Use retry <jobNumber> or cleanup <jobNumber>."
            }
        }
    }

    # Enrich from ediProd when the text command didn't include a description
    $enrichedDescription = $ParsedCommand.description
    $enrichedSummary = ''
    $enrichedJobGuid = ''
    $enrichedZone = 0
    if ([string]::IsNullOrWhiteSpace($enrichedDescription)) {
        try {
            $enrichScript = Join-Path $PSScriptRoot 'enrich-autotask-job.ps1'
            if (Test-Path -LiteralPath $enrichScript) {
                $enrichArgs = @('-JobNumber', $ParsedCommand.jobNumber)
                if (-not [string]::IsNullOrWhiteSpace([string]$ParsedCommand.taskSequence)) {
                    $enrichArgs += @('-TaskSequence', [string]$ParsedCommand.taskSequence)
                }
                $enrichJson = & $enrichScript @enrichArgs 2>$null | Out-String
                if (-not [string]::IsNullOrWhiteSpace($enrichJson)) {
                    $enriched = $enrichJson | ConvertFrom-Json -ErrorAction Stop
                    $enrichedSummary = [string](Get-ObjectPropertyValue -Object $enriched -Name 'summary' -Default '')
                    $enrichedDescription = [string](Get-ObjectPropertyValue -Object $enriched -Name 'description' -Default '')
                    $enrichedJobGuid = [string](Get-ObjectPropertyValue -Object $enriched -Name 'jobGuid' -Default '')
                    $enrichedZone = if ($null -ne $enriched.zone) { [int]$enriched.zone } else { 0 }
                }
            }
        } catch { }
    }

    $queuedJob = New-QueuedJob `
        -JobNumber $ParsedCommand.jobNumber `
        -TaskType $ParsedCommand.taskType `
        -Description (Get-FirstNonEmptyValue -Values @($enrichedSummary, $enrichedDescription, $ParsedCommand.description)) `
        -TaskSequence ([string]$ParsedCommand.taskSequence) `
        -CommandSource $CommandSource `
        -JobGuid $enrichedJobGuid `
        -Zone $enrichedZone

    # Override summary and description separately when enrichment provided both
    if (-not [string]::IsNullOrWhiteSpace($enrichedSummary)) {
        Set-AutotaskProperty -Object $queuedJob -Name 'summary' -Value $enrichedSummary
    }
    if (-not [string]::IsNullOrWhiteSpace($enrichedDescription)) {
        Set-AutotaskProperty -Object $queuedJob -Name 'description' -Value $enrichedDescription
    }

    $State.waitingQueue = @($State.waitingQueue) + $queuedJob
    return [PSCustomObject]@{
        state = $State
        stateChanged = $true
        message = if ($ParsedCommand.action -eq 'start') {
            "Queued $($ParsedCommand.jobNumber). Run /autotask-start to spawn workers."
        } else {
            "Queued $($ParsedCommand.jobNumber). Run /autotask-start to spawn workers."
        }
        jobNumber = $ParsedCommand.jobNumber
        action = $ParsedCommand.action
        requiresAutotaskStart = $true
    }
}

function ConvertFrom-WorkerStartOutput {
    param(
        [Parameter(Mandatory)]
        [string]$RawOutput
    )

    $trimmedOutput = $RawOutput.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedOutput)) {
        throw 'Worker start command returned no output.'
    }

    try {
        return $trimmedOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
    }

    $jsonStart = $trimmedOutput.IndexOf('{')
    $jsonEnd = $trimmedOutput.LastIndexOf('}')
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        $jsonPayload = $trimmedOutput.Substring($jsonStart, ($jsonEnd - $jsonStart) + 1)
        return $jsonPayload | ConvertFrom-Json -ErrorAction Stop
    }

    throw $trimmedOutput
}

function Invoke-WorkerStartCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [ValidateSet('start', 'retry')]
        [string]$Mode
    )

    $scriptPath = Join-Path $PSScriptRoot 'start-autotask-worker.ps1'
    $startParameters = @{
        JobNumber = $ParsedCommand.jobNumber
        Mode = $Mode
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ParsedCommand.taskSequence)) {
        $startParameters.TaskSequence = [string]$ParsedCommand.taskSequence
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ParsedCommand.taskType)) {
        $startParameters.TaskType = [string]$ParsedCommand.taskType
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ParsedCommand.description)) {
        $startParameters.Description = [string]$ParsedCommand.description
    }

    $rawOutput = & $scriptPath @startParameters 2>&1 | Out-String
    $startResult = ConvertFrom-WorkerStartOutput -RawOutput $rawOutput
    return [PSCustomObject]@{
        state = Read-AutotaskState
        stateChanged = $true
        message = [string]$startResult.message
        jobNumber = [string]$startResult.jobNumber
        action = $Mode
        requiresAutotaskStart = $false
        data = $startResult
    }
}

function Invoke-RetryCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [string]$CommandSource
    )

    return Invoke-WorkerStartCommand -ParsedCommand $ParsedCommand -Mode 'retry'
}

function Invoke-ResumeCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [string]$CommandSource
    )

    $scriptPath = Join-Path $PSScriptRoot 'resume-autotask-worker.ps1'
    $resumeParameters = @{
        JobNumber = $ParsedCommand.jobNumber
        Source = $CommandSource
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ParsedCommand.taskSequence)) {
        $resumeParameters.TaskSequence = [string]$ParsedCommand.taskSequence
    }
    $rawOutput = & $scriptPath @resumeParameters 2>&1 | Out-String
    $resumeResult = ConvertFrom-WorkerStartOutput -RawOutput $rawOutput
    return [PSCustomObject]@{
        state = Read-AutotaskState
        stateChanged = $true
        message = [string]$resumeResult.message
        jobNumber = [string]$resumeResult.jobNumber
        action = 'resume'
        requiresAutotaskStart = $false
        data = $resumeResult
    }
}

function Invoke-CleanupCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand
    )

    $existingEntry = Get-JobStateEntry -State $State -JobNumber $ParsedCommand.jobNumber -TaskSequence ([string]$ParsedCommand.taskSequence)
    if (-not $existingEntry) {
        throw "$($ParsedCommand.jobNumber) was not found in state."
    }

    $selectedTaskKey = Get-AutotaskJobObjectKey -Job $existingEntry.job
    $hasSiblingTasks = @(
        @($State.waitingQueue) +
        @($State.workers) +
        @($State.completedJobs) +
        @($State.failedJobs) |
            Where-Object {
                $_ -and
                ([string](Get-ObjectPropertyValue -Object $_ -Name 'jobNumber' -Default '')).Trim().ToUpperInvariant() -eq $ParsedCommand.jobNumber.Trim().ToUpperInvariant() -and
                (Get-AutotaskJobObjectKey -Job $_) -ne $selectedTaskKey
            }
    ).Count -gt 0

    foreach ($bucketName in @('waitingQueue', 'workers', 'completedJobs', 'failedJobs')) {
        Remove-JobFromBucket -State $State -BucketName $bucketName -JobNumber $ParsedCommand.jobNumber -TaskSequence ([string]$ParsedCommand.taskSequence)
    }

    return [PSCustomObject]@{
        state = $State
        stateChanged = $true
        message = if ($hasSiblingTasks) {
            "Removed $($ParsedCommand.jobNumber) task record and kept the shared workspace because other tasks for this WI still exist."
        } else {
            "Cleaned up $($ParsedCommand.jobNumber)."
        }
        jobNumber = $ParsedCommand.jobNumber
        action = 'cleanup'
        requiresAutotaskStart = $false
    }
}

function Invoke-StatusCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand
    )

    $counts = [PSCustomObject]@{
        startableJobs = 0
        waitingQueue = @($State.waitingQueue).Count
        workers = @($State.workers).Count
        completedJobs = @($State.completedJobs).Count
        failedJobs = @($State.failedJobs).Count
    }

    if ([string]::IsNullOrWhiteSpace($ParsedCommand.jobNumber)) {
        $startableSnapshot = Get-StartableJobsSnapshot

        # Exclude jobs already running as active workers (by jobNumber+taskSequence key)
        $activeWorkerKeys = @($State.workers | ForEach-Object {
            Get-AutotaskJobKey `
                -JobNumber ([string](Get-ObjectPropertyValue -Object $_ -Name 'jobNumber' -Default '')) `
                -TaskSequence ([string](Get-ObjectPropertyValue -Object $_ -Name 'taskSequence' -Default ''))
        })
        $dedupedStartable = @($startableSnapshot.startableJobs | Where-Object {
            $key = Get-AutotaskJobKey `
                -JobNumber ([string](Get-ObjectPropertyValue -Object $_ -Name 'jobNumber' -Default '')) `
                -TaskSequence ([string](Get-ObjectPropertyValue -Object $_ -Name 'taskSequence' -Default ''))
            $activeWorkerKeys -notcontains $key
        })

        $counts.startableJobs = $dedupedStartable.Count
        $data = [PSCustomObject]@{
            counts = $counts
            warnings = @($startableSnapshot.warnings)
            startableError = [string]$startableSnapshot.error
            startableJobs = @($dedupedStartable | ForEach-Object { ConvertTo-StatusJobSummary -Job $_ -Bucket 'startable' })
            waitingQueue = @($State.waitingQueue | ForEach-Object { ConvertTo-StatusJobSummary -Job $_ -Bucket 'waitingQueue' })
            workers = @($State.workers | ForEach-Object { ConvertTo-StatusJobSummary -Job $_ -Bucket 'workers' })
            completedJobs = @($State.completedJobs | ForEach-Object { ConvertTo-StatusJobSummary -Job $_ -Bucket 'completedJobs' })
            failedJobs = @($State.failedJobs | ForEach-Object { ConvertTo-StatusJobSummary -Job $_ -Bucket 'failedJobs' })
        }

        # Build a rich markdown report for Teams/plain-text channels
        $statusReport = Format-StatusMarkdownReport -Data $data
        Set-AutotaskProperty -Object $data -Name 'statusReport' -Value $statusReport

        $summaryMessage = "Startable: $($counts.startableJobs), Queue: $($counts.waitingQueue), Workers: $($counts.workers), Completed: $($counts.completedJobs), Failed: $($counts.failedJobs)"
        return [PSCustomObject]@{
            state = $State
            stateChanged = $false
            message = $summaryMessage
            jobNumber = ''
            action = 'status'
            requiresAutotaskStart = $false
            data = $data
        }
    }

    $existingEntry = Get-JobStateEntry -State $State -JobNumber $ParsedCommand.jobNumber
    if (-not $existingEntry) {
        throw "$($ParsedCommand.jobNumber) was not found in state."
    }

    $job = $existingEntry.job
    return [PSCustomObject]@{
        state = $State
        stateChanged = $false
        message = "$($ParsedCommand.jobNumber) is in $($existingEntry.bucketName)."
        jobNumber = $ParsedCommand.jobNumber
        action = 'status'
        requiresAutotaskStart = $false
        data = (ConvertTo-StatusJobSummary -Job $job -Bucket $existingEntry.bucketName)
    }
}

function Invoke-HelpCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    return [PSCustomObject]@{
        state = $State
        stateChanged = $false
        message = 'Supported commands: help, status [jobNumber] [--task <taskSequence>], queue <jobNumber> [--task <taskSequence>] [taskType] [description], start <jobNumber> [--task <taskSequence>], resume <jobNumber> [--task <taskSequence>], retry <jobNumber> [--task <taskSequence>], cleanup <jobNumber> [--task <taskSequence>], notes <jobNumber> --task <taskSequence>, setnotes <jobNumber> --task <taskSequence> <content>, reply <jobNumber> <message>, answer <jobNumber> <message>.'
        jobNumber = ''
        action = 'help'
        requiresAutotaskStart = $false
    }
}

function Invoke-ReplyCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [string]$CommandSource,

        [string]$Responder,
        [string]$MessageId
    )

    $scriptPath = Join-Path $PSScriptRoot 'submit-autotask-user-input.ps1'
    $replyParameters = @{
        JobNumber = $ParsedCommand.jobNumber
        Response = $ParsedCommand.response
        Source = $CommandSource
    }

    if (-not [string]::IsNullOrWhiteSpace($Responder)) {
        $replyParameters.Responder = $Responder
    }

    if (-not [string]::IsNullOrWhiteSpace($MessageId)) {
        $replyParameters.MessageId = $MessageId
    }

    $resultText = & $scriptPath @replyParameters
    if (-not $resultText) {
        throw "Reply submission returned no output for $($ParsedCommand.jobNumber)."
    }

    $result = $resultText | ConvertFrom-Json
    $updatedState = Read-AutotaskState
    return [PSCustomObject]@{
        state = $updatedState
        stateChanged = $true
        message = "Reply sent for $($ParsedCommand.jobNumber)."
        jobNumber = $ParsedCommand.jobNumber
        action = 'reply'
        requiresAutotaskStart = $false
        data = $result
    }
}

function Invoke-GetNotesCommand {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ParsedCommand
    )

    $jobNumber = $ParsedCommand.jobNumber
    $taskSequence = [string]$ParsedCommand.taskSequence
    $scriptPath = Join-Path $PSScriptRoot 'get-autotask-task-notes.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "get-autotask-task-notes.ps1 not found."
    }

    $rawOutput = & $scriptPath -JobNumber $jobNumber -TaskSequence $taskSequence 2>&1
    $jsonLine = @($rawOutput) | Where-Object { [string]$_ -match '^\s*\{' -and [string]$_ -match '"success"\s*:' } | Select-Object -Last 1
    if (-not $jsonLine) {
        throw "No result from notes script."
    }
    $result = [string]$jsonLine | ConvertFrom-Json
    if (-not $result.success) {
        $errMsg = if ($result.PSObject.Properties['error']) { [string]$result.error } else { 'Failed to read notes.' }
        throw $errMsg
    }

    $notes = if ($result.PSObject.Properties['notes']) { [string]$result.notes } else { '' }
    $taskId = if ($result.PSObject.Properties['taskId']) { [string]$result.taskId } else { '' }
    $hasNotes = -not [string]::IsNullOrWhiteSpace($notes)
    $preview = if ($hasNotes) { "Notes for $jobNumber task $taskSequence loaded ($($notes.Length) chars)." } else { "No notes found for $jobNumber task $taskSequence." }

    return [PSCustomObject]@{
        success = $true
        message = $preview
        jobNumber = $jobNumber
        action = 'notes'
        requiresAutotaskStart = $false
        data = [PSCustomObject]@{
            taskId = $taskId
            notes = $notes
            hasNotes = $hasNotes
        }
    }
}

function Invoke-SetNotesCommand {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ParsedCommand
    )

    $jobNumber = $ParsedCommand.jobNumber
    $taskSequence = [string]$ParsedCommand.taskSequence
    $content = if ($ParsedCommand.PSObject.Properties['content']) { [string]$ParsedCommand.content } else { '' }
    $scriptPath = Join-Path $PSScriptRoot 'set-autotask-task-notes.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "set-autotask-task-notes.ps1 not found."
    }

    $rawOutput = & $scriptPath -JobNumber $jobNumber -TaskSequence $taskSequence -Content $content 2>&1
    $jsonLine = @($rawOutput) | Where-Object { [string]$_ -match '^\s*\{' -and [string]$_ -match '"success"\s*:' } | Select-Object -Last 1
    if (-not $jsonLine) {
        throw "No result from set-notes script."
    }
    $result = [string]$jsonLine | ConvertFrom-Json
    if (-not $result.success) {
        $errMsg = if ($result.PSObject.Properties['error']) { [string]$result.error } else { 'Failed to save notes.' }
        throw $errMsg
    }

    return [PSCustomObject]@{
        success = $true
        message = "Notes saved for $jobNumber task $taskSequence."
        jobNumber = $jobNumber
        action = 'setnotes'
        requiresAutotaskStart = $false
        data = [PSCustomObject]@{
            savedChars = $content.Length
        }
    }
}

function Invoke-AutotaskCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$ParsedCommand,

        [Parameter(Mandatory)]
        [string]$CommandSource,

        [string]$Responder,
        [string]$MessageId
    )

    switch ($ParsedCommand.action) {
        'help' {
            return Invoke-HelpCommand -State $State
        }

        'status' {
            return Invoke-StatusCommand -State $State -ParsedCommand $ParsedCommand
        }

        'queue' {
            return Invoke-QueueLikeCommand -State $State -ParsedCommand $ParsedCommand -CommandSource $CommandSource
        }

        'start' {
            return Invoke-WorkerStartCommand -ParsedCommand $ParsedCommand -Mode 'start'
        }

        'resume' {
            return Invoke-ResumeCommand -ParsedCommand $ParsedCommand -CommandSource $CommandSource
        }

        'retry' {
            return Invoke-RetryCommand -State $State -ParsedCommand $ParsedCommand -CommandSource $CommandSource
        }

        'cleanup' {
            return Invoke-CleanupCommand -State $State -ParsedCommand $ParsedCommand
        }

        'notes' {
            return Invoke-GetNotesCommand -ParsedCommand $ParsedCommand
        }

        'setnotes' {
            return Invoke-SetNotesCommand -ParsedCommand $ParsedCommand
        }

        'reply' {
            return Invoke-ReplyCommand -State $State -ParsedCommand $ParsedCommand -CommandSource $CommandSource -Responder $Responder -MessageId $MessageId
        }

        default {
            throw "Unsupported action '$($ParsedCommand.action)'."
        }
    }
}

function New-CommandResult {
    param(
        [bool]$Success,
        [string]$Action = '',
        [string]$JobNumber = '',
        [string]$Message = '',
        [string]$Error = '',
        [string]$Command = '',
        [bool]$Duplicate = $false,
        [bool]$RequiresAutotaskStart = $false,
        $Data = $null
    )

    return [PSCustomObject]@{
        success = $Success
        duplicate = $Duplicate
        command = $Command
        action = $Action
        jobNumber = $JobNumber
        message = $Message
        error = $Error
        requiresAutotaskStart = $RequiresAutotaskStart
        data = $Data
        receivedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Main {
    $trimmedCommand = $CommandText.Trim()
    $resolvedSource = Get-FirstNonEmptyValue -Values @($Source, 'manual-command')
    $resultObject = $null

    try {
        $state = Read-AutotaskState
        $existingEntry = Get-CommandHistoryEntry -State $state -MessageId $MessageId
        if ($existingEntry) {
            $duplicateData = Get-ObjectPropertyValue -Object $existingEntry -Name 'data' -Default $null
            $duplicateMessage = [string]$existingEntry.message

            if ([string]$existingEntry.action -eq 'status') {
                $parsedCommand = Parse-AutotaskCommand -RawCommand $trimmedCommand
                $dispatchResult = Invoke-AutotaskCommand -State $state -ParsedCommand $parsedCommand -CommandSource $resolvedSource -Responder $Responder -MessageId $MessageId
                $duplicateData = Get-ObjectPropertyValue -Object $dispatchResult -Name 'data' -Default $duplicateData
                $duplicateMessage = [string]$dispatchResult.message
            }

            $resultObject = New-CommandResult `
                -Success ([bool]$existingEntry.success) `
                -Action ([string]$existingEntry.action) `
                -JobNumber ([string]$existingEntry.jobNumber) `
                -Message $duplicateMessage `
                -Error ([string]$existingEntry.error) `
                -Command $trimmedCommand `
                -Duplicate $true `
                -RequiresAutotaskStart ([bool]$existingEntry.requiresAutotaskStart) `
                -Data $duplicateData
        } else {
            $parsedCommand = Parse-AutotaskCommand -RawCommand $trimmedCommand
            $dispatchResult = Invoke-AutotaskCommand -State $state -ParsedCommand $parsedCommand -CommandSource $resolvedSource -Responder $Responder -MessageId $MessageId
            $updatedState = if (Get-ObjectPropertyValue -Object $dispatchResult -Name 'state' -Default $null) { $dispatchResult.state } else { $state }

            $resultObject = New-CommandResult `
                -Success $true `
                -Action ([string]$dispatchResult.action) `
                -JobNumber ([string]$dispatchResult.jobNumber) `
                -Message ([string]$dispatchResult.message) `
                -Command $trimmedCommand `
                -RequiresAutotaskStart ([bool]$dispatchResult.requiresAutotaskStart) `
                -Data (Get-ObjectPropertyValue -Object $dispatchResult -Name 'data' -Default $null)

            $historyEntry = [PSCustomObject]@{
                receivedAt = $resultObject.receivedAt
                success = $true
                messageId = $MessageId
                source = $resolvedSource
                responder = $Responder
                command = $trimmedCommand
                action = [string]$dispatchResult.action
                jobNumber = [string]$dispatchResult.jobNumber
                message = [string]$dispatchResult.message
                error = ''
                requiresAutotaskStart = [bool]$dispatchResult.requiresAutotaskStart
                data = (Get-ObjectPropertyValue -Object $dispatchResult -Name 'data' -Default $null)
            }
            Add-CommandHistoryEntry -State $updatedState -Entry $historyEntry
            Write-AutotaskState -State $updatedState
        }
    } catch {
        $updatedState = Read-AutotaskState
        $resultObject = New-CommandResult `
            -Success $false `
            -Message 'Autotask command failed.' `
            -Error $_.Exception.Message `
            -Command $trimmedCommand

        $historyEntry = [PSCustomObject]@{
            receivedAt = $resultObject.receivedAt
            success = $false
            messageId = $MessageId
            source = $resolvedSource
            responder = $Responder
            command = $trimmedCommand
            action = ''
            jobNumber = ''
            message = $resultObject.message
            error = $resultObject.error
            requiresAutotaskStart = $false
            data = $null
        }
        Add-CommandHistoryEntry -State $updatedState -Entry $historyEntry
        Write-AutotaskState -State $updatedState
    }

    $json = $resultObject | ConvertTo-Json -Depth 20
    $global:LASTEXITCODE = 0
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output $json

    if ($PassThru) {
        [PSCustomObject]@{
            Json = $json
            Result = $resultObject
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
