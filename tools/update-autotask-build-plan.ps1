[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = '',
    [string]$WorkspacePath = '',
    [string]$BuildMode = '',
    [string[]]$TargetProjects = @(),
    [string[]]$TargetTests = @(),
    [string[]]$BuildCommands = @(),
    [string[]]$TestCommands = @(),
    [string[]]$Notes = @(),
    [string]$ArtifactCacheStatus = '',
    [string]$ArtifactPath = '',
    [string]$ArtifactBuildId = '',
    [string]$CachePath = '',
    [string]$ArtifactSource = '',
    [string]$ExtractedTo = '',
    [switch]$PassThru
)

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
            [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        }
    }

    return ($chunks -join [Environment]::NewLine)
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

function Resolve-ArtifactCachePath {
    param(
        [string]$ConfiguredCachePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredCachePath)) {
        return (Resolve-AutotaskPath -Path $ConfiguredCachePath)
    }

    $configContent = Get-ConfigContent
    $configuredPath = Get-ConfigTextValue -Content $configContent -Key 'artifacts_cache' -Default 'artifacts-cache'
    return (Resolve-AutotaskPath -Path $configuredPath)
}

$state = Read-AutotaskState
$worker = Get-AutotaskWorker -State $state -JobNumber $JobNumber -TaskSequence $TaskSequence
if (-not $worker) {
    throw "Worker not found for job $JobNumber"
}

$timestamp = (Get-Date).ToUniversalTime().ToString('o')
$resolvedWorkspacePath = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) {
    Resolve-AutotaskPath -Path $WorkspacePath
} elseif (-not [string]::IsNullOrWhiteSpace([string]$worker.workspacePath)) {
    Resolve-AutotaskPath -Path ([string]$worker.workspacePath)
} else {
    throw "Workspace path not available for job $JobNumber"
}
$relativeWorkspacePath = ConvertTo-AutotaskRelativePath -Path $resolvedWorkspacePath

$buildPlan = Get-ObjectPropertyValue -Object $worker -Name 'buildPlan' -Default (New-AutotaskBuildPlan -Timestamp $timestamp)
$artifactUsage = Get-ObjectPropertyValue -Object $worker -Name 'artifactUsage' -Default (New-AutotaskArtifactUsage -Branch ([string]$worker.branch) -Timestamp $timestamp)

if (-not [string]::IsNullOrWhiteSpace($BuildMode)) {
    Set-AutotaskProperty -Object $buildPlan -Name 'buildMode' -Value $BuildMode.Trim()
}
Set-AutotaskProperty -Object $buildPlan -Name 'targetProjects' -Value (Get-AutotaskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $buildPlan -Name 'targetProjects' -Default @()),
        $TargetProjects
    ))
Set-AutotaskProperty -Object $buildPlan -Name 'targetTests' -Value (Get-AutotaskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $buildPlan -Name 'targetTests' -Default @()),
        $TargetTests
    ))
Set-AutotaskProperty -Object $buildPlan -Name 'buildCommands' -Value (Get-AutotaskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $buildPlan -Name 'buildCommands' -Default @()),
        $BuildCommands
    ))
Set-AutotaskProperty -Object $buildPlan -Name 'testCommands' -Value (Get-AutotaskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $buildPlan -Name 'testCommands' -Default @()),
        $TestCommands
    ))
Set-AutotaskProperty -Object $buildPlan -Name 'notes' -Value (Get-AutotaskUniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $buildPlan -Name 'notes' -Default @()),
        $Notes
    ))
Set-AutotaskProperty -Object $buildPlan -Name 'updatedAt' -Value $timestamp

$artifactUpdateRequested = @(
    $ArtifactCacheStatus,
    $ArtifactPath,
    $ArtifactBuildId,
    $CachePath,
    $ArtifactSource,
    $ExtractedTo
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

if ($artifactUpdateRequested.Count -gt 0) {
    if (-not [string]::IsNullOrWhiteSpace($ArtifactCacheStatus)) {
        Set-AutotaskProperty -Object $artifactUsage -Name 'cacheStatus' -Value $ArtifactCacheStatus.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
        Set-AutotaskProperty -Object $artifactUsage -Name 'artifactPath' -Value $ArtifactPath.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ArtifactBuildId)) {
        Set-AutotaskProperty -Object $artifactUsage -Name 'artifactBuildId' -Value $ArtifactBuildId.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ArtifactSource)) {
        Set-AutotaskProperty -Object $artifactUsage -Name 'source' -Value $ArtifactSource.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ExtractedTo)) {
        Set-AutotaskProperty -Object $artifactUsage -Name 'extractedTo' -Value $ExtractedTo.Trim()
    }

    $resolvedCachePath = Resolve-ArtifactCachePath -ConfiguredCachePath $CachePath
    Set-AutotaskProperty -Object $artifactUsage -Name 'cachePath' -Value $resolvedCachePath
    Set-AutotaskProperty -Object $artifactUsage -Name 'branch' -Value ([string]$worker.branch)
    Set-AutotaskProperty -Object $artifactUsage -Name 'sharedCache' -Value $true
    Set-AutotaskProperty -Object $artifactUsage -Name 'updatedAt' -Value $timestamp
}

$payload = [PSCustomObject]@{
    jobNumber = $JobNumber
    workspacePath = $relativeWorkspacePath
    buildPlan = $buildPlan
    artifactUsage = $artifactUsage
    updatedAt = $timestamp
}

if ($PSCmdlet.ShouldProcess($JobNumber, 'Update Autotask build plan')) {
    Set-AutotaskProperty -Object $worker -Name 'workspacePath' -Value $relativeWorkspacePath
    Set-AutotaskProperty -Object $worker -Name 'buildPlan' -Value $buildPlan
    Set-AutotaskProperty -Object $worker -Name 'artifactUsage' -Value $artifactUsage
    Set-AutotaskWorkerHeartbeat -Worker $worker -Timestamp $timestamp
    Write-AutotaskState -State $state
    $artifactFile = Save-AutotaskWorkspaceArtifact -WorkspacePath $resolvedWorkspacePath -FileName 'build-plan.json' -Content $payload
} else {
    $artifactFile = ConvertTo-AutotaskRelativePath -Path (Join-Path (Join-Path $resolvedWorkspacePath '.autotask') 'build-plan.json')
}

$result = [PSCustomObject]@{
    success = $true
    jobNumber = $JobNumber
    buildPlan = $buildPlan
    artifactUsage = $artifactUsage
    artifactFile = $artifactFile
}

$json = $result | ConvertTo-Json -Depth 20
Write-Output $json

if ($PassThru) {
    $result
}
