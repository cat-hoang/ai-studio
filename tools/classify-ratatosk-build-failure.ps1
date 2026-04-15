[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$IssueId = '',
    [string]$WorkspacePath = '',
    [string]$FailureText,

    [string[]]$TargetProjects = @(),
    [string[]]$FailedProjects = @(),
    [string[]]$TargetTests = @(),
    [string[]]$FailedTests = @(),
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

$worker = $null
$resolvedWorkspacePath = ''
$relativeWorkspacePath = ''

if (-not [string]::IsNullOrWhiteSpace($IssueId)) {
    $state = Read-RatatoskState
    $worker = Get-RatatoskWorker -State $state -IssueId $IssueId
    if (-not $worker) {
        throw "Worker not found for issue $IssueId"
    }

    if ([string]::IsNullOrWhiteSpace($Phase)) {
        $Phase = [string](Get-ObjectPropertyValue -Object $worker -Name 'phase' -Default '')
    }

    $buildPlan = Get-ObjectPropertyValue -Object $worker -Name 'buildPlan' -Default $null
    if ($TargetProjects.Count -eq 0 -and $null -ne $buildPlan) {
        $TargetProjects = @((Get-ObjectPropertyValue -Object $buildPlan -Name 'targetProjects' -Default @()))
    }
    if ($TargetTests.Count -eq 0 -and $null -ne $buildPlan) {
        $TargetTests = @((Get-ObjectPropertyValue -Object $buildPlan -Name 'targetTests' -Default @()))
    }

    $resolvedWorkspacePath = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) {
        Resolve-RatatoskPath -Path $WorkspacePath
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$worker.workspacePath)) {
        Resolve-RatatoskPath -Path ([string]$worker.workspacePath)
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedWorkspacePath)) {
        $relativeWorkspacePath = ConvertTo-RatatoskRelativePath -Path $resolvedWorkspacePath
    }
}

$assessment = Get-RatatoskBuildFailureAssessment `
    -FailureText $FailureText `
    -Phase $Phase `
    -TargetProjects $TargetProjects `
    -FailedProjects $FailedProjects `
    -TargetTests $TargetTests `
    -FailedTests $FailedTests

$result = [PSCustomObject]@{
    issueId = $IssueId
    phase = $Phase
    workspacePath = $relativeWorkspacePath
    buildFailure = $assessment
}

if ($null -ne $worker -and $PSCmdlet.ShouldProcess($IssueId, 'Classify Ratatosk build failure')) {
    $timestamp = [string](Get-ObjectPropertyValue -Object $assessment -Name 'updatedAt' -Default ((Get-Date).ToUniversalTime().ToString('o')))
    Set-RatatoskProperty -Object $worker -Name 'buildFailure' -Value $assessment
    if (-not [string]::IsNullOrWhiteSpace($relativeWorkspacePath)) {
        Set-RatatoskProperty -Object $worker -Name 'workspacePath' -Value $relativeWorkspacePath
    }
    Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp $timestamp
    Write-RatatoskState -State $state

    if (-not [string]::IsNullOrWhiteSpace($resolvedWorkspacePath)) {
        $artifactFile = Save-RatatoskWorkspaceArtifact -WorkspacePath $resolvedWorkspacePath -FileName 'build-failure.json' -Content $result
        Set-RatatoskProperty -Object $result -Name 'artifactFile' -Value $artifactFile
    }
}

$json = $result | ConvertTo-Json -Depth 20
Write-Output $json

if ($PassThru) {
    $result
}
