[CmdletBinding()]
param(
    [string]$BufferBoardUrl = '',
    [string]$BoardName = '',
    [string]$StaffCode = '',
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OrchestratorRoot {
    return [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-ConfigContent {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item)) {
            continue
        }

        $chunks.Add([System.IO.File]::ReadAllText($item, [System.Text.Encoding]::UTF8))
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

    # Parse JSON array: ["A", "B", "C"]
    $stripped = $rawValue.Trim()
    if ($stripped.StartsWith('[') -and $stripped.EndsWith(']')) {
        $inner = $stripped.Substring(1, $stripped.Length - 2)
        return @($inner -split ',' | ForEach-Object {
            $_.Trim().Trim('"').Trim("'")
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # Comma-separated fallback
    return @($stripped -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ConfigSectionValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    $lines = $Content -split "`r?`n"
    $inSection = $false
    $sectionIndent = -1

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        # Count leading spaces
        $indent = $line.Length - $line.TrimStart().Length

        if (-not $inSection) {
            # Match a bare section header: "Section:" with no trailing value
            if ($trimmed -match '^([^:]+):\s*$' -and $Matches[1].Trim() -eq $Section) {
                $inSection = $true
                $sectionIndent = $indent
            }
            continue
        }

        # Left the section if indent regressed to same or higher level
        if ($indent -le $sectionIndent) {
            break
        }

        # Parse key: value
        if ($trimmed -match '^([^:]+):\s*(.*)$') {
            $lineKey = $Matches[1].Trim()
            $lineValue = $Matches[2]
            if ($lineValue.Contains('#')) {
                $lineValue = $lineValue.Split('#', 2)[0]
            }
            $lineValue = $lineValue.Trim().Trim("'`"")
            if ($lineKey -eq $Key) {
                return $lineValue
            }
        }
    }

    return $Default
}

function Invoke-GenericAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OrchestratorRoot,

        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $resultsList = New-Object System.Collections.Generic.List[object]

    try {
        $scriptPath = Join-Path (Join-Path $OrchestratorRoot 'tools') 'query-issue-source.ts'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Issue source adapter script not found at: $scriptPath"
        }

        $rawLines = @(& bun $scriptPath 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "query-issue-source.ts exited with code $LASTEXITCODE"
        }

        # The script may emit log lines before the JSON — find the first
        # object that contains the "startableJobs" key.
        $procOutput = $null
        $foundJson = $false
        $braceDepth = 0
        $currentJsonLines = New-Object System.Collections.Generic.List[string]

        foreach ($line in $rawLines) {
            if (-not $foundJson) {
                if ($line.TrimStart().StartsWith('{')) {
                    $foundJson = $true
                    $currentJsonLines.Clear()
                    $braceDepth = 0
                } else {
                    continue
                }
            }
            $currentJsonLines.Add($line)
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq '{') { $braceDepth++ }
                elseif ($ch -eq '}') { $braceDepth-- }
            }
            if ($braceDepth -le 0) {
                $candidate = ($currentJsonLines -join "`n")
                if ($candidate -match '"startableJobs"') {
                    $procOutput = $candidate
                    break
                }
                $foundJson = $false
                $currentJsonLines.Clear()
            }
        }

        if ($null -eq $procOutput) {
            throw "query-issue-source.ts produced no JSON output with a 'startableJobs' key."
        }

        $parsed = $procOutput | ConvertFrom-Json -ErrorAction Stop

        $adapterWarnings = @()
        if ($parsed.PSObject.Properties['warnings']) {
            $adapterWarnings = @($parsed.warnings | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        if ($parsed.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace($parsed.error)) {
            $adapterWarnings += @("$AdapterName adapter error: $($parsed.error)")
        }

        $items = @()
        if ($parsed.PSObject.Properties['startableJobs']) {
            $items = @($parsed.startableJobs)
        }

        foreach ($item in $items) {
            $resultsList.Add($item)
        }

        return [PSCustomObject]@{
            warnings      = $adapterWarnings
            startableJobs = $resultsList.ToArray()
        }
    } catch {
        return [PSCustomObject]@{
            warnings      = @("$AdapterName adapter failed: $($_.Exception.Message)")
            startableJobs = @()
        }
    }
}

function New-ErrorPayloadJson {
    param([string]$Message = '')

    return ([PSCustomObject]@{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        warnings = @($Message)
        startableJobs = @()
        error = $Message
    } | ConvertTo-Json -Depth 20)
}

function Get-ApiBaseUrl {
    param(
        [string]$ConfiguredUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredUrl)) {
        return $null
    }

    return $ConfiguredUrl.Trim().TrimEnd('/')
}

function Invoke-PaveJson {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    return Invoke-RestMethod -Uri $Uri -Method GET -TimeoutSec 30
}

function Resolve-StaffCode {
    param(
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [string]$ConfiguredStaffCode
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredStaffCode)) {
        return $ConfiguredStaffCode.Trim()
    }

    $currentUser = Invoke-PaveJson -Uri "$ApiBaseUrl/api/user/current"
    if ($null -eq $currentUser -or [string]::IsNullOrWhiteSpace($currentUser.code)) {
        throw 'Unable to resolve staff code from /api/user/current.'
    }

    return [string]$currentUser.code
}

function Resolve-BoardId {
    param(
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$ConfiguredBoardName
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredBoardName)) {
        throw 'board_name is not configured.'
    }

    $queries = New-Object System.Collections.Generic.List[string]
    $queries.Add($ConfiguredBoardName.Trim())

    $firstWord = ($ConfiguredBoardName -split '\s+', 2)[0]
    if (-not [string]::IsNullOrWhiteSpace($firstWord) -and $firstWord.Length -ge 3 -and $firstWord -ne $ConfiguredBoardName) {
        $queries.Add($firstWord)
    }

    foreach ($query in $queries) {
        $suggestions = Invoke-PaveJson -Uri ("$ApiBaseUrl/api/boards/suggest?q={0}" -f [uri]::EscapeDataString($query))
        $boards = @($suggestions.boards)
        if ($boards.Count -eq 0) {
            continue
        }

        $exactMatch = $boards | Where-Object { $_.name -and $_.name.Equals($ConfiguredBoardName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($exactMatch) {
            return [string]$exactMatch.pk
        }

        $containsMatch = $boards | Where-Object { $_.name -and $_.name.IndexOf($ConfiguredBoardName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
        if ($containsMatch) {
            return [string]$containsMatch.pk
        }
    }

    throw "Unable to resolve board id for '$ConfiguredBoardName'."
}

function Get-StartableJobsFromPayload {
    param(
        [Parameter(Mandatory)]
        $Payload
    )

    $results = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($job in @($Payload.jobs)) {
        if ($null -eq $job -or [string]::IsNullOrWhiteSpace($job.number)) {
            continue
        }

        $startableTasks = @($job.tasks | Where-Object { $_.is_startable -eq $true })
        if ($startableTasks.Count -eq 0) {
            continue
        }

        $orderedTasks = @($startableTasks | Sort-Object sequence, type)
        $primaryTask = $orderedTasks[0]
        $taskTypes = @($orderedTasks | ForEach-Object { $_.type } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $taskEntries = @(
            $orderedTasks |
                ForEach-Object {
                    [PSCustomObject]@{
                        taskSequence = if ($null -ne $_.sequence) { [string]$_.sequence } else { '' }
                        taskType = [string]$_.type
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.taskSequence) -or -not [string]::IsNullOrWhiteSpace([string]$_.taskType) }
        )

        $primaryTaskDesc = if ($primaryTask.PSObject.Properties['description'] -and -not [string]::IsNullOrWhiteSpace([string]$primaryTask.description)) { [string]$primaryTask.description } else { [string]$job.title }
        $primaryTaskZone = if ($primaryTask.PSObject.Properties['zone'] -and $null -ne $primaryTask.zone -and "$($primaryTask.zone)".Trim() -ne '') { [int]$primaryTask.zone } else { 0 }
        $result = [PSCustomObject]@{
            jobNumber = [string]$job.number
            jobGuid = [string]$job.pk
            taskSequence = if ($null -ne $primaryTask.sequence) { [string]$primaryTask.sequence } else { '' }
            taskType = if ($taskTypes.Count -gt 0) { [string]$taskTypes[0] } else { '' }
            staffCode = if ($null -ne $primaryTask.staff_code -and -not [string]::IsNullOrWhiteSpace([string]$primaryTask.staff_code)) { [string]$primaryTask.staff_code } else { '' }
            startableTasks = $taskEntries
            summary = [string]$job.title
            description = $primaryTaskDesc
            zone = $primaryTaskZone
            source = 'pave-api'
            sources = @('pave-api')
            jobUrl = ''
        }

        $seen[$result.jobNumber] = $true
        $results.Add($result)
    }

    foreach ($task in @($Payload.tasks)) {
        if ($null -eq $task -or $task.is_startable -ne $true -or $null -eq $task.parent_job -or [string]::IsNullOrWhiteSpace($task.parent_job.number)) {
            continue
        }

        $jobNumber = [string]$task.parent_job.number
        if ($seen.ContainsKey($jobNumber)) {
            continue
        }

        $taskDesc = if ($task.PSObject.Properties['description'] -and -not [string]::IsNullOrWhiteSpace([string]$task.description)) { [string]$task.description } else { [string]$task.parent_job.title }
        $taskZone = if ($task.PSObject.Properties['zone'] -and $null -ne $task.zone -and "$($task.zone)".Trim() -ne '') { [int]$task.zone } else { 0 }
        $result = [PSCustomObject]@{
            jobNumber = $jobNumber
            jobGuid = [string]$task.parent_job.pk
            taskSequence = if ($null -ne $task.sequence) { [string]$task.sequence } else { '' }
            taskType = [string]$task.type
            staffCode = if ($null -ne $task.staff_code -and -not [string]::IsNullOrWhiteSpace([string]$task.staff_code)) { [string]$task.staff_code } else { '' }
            startableTasks = @([PSCustomObject]@{
                    taskSequence = if ($null -ne $task.sequence) { [string]$task.sequence } else { '' }
                    taskType = [string]$task.type
                })
            summary = [string]$task.parent_job.title
            description = $taskDesc
            zone = $taskZone
            source = 'pave-api'
            sources = @('pave-api')
            jobUrl = ''
        }

        $seen[$jobNumber] = $true
        $results.Add($result)
    }

    return @($results | Sort-Object jobNumber)
}

function Invoke-ODataQuery {
    param(
        [Parameter(Mandatory)]
        [string]$OrchestratorRoot,

        [Parameter(Mandatory)]
        [string]$ResolvedStaffCode
    )

    $resultsList = New-Object System.Collections.Generic.List[object]
    try {
        $scriptPath = Join-Path (Join-Path $OrchestratorRoot 'tools') 'query-bm-startable.ts'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "BM OData query script not found at $scriptPath"
        }

        # Run the TypeScript OData script with bun.
        # bun emits OTEL/INFO lines to stdout before the JSON — strip them.
        $bunCmd = 'bun'
        $rawLines = @(& $bunCmd $scriptPath 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "OData script failed (exit $LASTEXITCODE)"
        }

        # The GlowClient pino logger emits structured JSON log lines to stdout in non-TTY
        # (subprocess) contexts instead of pretty-printed text. We must skip those and
        # find the specific JSON object produced by query-bm-startable.ts, identified
        # by the presence of a "results" key.
        $foundJson = $false
        $braceDepth = 0
        $currentJsonLines = New-Object System.Collections.Generic.List[string]
        $procOutput = $null
        foreach ($line in $rawLines) {
            if (-not $foundJson) {
                if ($line.TrimStart().StartsWith('{')) {
                    $foundJson = $true
                    $currentJsonLines.Clear()
                    $braceDepth = 0
                } else {
                    continue
                }
            }
            $currentJsonLines.Add($line)
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq '{') { $braceDepth++ }
                elseif ($ch -eq '}') { $braceDepth-- }
            }
            if ($braceDepth -le 0) {
                $candidate = ($currentJsonLines -join "`n")
                if ($candidate -match '"results"') {
                    $procOutput = $candidate
                    break
                }
                # This block was a log/diagnostic object — keep scanning
                $foundJson = $false
                $currentJsonLines.Clear()
            }
        }
        if ($null -eq $procOutput) {
            throw 'OData script produced no JSON output with a results key.'
        }

        $parsed = $procOutput | ConvertFrom-Json -ErrorAction Stop
        $items = @()
        if ($parsed.PSObject.Properties['results']) { $items = @($parsed.results) }
        elseif ($parsed.PSObject.Properties['Results']) { $items = @($parsed.Results) }

        foreach ($r in @($items)) {
            $taskSeq = if ($null -ne $r.sequence) { [string]$r.sequence } else { '' }
            $taskType = if ($null -ne $r.type) { [string]$r.type } else { '' }
            $taskDesc = if ($null -ne $r.description) { [string]$r.description } else { '' }
            $assigned = if ($null -ne $r.assignedStaff) { [string]$r.assignedStaff } else { '' }
            $parentJobPk = if ($null -ne $r.parentJobPk) { [string]$r.parentJobPk } else { '' }
            $jobNum = if ($null -ne $r.jobNumber -and -not [string]::IsNullOrWhiteSpace([string]$r.jobNumber)) { [string]$r.jobNumber } else { '' }

            $startableTasks = @([PSCustomObject]@{
                taskSequence = $taskSeq
                taskType = $taskType
                taskDescription = $taskDesc
                taskZone = $null
            })

            $jobSummary = if ($null -ne $r.jobSummary -and -not [string]::IsNullOrWhiteSpace([string]$r.jobSummary)) { [string]$r.jobSummary } else { '' }
            $jobObj = [PSCustomObject]@{
                jobNumber = $jobNum
                jobGuid = $parentJobPk
                taskSequence = $taskSeq
                taskType = $taskType
                staffCode = if (-not [string]::IsNullOrWhiteSpace($assigned)) { $assigned } else { $ResolvedStaffCode }
                startableTasks = @($startableTasks)
                summary = if (-not [string]::IsNullOrWhiteSpace($jobSummary)) { $jobSummary } else { $taskDesc }
                description = $taskDesc
                zone = 0
                source = 'bm-odata'
                sources = @('bm-odata')
                jobUrl = ''
            }

            $resultsList.Add($jobObj)
        }

        return [PSCustomObject]@{
            warnings = @()
            startableJobs = $resultsList.ToArray()
        }
    } catch {
        return [PSCustomObject]@{
            warnings = @("bm-odata query failed: $($_.Exception.Message)")
            startableJobs = @()
        }
    }
}

function Main {
    $canonicalJson = ''

    try {
        $orchestratorRoot = Get-OrchestratorRoot
        $configContent = Get-ConfigContent -Path @(
            (Join-Path $orchestratorRoot 'config.yaml'),
            (Join-Path $orchestratorRoot 'config.local.yaml')
        )

        $resolvedBufferBoardUrl = if ([string]::IsNullOrWhiteSpace($BufferBoardUrl)) {
            Get-ConfigTextValue -Content $configContent -Key 'buffer_board_url'
        } else {
            $BufferBoardUrl
        }
        $resolvedBoardName = if ([string]::IsNullOrWhiteSpace($BoardName)) {
            Get-ConfigTextValue -Content $configContent -Key 'board_name'
        } else {
            $BoardName
        }
        $resolvedStaffCode = if ([string]::IsNullOrWhiteSpace($StaffCode)) {
            Get-ConfigTextValue -Content $configContent -Key 'staff_code'
        } else {
            $StaffCode
        }
        $excludedTaskTypes = @(Get-ConfigListValue -Content $configContent -Key 'excluded_task_types' | ForEach-Object { $_.ToUpperInvariant() })

        $warnings = New-Object System.Collections.Generic.List[string]
        $startableJobs = @()

        # Determine the active issue source adapter (studio mode vs legacy ediprod path)
        $issueSourceAdapter = Get-ConfigSectionValue -Content $configContent -Section 'issue_source' -Key 'adapter'
        $useLegacyEdiprodPath = [string]::IsNullOrWhiteSpace($issueSourceAdapter) -or $issueSourceAdapter.ToLowerInvariant() -eq 'ediprod'

        if (-not $useLegacyEdiprodPath) {
            # --- Generic adapter path (Phase 1 studio mode) ---
            $adapterResult = Invoke-GenericAdapter -OrchestratorRoot $orchestratorRoot -AdapterName $issueSourceAdapter
            foreach ($w in @($adapterResult.warnings)) { $warnings.Add([string]$w) }
            $startableJobs = @($adapterResult.startableJobs)
        } else {
            # --- Legacy ediprod path (unchanged) ---
            # Primary: BM OData via bun/TS script — works without the local PAVE portal running
            $odataResult = Invoke-ODataQuery -OrchestratorRoot $orchestratorRoot -ResolvedStaffCode $resolvedStaffCode
            foreach ($w in @($odataResult.warnings)) { $warnings.Add([string]$w) }
            $startableJobs = @($odataResult.startableJobs)
        }

        # Fallback: PAVE API — only when URL is configured, on the legacy ediprod path, and OData returned nothing
        if ($startableJobs.Count -eq 0 -and $useLegacyEdiprodPath) {
            $apiBaseUrl = Get-ApiBaseUrl -ConfiguredUrl $resolvedBufferBoardUrl
            if ($null -ne $apiBaseUrl) {
                try {
                    # Pre-check: for localhost/loopback URLs, test the TCP port before attempting
                    # any HTTP calls so we get a clean skip message instead of a connection-refused error.
                    $parsedUri = [System.Uri]$apiBaseUrl
                    $isLoopback = ($parsedUri.Host -eq 'localhost' -or $parsedUri.Host -eq '127.0.0.1' -or $parsedUri.Host -eq '::1')
                    if ($isLoopback) {
                        $tcp = New-Object System.Net.Sockets.TcpClient
                        try {
                            $connectTask = $tcp.ConnectAsync($parsedUri.Host, $parsedUri.Port)
                            if (-not $connectTask.Wait(1500) -or -not $tcp.Connected) {
                                throw "PAVE portal not running at $($parsedUri.Host):$($parsedUri.Port) — skipping fallback."
                            }
                        } finally {
                            $tcp.Close()
                        }
                    }

                    $staffCodeValue = Resolve-StaffCode -ApiBaseUrl $apiBaseUrl -ConfiguredStaffCode $resolvedStaffCode
                    $boardId = Resolve-BoardId -ApiBaseUrl $apiBaseUrl -ConfiguredBoardName $resolvedBoardName
                    $tasksUri = '{0}/api/staff/{1}/tasks?board_id={2}&include_off_board_tasks=true&force_fetch=true' -f $apiBaseUrl, [uri]::EscapeDataString($staffCodeValue), [uri]::EscapeDataString($boardId)
                    $payload = Invoke-PaveJson -Uri $tasksUri
                    $startableJobs = Get-StartableJobsFromPayload -Payload $payload
                    $warnings.Add('BM OData returned no results; used PAVE API fallback.')
                } catch {
                    $warnings.Add("PAVE API fallback skipped: $($_.Exception.Message)")
                }
            }
        }

        # Populate web jobUrl when a buffer_board_url is configured so cards link to the web portal
        $apiBase = Get-ApiBaseUrl -ConfiguredUrl $resolvedBufferBoardUrl
        if ($null -ne $apiBase) {
            foreach ($j in $startableJobs) {
                try {
                    if ((-not $j.jobUrl) -or [string]::IsNullOrWhiteSpace([string]$j.jobUrl)) {
                        if ($j.jobGuid -and -not [string]::IsNullOrWhiteSpace([string]$j.jobGuid)) {
                            $j.jobUrl = "{0}/link/ShowEditForm/WorkItem/{1}?lang=en-gb" -f $apiBase.TrimEnd('/'), [uri]::EscapeDataString([string]$j.jobGuid)
                        }
                    }
                } catch {
                    # ignore per-job failures
                }
            }
        }

        $canonicalJson = ([PSCustomObject]@{
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
            warnings = @($warnings)
            startableJobs = @($startableJobs | Where-Object {
                $jobTaskType = ([string]$_.taskType).ToUpperInvariant()
                # Exclude hard-excluded task types
                if ($excludedTaskTypes.Count -gt 0 -and $jobTaskType -in $excludedTaskTypes) {
                    return $false
                }
                return $true
            })
            error = ''
        } | ConvertTo-Json -Depth 20)
    } catch {
        $canonicalJson = New-ErrorPayloadJson -Message $_.Exception.Message
    }

    $global:LASTEXITCODE = 0
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output $canonicalJson

    if ($PassThru) {
        [PSCustomObject]@{
            Json = $canonicalJson
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
