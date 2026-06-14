[CmdletBinding()]
param(
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

        $bunExe = (Get-Command bun -ErrorAction SilentlyContinue)?.Source
        if (-not $bunExe) {
            $bunExe = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
        }
        if (-not (Test-Path -LiteralPath $bunExe)) {
            throw "bun executable not found. Ensure bun is installed and available in PATH."
        }
        $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) "query-issue-source-stderr-$PID.txt"
        $rawLines = @(& $bunExe $scriptPath 2>$stderrFile)
        $exitCode = $LASTEXITCODE
        $stderrText = ''
        if (Test-Path $stderrFile) {
            $raw = Get-Content $stderrFile -Raw
            if ($raw) { $stderrText = $raw.Trim() }
            Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
        }
        if ($exitCode -ne 0) {
            # Try to extract the error message from the JSON payload written to stdout
            $jsonError = ''
            $stdoutJson = $rawLines -join "`n"
            try {
                $parsed = $stdoutJson | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.error) { $jsonError = $parsed.error }
            } catch {}
            $detail = if ($jsonError) { $jsonError } elseif ($stderrText) { $stderrText } else { "exit code $exitCode" }
            throw "query-issue-source.ts failed: $detail"
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

function Main {
    $canonicalJson = ''

    try {
        $orchestratorRoot = Get-OrchestratorRoot
        $configContent = Get-ConfigContent -Path @(
            (Join-Path $orchestratorRoot 'config.yaml'),
            (Join-Path $orchestratorRoot 'config.local.yaml')
        )

        $warnings = New-Object System.Collections.Generic.List[string]
        $startableJobs = @()

        $issueSourceAdapter = Get-ConfigSectionValue -Content $configContent -Section 'issue_source' -Key 'adapter'
        $adapterResult = Invoke-GenericAdapter -OrchestratorRoot $orchestratorRoot -AdapterName $issueSourceAdapter
        foreach ($w in @($adapterResult.warnings)) { $warnings.Add([string]$w) }
        $startableJobs = @($adapterResult.startableJobs)

        $canonicalJson = ([PSCustomObject]@{
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
            warnings = @($warnings)
            startableJobs = @($startableJobs)
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
