[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookDecision {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('approve', 'block')]
        [string]$Decision,

        [string]$Reason = '',
        [string]$SystemMessage = ''
    )

    [PSCustomObject]@{
        decision = $Decision
        reason = $Reason
        systemMessage = $SystemMessage
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $hookInput = $inputText | ConvertFrom-Json
    $cwd = [string]$hookInput.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $workspaceRoot = [IO.Path]::GetFullPath((Join-Path $pluginRoot 'workspaces'))
    $currentDirectory = [IO.Path]::GetFullPath($cwd).TrimEnd('\')

    if (-not $currentDirectory.StartsWith($workspaceRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $issueId = Split-Path -Leaf $currentDirectory
    if ([string]::IsNullOrWhiteSpace($issueId)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    . (Join-Path $pluginRoot 'tools\autotask-state-common.ps1')

    $state = Read-AutotaskState
    $job = @(
        $state.workers +
        $state.completedJobs +
        $state.failedJobs |
            Where-Object { ($_.issueId -eq $issueId) -or ($_.jobNumber -eq $issueId) }
    ) | Select-Object -First 1

    if (-not $job) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $reportPath = [string]$job.finalReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
        $resolvedPath = if ([IO.Path]::IsPathRooted($reportPath)) {
            $reportPath
        } else {
            Join-Path $pluginRoot $reportPath
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            Write-HookDecision -Decision 'approve'
            exit 0
        }
    }
    # Also approve if finalReportedAt is set (report was captured but path may have moved)
    if (-not [string]::IsNullOrWhiteSpace([string]$job.finalReportedAt)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $currentStatus = ([string]$job.status).ToLowerInvariant()
    $instruction = if ($currentStatus -eq 'done') {
        "Run .\\tools\\finalize-autotask-worker.ps1 -IssueId $issueId -Status done -Summary '<final summary>' before stopping."
    } else {
        "Run .\\tools\\finalize-autotask-worker.ps1 -IssueId $issueId -Status failed -Summary '<failure summary>' -ErrorMessage '<error>' before stopping."
    }

    Write-HookDecision `
        -Decision 'block' `
        -Reason "Autotask worker $issueId has no final report yet." `
        -SystemMessage "Before stopping a Autotask worker, capture a final report artifact and notifications. $instruction"
    exit 0
} catch {
    Write-HookDecision -Decision 'approve' -SystemMessage "Autotask stop hook failed open: $($_.Exception.Message)"
    exit 0
}
