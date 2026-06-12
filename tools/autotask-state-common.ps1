Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AutotaskRoot = Split-Path -Parent $PSScriptRoot
$script:AutotaskStatePath = Join-Path $script:AutotaskRoot 'temp\state.json'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:AutotaskBackupRetentionCount = 50

function Get-AutotaskRootPath {
    return $script:AutotaskRoot
}

function Get-AutotaskStatePath {
    return $script:AutotaskStatePath
}

function Resolve-AutotaskPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $script:AutotaskRoot $Path))
}

function ConvertTo-AutotaskRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $fullPath = Resolve-AutotaskPath -Path $Path
    $rootWithSeparator = $script:AutotaskRoot.TrimEnd('\') + '\'
    if ($fullPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($rootWithSeparator.Length)
    }

    return $fullPath
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $Default
    }

    if ($Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }

    return $Default
}

function Get-AutotaskUniqueStringArray {
    param(
        [AllowEmptyCollection()]
        [object[]]$Values = @()
    )

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ($null -eq $value) {
            continue
        }

        foreach ($entry in @($value)) {
            if ($null -eq $entry) {
                continue
            }

            $text = [string]$entry
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $trimmed = $text.Trim()
            if (-not $items.Contains($trimmed)) {
                $items.Add($trimmed)
            }
        }
    }

    return @($items)
}

function New-AutotaskArtifactUsage {
    param(
        [string]$Branch = '',
        [string]$Timestamp = ''
    )

    $effectiveTimestamp = if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        (Get-Date).ToUniversalTime().ToString('o')
    } else {
        $Timestamp
    }

    return [PSCustomObject]@{
        source = 'shared-cache'
        branch = $Branch
        cacheStatus = 'unknown'
        cachePath = ''
        artifactPath = ''
        artifactBuildId = ''
        extractedTo = ''
        sharedCache = $true
        updatedAt = $effectiveTimestamp
    }
}

function New-AutotaskBuildPlan {
    param(
        [string]$Timestamp = ''
    )

    $effectiveTimestamp = if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        (Get-Date).ToUniversalTime().ToString('o')
    } else {
        $Timestamp
    }

    return [PSCustomObject]@{
        buildMode = 'unplanned'
        targetProjects = @()
        targetTests = @()
        buildCommands = @()
        testCommands = @()
        notes = @()
        updatedAt = $effectiveTimestamp
    }
}

function New-AutotaskBuildFailure {
    param(
        [string]$Timestamp = ''
    )

    return [PSCustomObject]@{
        classification = 'none'
        likelyUnrelated = $false
        summary = ''
        failedProjects = @()
        failedTests = @()
        matchedSignals = @()
        shouldRefreshArtifacts = $false
        updatedAt = $Timestamp
    }
}

function Get-AutotaskNormalizedNameSet {
    param(
        [AllowEmptyCollection()]
        [string[]]$Values = @(),

        [switch]$StripExtension
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $candidate = [string]$value
        foreach ($separator in @('\', '/')) {
            if ($candidate.Contains($separator)) {
                $candidate = [System.IO.Path]::GetFileName($candidate)
                break
            }
        }

        if ($StripExtension -and $candidate.Contains('.')) {
            $candidate = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
        }

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = $candidate.Trim()
        if (-not $names.Contains($normalized)) {
            $names.Add($normalized)
        }
    }

    return @($names)
}

function Get-AutotaskBuildFailureAssessment {
    param(
        [string]$FailureText = '',
        [string]$Phase = '',
        [AllowEmptyCollection()]
        [string[]]$TargetProjects = @(),
        [AllowEmptyCollection()]
        [string[]]$FailedProjects = @(),
        [AllowEmptyCollection()]
        [string[]]$TargetTests = @(),
        [AllowEmptyCollection()]
        [string[]]$FailedTests = @()
    )

    $matchedSignals = New-Object System.Collections.Generic.List[string]
    $normalizedFailureText = [string]$FailureText
    $normalizedTargetProjects = @(Get-AutotaskNormalizedNameSet -Values $TargetProjects -StripExtension)
    $normalizedFailedProjects = @(Get-AutotaskNormalizedNameSet -Values $FailedProjects -StripExtension)
    $normalizedTargetTests = @(Get-AutotaskNormalizedNameSet -Values $TargetTests)
    $normalizedFailedTests = @(Get-AutotaskNormalizedNameSet -Values $FailedTests)

    $overlapProjects = @($normalizedFailedProjects | Where-Object { $normalizedTargetProjects -contains $_ })
    $overlapTests = @($normalizedFailedTests | Where-Object { $normalizedTargetTests -contains $_ })

    $outsideProjectScope = $normalizedTargetProjects.Count -gt 0 -and $normalizedFailedProjects.Count -gt 0 -and $overlapProjects.Count -eq 0
    $outsideTestScope = $normalizedTargetTests.Count -gt 0 -and $normalizedFailedTests.Count -gt 0 -and $overlapTests.Count -eq 0
    $outsideTargetScope = $outsideProjectScope -or $outsideTestScope

    $classifications = @(
        @{
            Name = 'environment-or-tooling'
            LikelyUnrelated = $true
            ShouldRefreshArtifacts = $false
            Summary = 'Failure looks environmental or tooling-related rather than caused by the targeted code changes.'
            Patterns = @(
                'MSB4236',
                'SDK .* could not be found',
                'is not recognized as the name of a cmdlet',
                'The system cannot find the path specified',
                'Access to the path .* is denied',
                'being used by another process',
                'No such host is known',
                'The remote name could not be resolved',
                'timed out',
                'Unable to load the service index',
                'network path was not found',
                'NuGet'
            )
        },
        @{
            Name = 'artifact-or-baseline'
            LikelyUnrelated = $true
            ShouldRefreshArtifacts = $true
            Summary = 'Failure looks tied to stale or incomplete baseline artifacts rather than the incremental change set.'
            Patterns = @(
                'Metadata file .*CargoWise\\Bin.* could not be found',
                'Could not load file or assembly',
                'BadImageFormatException',
                'The module was expected to contain an assembly manifest',
                'CargoWise\\Bin',
                'Binaries/'
            )
        },
        @{
            Name = 'test-infrastructure'
            LikelyUnrelated = $true
            ShouldRefreshArtifacts = $false
            Summary = 'Failure looks tied to test infrastructure or discovery rather than the targeted behavior.'
            Patterns = @(
                'No test matches the given testcase filter',
                'Could not find testhost',
                'Testhost process exited',
                'The active test run was aborted',
                'data collector',
                'test adapter'
            )
        }
    )

    foreach ($candidate in $classifications) {
        foreach ($pattern in $candidate.Patterns) {
            if ($normalizedFailureText -match $pattern) {
                $matchedSignals.Add($pattern)
            }
        }

        if ($matchedSignals.Count -gt 0) {
            return [PSCustomObject]@{
                classification = $candidate.Name
                likelyUnrelated = $candidate.LikelyUnrelated
                summary = $candidate.Summary
                failedProjects = @($normalizedFailedProjects)
                failedTests = @($normalizedFailedTests)
                matchedSignals = @($matchedSignals)
                shouldRefreshArtifacts = $candidate.ShouldRefreshArtifacts
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
        }
    }

    if ($outsideTargetScope) {
        if ($outsideProjectScope) {
            $matchedSignals.Add('failed-projects-outside-target-scope')
        }
        if ($outsideTestScope) {
            $matchedSignals.Add('failed-tests-outside-target-scope')
        }

        return [PSCustomObject]@{
            classification = 'outside-target-scope'
            likelyUnrelated = $true
            summary = 'Failure was observed outside the projects or tests selected for the targeted build/test plan.'
            failedProjects = @($normalizedFailedProjects)
            failedTests = @($normalizedFailedTests)
            matchedSignals = @($matchedSignals)
            shouldRefreshArtifacts = $false
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    if (
        $overlapProjects.Count -gt 0 -or
        $overlapTests.Count -gt 0 -or
        $normalizedFailureText -match 'error CS\d+' -or
        $normalizedFailureText -match 'Assert\.|Expected:|Actual:'
    ) {
        if ($overlapProjects.Count -gt 0) {
            $matchedSignals.Add('failed-projects-overlap-target-scope')
        }
        if ($overlapTests.Count -gt 0) {
            $matchedSignals.Add('failed-tests-overlap-target-scope')
        }
        if ($normalizedFailureText -match 'error CS\d+') {
            $matchedSignals.Add('compiler-error')
        }
        if ($normalizedFailureText -match 'Assert\.|Expected:|Actual:') {
            $matchedSignals.Add('assertion-failure')
        }

        return [PSCustomObject]@{
            classification = 'related-change'
            likelyUnrelated = $false
            summary = 'Failure overlaps the targeted projects/tests or looks like a direct code or test regression.'
            failedProjects = @($normalizedFailedProjects)
            failedTests = @($normalizedFailedTests)
            matchedSignals = @($matchedSignals)
            shouldRefreshArtifacts = $false
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    return [PSCustomObject]@{
        classification = 'unknown'
        likelyUnrelated = $false
        summary = 'Failure could not be classified from the available build/test evidence.'
        failedProjects = @($normalizedFailedProjects)
        failedTests = @($normalizedFailedTests)
        matchedSignals = @()
        shouldRefreshArtifacts = $false
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function New-AutotaskEmptyState {
    return [PSCustomObject]@{
        orchestrator = 'autotask'
        version = '1.0.0'
        date = (Get-Date -Format 'yyyy-MM-dd')
        waitingQueue = @()
        workers = @()
        completedJobs = @()
        failedJobs = @()
    }
}

function Read-AutotaskState {
    if (-not (Test-Path -LiteralPath $script:AutotaskStatePath)) {
        return New-AutotaskEmptyState
    }

    $state = Get-Content -LiteralPath $script:AutotaskStatePath -Raw | ConvertFrom-Json
    if (-not $state.waitingQueue) { Set-AutotaskProperty -Object $state -Name 'waitingQueue' -Value @() }
    if (-not $state.workers) { Set-AutotaskProperty -Object $state -Name 'workers' -Value @() }
    if (-not $state.completedJobs) { Set-AutotaskProperty -Object $state -Name 'completedJobs' -Value @() }
    if (-not $state.failedJobs) { Set-AutotaskProperty -Object $state -Name 'failedJobs' -Value @() }
    return $state
}

function Invoke-AutotaskBackupRetention {
    param(
        [Parameter(Mandatory)]
        [string]$TempDir,

        [int]$KeepCount = $script:AutotaskBackupRetentionCount
    )

    if ($KeepCount -lt 1) { return }

    try {
        $backups = Get-ChildItem -LiteralPath $TempDir -Filter 'state.json.bak.*' -File -ErrorAction Stop |
            Sort-Object -Property Name -Descending
        if ($backups.Count -le $KeepCount) { return }
        $backups | Select-Object -Skip $KeepCount | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Invoke-AutotaskBackupRetention: pruning failed: $_"
    }
}

function Write-AutotaskState {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    # Ensure temp dir exists for safe backups
    $tempDir = Join-Path $script:AutotaskRoot 'temp'
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    # Backup current state.json into temp as state.json.bak.YYYYMMDDHHmmss if it exists
    try {
        if (Test-Path -LiteralPath $script:AutotaskStatePath) {
            $ts = (Get-Date).ToString('yyyyMMddHHmmss')
            $backupName = "state.json.bak.$ts"
            $backupPath = Join-Path $tempDir $backupName
            Copy-Item -LiteralPath $script:AutotaskStatePath -Destination $backupPath -Force
            Invoke-AutotaskBackupRetention -TempDir $tempDir
        }
    } catch {
        # Best-effort: do not fail writes if backup fails
        Write-Verbose "Write-AutotaskState: backup to temp failed: $_"
    }

    # Merge with fresh disk state to avoid clobbering concurrent changes.
    # The caller's workers entries are authoritative (fresher heartbeats/status),
    # but non-workers buckets (completedJobs, failedJobs, waitingQueue) take the
    # disk version to preserve cleanup/complete mutations from other writers.
    try {
        if (Test-Path -LiteralPath $script:AutotaskStatePath) {
            $diskContent = [System.IO.File]::ReadAllText($script:AutotaskStatePath, $script:Utf8NoBom)
            if (-not [string]::IsNullOrWhiteSpace($diskContent)) {
                $diskContent = $diskContent -replace '^\xEF\xBB\xBF', ''
                $diskState = $diskContent | ConvertFrom-Json -ErrorAction Stop

                # Build a set of worker keys the caller is tracking
                $callerWorkerKeys = @{}
                foreach ($w in @($State.workers)) {
                    $jn = [string](Get-ObjectPropertyValue -Object $w -Name 'issueId' -Default '')
                    if ([string]::IsNullOrWhiteSpace($jn)) { $jn = [string](Get-ObjectPropertyValue -Object $w -Name 'jobNumber' -Default '') }
                    $ts2 = [string](Get-ObjectPropertyValue -Object $w -Name 'taskSequence' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($jn)) {
                        $key = if ([string]::IsNullOrWhiteSpace($ts2)) { $jn } else { "${jn}::${ts2}" }
                        $callerWorkerKeys[$key] = $w
                    }
                }

                # Build disk worker keys
                $diskWorkerKeys = @{}
                foreach ($w in @($diskState.workers)) {
                    $jn = [string](Get-ObjectPropertyValue -Object $w -Name 'issueId' -Default '')
                    if ([string]::IsNullOrWhiteSpace($jn)) { $jn = [string](Get-ObjectPropertyValue -Object $w -Name 'jobNumber' -Default '') }
                    $ts2 = [string](Get-ObjectPropertyValue -Object $w -Name 'taskSequence' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($jn)) {
                        $key = if ([string]::IsNullOrWhiteSpace($ts2)) { $jn } else { "${jn}::${ts2}" }
                        $diskWorkerKeys[$key] = $w
                    }
                }

                # Build keys present in disk completed/failed (these were moved out of workers by another writer)
                $movedOutKeys = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($bucket in @('completedJobs', 'failedJobs')) {
                    foreach ($j in @(Get-ObjectPropertyValue -Object $diskState -Name $bucket -Default @())) {
                        $jn = [string](Get-ObjectPropertyValue -Object $j -Name 'issueId' -Default '')
                        if ([string]::IsNullOrWhiteSpace($jn)) { $jn = [string](Get-ObjectPropertyValue -Object $j -Name 'jobNumber' -Default '') }
                        $ts2 = [string](Get-ObjectPropertyValue -Object $j -Name 'taskSequence' -Default '')
                        if (-not [string]::IsNullOrWhiteSpace($jn)) {
                            $key = if ([string]::IsNullOrWhiteSpace($ts2)) { $jn } else { "${jn}::${ts2}" }
                            [void]$movedOutKeys.Add($key)
                        }
                    }
                }

                # Merge workers: use caller's version of each worker, but drop any that
                # were moved to completed/failed on disk (i.e. another writer completed/cleaned them)
                $mergedWorkers = [System.Collections.Generic.List[object]]::new()
                foreach ($key in $callerWorkerKeys.Keys) {
                    if (-not $movedOutKeys.Contains($key)) {
                        $mergedWorkers.Add($callerWorkerKeys[$key])
                    }
                }
                # Add any disk-only workers the caller didn't know about
                foreach ($key in $diskWorkerKeys.Keys) {
                    if (-not $callerWorkerKeys.ContainsKey($key) -and -not $movedOutKeys.Contains($key)) {
                        $mergedWorkers.Add($diskWorkerKeys[$key])
                    }
                }

                # Build cleaned-up key set (removed from all buckets on disk)
                $diskAllKeys = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($bucket in @('workers', 'completedJobs', 'failedJobs', 'waitingQueue')) {
                    foreach ($j in @(Get-ObjectPropertyValue -Object $diskState -Name $bucket -Default @())) {
                        $jn = [string](Get-ObjectPropertyValue -Object $j -Name 'issueId' -Default '')
                        if ([string]::IsNullOrWhiteSpace($jn)) { $jn = [string](Get-ObjectPropertyValue -Object $j -Name 'jobNumber' -Default '') }
                        $ts2 = [string](Get-ObjectPropertyValue -Object $j -Name 'taskSequence' -Default '')
                        if (-not [string]::IsNullOrWhiteSpace($jn)) {
                            $key = if ([string]::IsNullOrWhiteSpace($ts2)) { $jn } else { "${jn}::${ts2}" }
                            [void]$diskAllKeys.Add($key)
                        }
                    }
                }

                # Apply merged workers and take disk version of non-workers buckets
                $State.workers = @($mergedWorkers)
                foreach ($bucket in @('completedJobs', 'failedJobs', 'waitingQueue')) {
                    $diskBucket = @(Get-ObjectPropertyValue -Object $diskState -Name $bucket -Default @())
                    Set-AutotaskProperty -Object $State -Name $bucket -Value $diskBucket
                }

                # Preserve non-bucket properties from disk that the caller might not have
                foreach ($prop in $diskState.PSObject.Properties) {
                    if ($prop.Name -notin @('workers', 'completedJobs', 'failedJobs', 'waitingQueue') -and
                        -not $State.PSObject.Properties[$prop.Name]) {
                        Set-AutotaskProperty -Object $State -Name $prop.Name -Value $prop.Value
                    }
                }
            }
        }
    } catch {
        Write-Verbose "Write-AutotaskState: merge with disk state failed (proceeding with caller state): $_"
    }

    $serializedState = ($State | ConvertTo-Json -Depth 20)
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.IO.File]::WriteAllText(
                $script:AutotaskStatePath,
                $serializedState,
                $script:Utf8NoBom
            )
            return
        } catch {
            $lastError = $_
            $message = [string]$_.Exception.Message
            if ($message -notmatch 'being used by another process') {
                throw
            }

            if ($attempt -eq 5) {
                break
            }

            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }

    throw $lastError
}

function Set-AutotaskProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Set-AutotaskWorkerHeartbeat {
    param(
        [Parameter(Mandatory)]
        [psobject]$Worker,

        [string]$Timestamp = ''
    )

    $effectiveTimestamp = if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        Get-Date -Format 'o'
    } else {
        $Timestamp
    }

    Set-AutotaskProperty -Object $Worker -Name 'lastHeartbeatAt' -Value $effectiveTimestamp
    Set-AutotaskProperty -Object $Worker -Name 'lastUpdated' -Value $effectiveTimestamp
}

function Get-AutotaskTaskSequenceText {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    return $text.Trim()
}

function Get-AutotaskJobKey {
    param(
        [string]$IssueId,
        $TaskSequence = $null
    )

    $resolvedIssueId = if ([string]::IsNullOrWhiteSpace($IssueId)) { '' } else { $IssueId.Trim().ToUpperInvariant() }
    $resolvedTaskSequence = Get-AutotaskTaskSequenceText -Value $TaskSequence
    if ([string]::IsNullOrWhiteSpace($resolvedTaskSequence)) {
        return $resolvedIssueId
    }

    return ($resolvedIssueId + '::' + $resolvedTaskSequence)
}

function Get-AutotaskJobObjectKey {
    param(
        [Parameter(Mandatory)]
        [object]$Job
    )

    $id = [string](Get-ObjectPropertyValue -Object $Job -Name 'issueId' -Default '')
    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = [string](Get-ObjectPropertyValue -Object $Job -Name 'jobNumber' -Default '')
    }
    return Get-AutotaskJobKey `
        -IssueId $id `
        -TaskSequence (Get-ObjectPropertyValue -Object $Job -Name 'taskSequence' -Default '')
}

function Test-AutotaskJobMatch {
    param(
        [Parameter(Mandatory)]
        [object]$Job,

        [Parameter(Mandatory)]
        [string]$IssueId,

        $TaskSequence = $null
    )

    $jobIssueId = [string](Get-ObjectPropertyValue -Object $Job -Name 'issueId' -Default '')
    if ([string]::IsNullOrWhiteSpace($jobIssueId)) {
        $jobIssueId = [string](Get-ObjectPropertyValue -Object $Job -Name 'jobNumber' -Default '')
    }
    if ($jobIssueId.Trim().ToUpperInvariant() -ne $IssueId.Trim().ToUpperInvariant()) {
        return $false
    }

    $resolvedTaskSequence = Get-AutotaskTaskSequenceText -Value $TaskSequence
    if ([string]::IsNullOrWhiteSpace($resolvedTaskSequence)) {
        return $true
    }

    $jobTaskSequence = Get-AutotaskTaskSequenceText -Value (Get-ObjectPropertyValue -Object $Job -Name 'taskSequence' -Default '')
    return $jobTaskSequence -eq $resolvedTaskSequence
}

function Get-AutotaskWorker {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [string]$IssueId,

        $TaskSequence = $null
    )

    return @($State.workers | Where-Object { Test-AutotaskJobMatch -Job $_ -IssueId $IssueId -TaskSequence $TaskSequence }) | Select-Object -First 1
}

function Ensure-AutotaskWorkspaceDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $resolvedWorkspacePath = Resolve-AutotaskPath -Path $WorkspacePath

    if (-not (Test-Path -LiteralPath $resolvedWorkspacePath)) {
        New-Item -ItemType Directory -Path $resolvedWorkspacePath -Force | Out-Null
    }

    $autotaskDir = Join-Path $resolvedWorkspacePath '.autotask'
    if (-not (Test-Path -LiteralPath $autotaskDir)) {
        New-Item -ItemType Directory -Path $autotaskDir -Force | Out-Null
    }

    return $autotaskDir
}

function Save-AutotaskWorkspaceArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        $Content
    )

    $autotaskDir = Ensure-AutotaskWorkspaceDirectory -WorkspacePath $WorkspacePath
    $artifactPath = Join-Path $autotaskDir $FileName
    [System.IO.File]::WriteAllText(
        $artifactPath,
        ($Content | ConvertTo-Json -Depth 20),
        $script:Utf8NoBom
    )
    return (ConvertTo-AutotaskRelativePath -Path $artifactPath)
}
