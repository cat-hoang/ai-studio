#Requires -Version 5.1
<#
.SYNOPSIS
    Approves a studio pipeline gate, advancing the pipeline to the next stage.

.DESCRIPTION
    Reads state.json to find a running worker at a gate (studioTeam.activeAgent starts with
    'gate:'), updates handoff.json with approval metadata, advances the pipeline state, and
    re-invokes launch-studio-team.ps1 for the next stage.

    Supported gates:
      gate:post-design  ->  launches developer stage
      gate:post-pr      ->  marks pipeline ready for human merge (no auto-launch)

.EXAMPLE
    .\approve-studio-gate.ps1 -IssueId GH-42
    .\approve-studio-gate.ps1 -IssueId GH-42 -ApprovedBy "cat@example.com"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [string]$IssueId,

    [string]$ApprovedBy = 'dashboard',

    [string]$AutotaskRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')
. (Join-Path $PSScriptRoot 'autotask-config-common.ps1')

function Write-Result {
    param([bool]$Success, [string]$Message = '', [string]$Error = '', [hashtable]$Extra = @{})
    $obj = [ordered]@{ success = $Success; issueId = $IssueId }
    foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    if ($Success) { $obj['message'] = $Message } else { $obj['error'] = $Error }
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output ($obj | ConvertTo-Json -Depth 5 -Compress)
}

function Get-NextStageForGate {
    param([string]$GateName)
    switch ($GateName) {
        'gate:post-design' { return 'developer' }
        'gate:post-pr'     { return 'done' }
        default            { return $null }
    }
}

function Main {
    $state = Read-AutotaskState

    # Find the worker by issueId or jobNumber
    $worker = @($state.workers) | Where-Object {
        $id = if ($_.PSObject.Properties['issueId']) { [string]$_.issueId }
              elseif ($_.PSObject.Properties['jobNumber']) { [string]$_.jobNumber }
              else { '' }
        $id -eq $IssueId
    } | Select-Object -First 1

    if (-not $worker) {
        Write-Result -Success $false -Error "No active worker found for $IssueId. Is it running in studio mode?"
        return
    }

    if (-not $worker.PSObject.Properties['studioTeam'] -or $null -eq $worker.studioTeam) {
        Write-Result -Success $false -Error "$IssueId is not running in studio mode (no studioTeam in state)."
        return
    }

    $studioTeam  = $worker.studioTeam
    $activeAgent = [string]($studioTeam.PSObject.Properties['activeAgent'] ? $studioTeam.activeAgent : '')
    if (-not $activeAgent.StartsWith('gate:')) {
        Write-Result -Success $false -Error "$IssueId is not at a gate (current activeAgent: '$activeAgent')."
        return
    }

    $gateName  = $activeAgent
    $nextStage = Get-NextStageForGate -GateName $gateName
    if (-not $nextStage) {
        Write-Result -Success $false -Error "Unknown gate '$gateName' — cannot determine next stage."
        return
    }

    # Resolve paths from worker / studioTeam
    $workspacePath = [string]$worker.workspacePath
    $artifactsPath = if ($studioTeam.PSObject.Properties['artifactsPath'] -and $studioTeam.artifactsPath) {
        [string]$studioTeam.artifactsPath
    } else {
        Join-Path $workspacePath 'studio'
    }
    $issueTitle    = if ($worker.PSObject.Properties['title'] -and $worker.title) { [string]$worker.title } else { $IssueId }
    $currentCycles = if ($studioTeam.PSObject.Properties['reviewCycles']) { [int]$studioTeam.reviewCycles } else { 0 }

    # Repos stored in studioTeam at launch time (see studio-start.md Step 9c)
    $reposJson = '[]'
    if ($studioTeam.PSObject.Properties['repos'] -and $null -ne $studioTeam.repos) {
        try { $reposJson = $studioTeam.repos | ConvertTo-Json -Compress -Depth 5 } catch { }
    }

    # Launch params: prefer studioTeam-stored values, fall back to config
    $configContent = Get-AutotaskConfigContent
    $workerCli = if ($studioTeam.PSObject.Properties['workerCli'] -and $studioTeam.workerCli) {
        [string]$studioTeam.workerCli
    } else {
        Get-AutotaskConfigTextValue -Content $configContent -Key 'worker_cli' -Default 'claude'
    }
    $branchPrefix = if ($studioTeam.PSObject.Properties['branchPrefix'] -and $studioTeam.branchPrefix) {
        [string]$studioTeam.branchPrefix
    } else {
        Get-AutotaskConfigTextValue -Content $configContent -Key 'branch_prefix' -Default ''
    }
    $autonomyMode = if ($studioTeam.PSObject.Properties['autonomyMode'] -and $studioTeam.autonomyMode) {
        [string]$studioTeam.autonomyMode
    } else {
        Get-AutotaskConfigTextValue -Content $configContent -Key 'autonomy_mode' -Default 'suggestions-only'
    }
    $reviewCycles = Get-AutotaskConfigNumberValue -Content $configContent -Key 'review_cycles' -Default 2

    # Update handoff.json gate fields
    $handoffPath = Join-Path $artifactsPath 'handoff.json'
    if (Test-Path -LiteralPath $handoffPath) {
        $handoff = Get-Content -LiteralPath $handoffPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Set-AutotaskProperty -Object $handoff -Name 'gate' -Value ([PSCustomObject]@{
            name       = $gateName
            status     = 'approved'
            approvedBy = $ApprovedBy
            approvedAt = (Get-Date -Format 'o')
        })
        $handoff | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
    }

    # Advance state.json
    $phaseSuffix = ($gateName -replace '^gate:', '') + '-approved'
    if ($nextStage -eq 'done') {
        Set-AutotaskProperty -Object $studioTeam -Name 'activeAgent' -Value 'orchestrator:post-pr'
        $worker.phase = 'post-pr-gate-approved'
    } else {
        Set-AutotaskProperty -Object $studioTeam -Name 'activeAgent' -Value $nextStage
        $worker.phase = $phaseSuffix
    }
    Set-AutotaskProperty -Object $worker -Name 'lastUpdated' -Value (Get-Date -Format 'o')
    Write-AutotaskState -State $state

    # Launch next agent tab (skip for gate:post-pr — that is a human merge step)
    if ($nextStage -ne 'done') {
        $launchScript = Join-Path $AutotaskRoot 'tools' 'launch-studio-team.ps1'
        $launchArgs = @(
            '-Cli',               $workerCli,
            '-IssueId',           $IssueId,
            '-Title',             $issueTitle,
            '-WorkspacePath',     $workspacePath,
            '-ArtifactsPath',     $artifactsPath,
            '-Repos',             $reposJson,
            '-BranchPrefix',      $branchPrefix,
            '-Stage',             $nextStage,
            '-AutonomyMode',      $autonomyMode,
            '-ReviewCycles',      $reviewCycles,
            '-ReviewCycleNumber', $currentCycles,
            '-PluginDir',         $AutotaskRoot
        )
        if ($PSCmdlet.ShouldProcess($IssueId, "Launch studio stage '$nextStage'")) {
            & $launchScript @launchArgs | Out-Null
        }
    }

    Write-Result -Success $true `
        -Message "Gate '$gateName' approved for $IssueId. Next stage: $nextStage." `
        -Extra @{ gate = $gateName; nextStage = $nextStage; approvedBy = $ApprovedBy }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
