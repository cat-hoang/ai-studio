#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the appropriate studio agent tab for a given stage of the Autotask studio pipeline.

.DESCRIPTION
    Spawns a Windows Terminal tab running the correct agent CLI (architect, developer, tester, or reviewer)
    for the specified studio stage. Called by the studio-start orchestrator command and by gate-approval
    handlers when the pipeline needs to advance to the next stage.

    For the developer stage, if spec.md defines multiple independent sub-tasks, this script opens
    one tab per sub-task concurrently.

    Stages: architect | developer | tester | reviewer

.EXAMPLE
    # Launch architect for a new studio session
    .\launch-studio-team.ps1 -Cli auto -IssueId GH-42 -Title "Add dark mode" `
        -WorkspacePath "C:\git\autotask\workspaces\GH-42" `
        -ArtifactsPath "C:\git\autotask\workspaces\GH-42\studio" `
        -Repos '[{"name":"my-app","path":"C:\\git\\my-app","remoteName":"origin"}]' `
        -BranchPrefix "feature/autotask" -Stage architect

.EXAMPLE
    # Advance to developer stage after post-design gate approval
    .\launch-studio-team.ps1 -Cli auto -IssueId GH-42 -Title "Add dark mode" `
        -WorkspacePath "C:\git\autotask\workspaces\GH-42" `
        -ArtifactsPath "C:\git\autotask\workspaces\GH-42\studio" `
        -Repos '[{"name":"my-app","path":"C:\\git\\my-app","remoteName":"origin"}]' `
        -BranchPrefix "feature/autotask" -Stage developer
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('auto', 'claude', 'copilot')]
    [string]$Cli,

    [Parameter(Mandatory)]
    [string]$IssueId,

    [Parameter(Mandatory)]
    [string]$Title,

    [Parameter(Mandatory)]
    [string]$WorkspacePath,

    [Parameter(Mandatory)]
    [string]$ArtifactsPath,

    # JSON array of repo objects: [{"name":"...","path":"...","remoteName":"..."}]
    [Parameter(Mandatory)]
    [string]$Repos,

    [string]$BranchPrefix = '',

    [ValidateSet('architect', 'developer', 'tester', 'reviewer')]
    [string]$Stage = 'architect',

    [ValidateSet('suggestions-only', 'auto')]
    [string]$AutonomyMode = 'suggestions-only',

    [switch]$PostDesignGate,
    [switch]$PostPrGate,

    [int]$ReviewCycles = 2,
    [int]$ReviewCycleNumber = 0,

    [string]$PluginDir = (Split-Path -Parent $PSScriptRoot),

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutotaskRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Helper functions (shared patterns from launch-autotask-worker.ps1)
# ---------------------------------------------------------------------------

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Resolve-WorkerCli {
    param([string]$RequestedCli)
    $normalized = ($RequestedCli ?? '').Trim().ToLowerInvariant()
    if ($normalized -eq 'claude' -or $normalized -eq 'copilot') { return $normalized }

    foreach ($envVar in @('COPILOT_CLI', 'COPILOT_RUN_APP')) {
        if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($envVar))) {
            return 'copilot'
        }
    }
    foreach ($envVar in @('CLAUDECODE', 'CLAUDE_CODE', 'CLAUDECODE_ENTRYPOINT', 'CLAUDE_CODE_ENTRYPOINT')) {
        if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($envVar))) {
            return 'claude'
        }
    }

    $claudeAvailable  = Test-CommandAvailable -Name 'claude'
    $copilotAvailable = Test-CommandAvailable -Name 'copilot'
    if ($claudeAvailable  -and -not $copilotAvailable) { return 'claude' }
    if ($copilotAvailable -and -not $claudeAvailable)  { return 'copilot' }
    return 'claude'
}

function ConvertTo-EncodedCommand {
    param([Parameter(Mandatory)][string]$CommandText)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
}

function Get-StageIcon {
    param([string]$StageName)
    switch ($StageName) {
        'architect'  { return '📐' }
        'developer'  { return '⚙️' }
        'tester'     { return '🧪' }
        'reviewer'   { return '📝' }
        default      { return '🤖' }
    }
}

# ---------------------------------------------------------------------------
# Prompt file builders — one per stage
# ---------------------------------------------------------------------------

function New-ArchitectPrompt {
    param(
        [string]$IssueIdVal,
        [string]$TitleVal,
        [string]$WorkspacePathVal,
        [string]$ArtifactsPathVal,
        [string]$ReposVal,
        [string]$AutonomyModeVal,
        [bool]$PostDesignGateVal,
        [string]$AutotaskRootVal
    )

    $gateFlag = if ($PostDesignGateVal) { 'true' } else { 'false' }

    return @"
You are the Autotask Architect Agent for issue $IssueIdVal.
Read your full instructions from ``$AutotaskRootVal\agents\architect.md``.

issueId: $IssueIdVal
title: $TitleVal
workspacePath: $WorkspacePathVal
autotaskRoot: $AutotaskRootVal
artifactsPath: $ArtifactsPathVal
repos: $ReposVal
autonomyMode: $AutonomyModeVal
postDesignGate: $gateFlag

Keep the terminal tab title exactly as launched. Do not rename the tab.
Publish live activity via ``$AutotaskRootVal\tools\set-autotask-worker-activity.ps1``.
Begin work immediately.
"@
}

function New-DeveloperPrompt {
    param(
        [string]$IssueIdVal,
        [string]$TitleVal,
        [string]$SubTaskId,
        [string]$WorkspacePathVal,
        [string]$ArtifactsPathVal,
        [string]$ReposVal,
        [string]$BranchPrefixVal,
        [string]$AutotaskRootVal
    )

    return @"
You are the Autotask Developer Agent for issue $IssueIdVal.
Read your full instructions from ``$AutotaskRootVal\agents\developer.md``.

issueId: $IssueIdVal
title: $TitleVal
subTaskId: $SubTaskId
workspacePath: $WorkspacePathVal
autotaskRoot: $AutotaskRootVal
artifactsPath: $ArtifactsPathVal
repos: $ReposVal
branchPrefix: $BranchPrefixVal
workspaceMode: clone

Keep the terminal tab title exactly as launched. Do not rename the tab.
Publish live activity via ``$AutotaskRootVal\tools\set-autotask-worker-activity.ps1``.
Begin work immediately.
"@
}

function New-TesterPrompt {
    param(
        [string]$IssueIdVal,
        [string]$TitleVal,
        [string]$WorkspacePathVal,
        [string]$ArtifactsPathVal,
        [string]$ReposVal,
        [string]$AutotaskRootVal
    )

    return @"
You are the Autotask Tester Agent for issue $IssueIdVal.
Read your full instructions from ``$AutotaskRootVal\agents\tester.md``.

issueId: $IssueIdVal
title: $TitleVal
workspacePath: $WorkspacePathVal
autotaskRoot: $AutotaskRootVal
artifactsPath: $ArtifactsPathVal
repos: $ReposVal

Keep the terminal tab title exactly as launched. Do not rename the tab.
Publish live activity via ``$AutotaskRootVal\tools\set-autotask-worker-activity.ps1``.
Begin work immediately.
"@
}

function New-ReviewerPrompt {
    param(
        [string]$IssueIdVal,
        [string]$TitleVal,
        [string]$WorkspacePathVal,
        [string]$ArtifactsPathVal,
        [string]$ReposVal,
        [string]$AutotaskRootVal,
        [int]$ReviewCycleVal,
        [int]$MaxReviewCyclesVal
    )

    return @"
You are the Autotask Reviewer Agent for issue $IssueIdVal.
Read your full instructions from ``$AutotaskRootVal\agents\reviewer.md``.

issueId: $IssueIdVal
title: $TitleVal
workspacePath: $WorkspacePathVal
autotaskRoot: $AutotaskRootVal
artifactsPath: $ArtifactsPathVal
repos: $ReposVal
reviewCycle: $ReviewCycleVal
maxReviewCycles: $MaxReviewCyclesVal

Keep the terminal tab title exactly as launched. Do not rename the tab.
Publish live activity via ``$AutotaskRootVal\tools\set-autotask-worker-activity.ps1``.
Begin work immediately.
"@
}

# ---------------------------------------------------------------------------
# wt.exe argument builders
# ---------------------------------------------------------------------------

function New-ClaudeTabArguments {
    param(
        [string]$ResolvedWorkspacePath,
        [string]$ResolvedPromptFile,
        [string]$ResolvedPluginDir,
        [string]$TabTitle
    )

    return @(
        '-w', '0',
        'new-tab',
        '--title', $TabTitle,
        '--suppressApplicationTitle',
        '-d', $ResolvedWorkspacePath,
        'claude',
        '--system-prompt-file', $ResolvedPromptFile,
        '--dangerously-skip-permissions',
        '--plugin-dir', $ResolvedPluginDir,
        'Begin work immediately.'
    )
}

function New-CopilotTabArguments {
    param(
        [string]$ResolvedWorkspacePath,
        [string]$ResolvedPromptFile,
        [string]$ResolvedPluginDir,
        [string]$TabTitle
    )

    $escapedWorkspacePath = $ResolvedWorkspacePath.Replace("'", "''")
    $escapedPromptFile    = $ResolvedPromptFile.Replace("'", "''")
    $escapedPluginDir     = $ResolvedPluginDir.Replace("'", "''")

    $commandText = @"
Set-Location -LiteralPath '$escapedWorkspacePath'
`$prompt = Get-Content -LiteralPath '$escapedPromptFile' -Raw -Encoding UTF8
copilot --plugin-dir '$escapedPluginDir' --allow-all --no-ask-user --add-dir '$escapedPluginDir' --add-dir '$escapedWorkspacePath' -i `$prompt
"@

    $pwshCmd  = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $shellExe = if ($pwshCmd) { $pwshCmd.Source } else { 'powershell.exe' }

    return @(
        '-w', '0',
        'new-tab',
        '--title', $TabTitle,
        '--suppressApplicationTitle',
        '-d', $ResolvedWorkspacePath,
        $shellExe,
        '-NoExit',
        '-NoProfile',
        '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText)))
    )
}

# ---------------------------------------------------------------------------
# Launch a single agent tab
# ---------------------------------------------------------------------------

function Invoke-AgentTab {
    param(
        [string]$ResolvedCli,
        [string]$ResolvedWorkspacePath,
        [string]$PromptFile,
        [string]$ResolvedPluginDir,
        [string]$TabTitle
    )

    $resolvedPromptFile = Get-FullPath -Path $PromptFile

    $argList = if ($ResolvedCli -eq 'claude') {
        New-ClaudeTabArguments `
            -ResolvedWorkspacePath $ResolvedWorkspacePath `
            -ResolvedPromptFile    $resolvedPromptFile `
            -ResolvedPluginDir     $ResolvedPluginDir `
            -TabTitle              $TabTitle
    } else {
        New-CopilotTabArguments `
            -ResolvedWorkspacePath $ResolvedWorkspacePath `
            -ResolvedPromptFile    $resolvedPromptFile `
            -ResolvedPluginDir     $ResolvedPluginDir `
            -TabTitle              $TabTitle
    }

    if ($PSCmdlet.ShouldProcess($TabTitle, "Launch studio agent tab via $ResolvedCli")) {
        & wt.exe @argList | Out-Null
    }

    return $argList
}

# ---------------------------------------------------------------------------
# Read sub-tasks from spec.md (parallel developer support)
# ---------------------------------------------------------------------------

function Get-SpecSubTasks {
    param([string]$SpecPath)

    if (-not (Test-Path -LiteralPath $SpecPath)) { return @('all') }

    $content  = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8
    $matches_ = [regex]::Matches($content, '(?m)^###\s+Sub-task\s+(\S+)')
    if ($matches_.Count -lt 2) { return @('all') }

    return $matches_ | ForEach-Object { $_.Groups[1].Value }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    $resolvedWorkspacePath = Get-FullPath -Path $WorkspacePath
    $resolvedArtifactsPath = Get-FullPath -Path $ArtifactsPath
    $resolvedPluginDir     = Get-FullPath -Path $PluginDir
    $resolvedCli           = Resolve-WorkerCli -RequestedCli $Cli

    $studioFolder = Join-Path $resolvedWorkspacePath 'studio'
    if (-not (Test-Path -LiteralPath $studioFolder)) {
        New-Item -ItemType Directory -Path $studioFolder -Force | Out-Null
    }

    # Validate prerequisites
    if (-not (Test-Path -LiteralPath $resolvedWorkspacePath)) {
        throw "Workspace path not found: $resolvedWorkspacePath"
    }
    if (-not (Test-CommandAvailable -Name 'wt.exe')) {
        throw 'Windows Terminal (wt.exe) is required to launch studio agents.'
    }
    if (-not (Test-CommandAvailable -Name $resolvedCli)) {
        throw "Required worker CLI not found on PATH: $resolvedCli"
    }
    if ($resolvedCli -eq 'copilot') {
        $copilotPluginManifest = Join-Path $resolvedPluginDir 'plugin.json'
        if (-not (Test-Path -LiteralPath $copilotPluginManifest)) {
            throw "Copilot plugin manifest not found: $copilotPluginManifest"
        }
    }

    $stageIcon  = Get-StageIcon -StageName $Stage
    $launchedTabs = [System.Collections.Generic.List[object]]::new()

    switch ($Stage) {

        'architect' {
            $promptContent = New-ArchitectPrompt `
                -IssueIdVal       $IssueId `
                -TitleVal         $Title `
                -WorkspacePathVal $resolvedWorkspacePath `
                -ArtifactsPathVal $resolvedArtifactsPath `
                -ReposVal         $Repos `
                -AutonomyModeVal  $AutonomyMode `
                -PostDesignGateVal $PostDesignGate.IsPresent `
                -AutotaskRootVal  $AutotaskRoot

            $promptFile = Join-Path $resolvedWorkspacePath '.studio-prompt-architect.md'
            [System.IO.File]::WriteAllText($promptFile, $promptContent, [System.Text.Encoding]::UTF8)

            $tabTitle = "$stageIcon $IssueId architect"
            $argList  = Invoke-AgentTab `
                -ResolvedCli          $resolvedCli `
                -ResolvedWorkspacePath $resolvedWorkspacePath `
                -PromptFile           $promptFile `
                -ResolvedPluginDir    $resolvedPluginDir `
                -TabTitle             $tabTitle

            $launchedTabs.Add([PSCustomObject]@{ Stage = 'architect'; SubTaskId = 'all'; Title = $tabTitle; PromptFile = $promptFile; ArgumentList = $argList })
        }

        'developer' {
            $specPath = Join-Path $resolvedArtifactsPath 'spec.md'
            $subTasks = Get-SpecSubTasks -SpecPath $specPath

            foreach ($subTask in $subTasks) {
                $promptContent = New-DeveloperPrompt `
                    -IssueIdVal       $IssueId `
                    -TitleVal         $Title `
                    -SubTaskId        $subTask `
                    -WorkspacePathVal $resolvedWorkspacePath `
                    -ArtifactsPathVal $resolvedArtifactsPath `
                    -ReposVal         $Repos `
                    -BranchPrefixVal  $BranchPrefix `
                    -AutotaskRootVal  $AutotaskRoot

                $safeSub    = $subTask -replace '[^a-zA-Z0-9\-]', '-'
                $promptFile = Join-Path $resolvedWorkspacePath ".studio-prompt-developer-$safeSub.md"
                [System.IO.File]::WriteAllText($promptFile, $promptContent, [System.Text.Encoding]::UTF8)

                $tabTitle = "$stageIcon $IssueId dev:$subTask"
                $argList  = Invoke-AgentTab `
                    -ResolvedCli          $resolvedCli `
                    -ResolvedWorkspacePath $resolvedWorkspacePath `
                    -PromptFile           $promptFile `
                    -ResolvedPluginDir    $resolvedPluginDir `
                    -TabTitle             $tabTitle

                $launchedTabs.Add([PSCustomObject]@{ Stage = 'developer'; SubTaskId = $subTask; Title = $tabTitle; PromptFile = $promptFile; ArgumentList = $argList })
            }
        }

        'tester' {
            $promptContent = New-TesterPrompt `
                -IssueIdVal       $IssueId `
                -TitleVal         $Title `
                -WorkspacePathVal $resolvedWorkspacePath `
                -ArtifactsPathVal $resolvedArtifactsPath `
                -ReposVal         $Repos `
                -AutotaskRootVal  $AutotaskRoot

            $promptFile = Join-Path $resolvedWorkspacePath '.studio-prompt-tester.md'
            [System.IO.File]::WriteAllText($promptFile, $promptContent, [System.Text.Encoding]::UTF8)

            $tabTitle = "$stageIcon $IssueId tester"
            $argList  = Invoke-AgentTab `
                -ResolvedCli          $resolvedCli `
                -ResolvedWorkspacePath $resolvedWorkspacePath `
                -PromptFile           $promptFile `
                -ResolvedPluginDir    $resolvedPluginDir `
                -TabTitle             $tabTitle

            $launchedTabs.Add([PSCustomObject]@{ Stage = 'tester'; SubTaskId = 'all'; Title = $tabTitle; PromptFile = $promptFile; ArgumentList = $argList })
        }

        'reviewer' {
            $promptContent = New-ReviewerPrompt `
                -IssueIdVal         $IssueId `
                -TitleVal           $Title `
                -WorkspacePathVal   $resolvedWorkspacePath `
                -ArtifactsPathVal   $resolvedArtifactsPath `
                -ReposVal           $Repos `
                -AutotaskRootVal    $AutotaskRoot `
                -ReviewCycleVal     $ReviewCycleNumber `
                -MaxReviewCyclesVal $ReviewCycles

            $promptFile = Join-Path $resolvedWorkspacePath ".studio-prompt-reviewer-cycle$ReviewCycleNumber.md"
            [System.IO.File]::WriteAllText($promptFile, $promptContent, [System.Text.Encoding]::UTF8)

            $tabTitle = "$stageIcon $IssueId reviewer (cycle $ReviewCycleNumber)"
            $argList  = Invoke-AgentTab `
                -ResolvedCli          $resolvedCli `
                -ResolvedWorkspacePath $resolvedWorkspacePath `
                -PromptFile           $promptFile `
                -ResolvedPluginDir    $resolvedPluginDir `
                -TabTitle             $tabTitle

            $launchedTabs.Add([PSCustomObject]@{ Stage = 'reviewer'; SubTaskId = 'all'; Title = $tabTitle; PromptFile = $promptFile; ArgumentList = $argList })
        }
    }

    Write-Host "✅ Launched $($launchedTabs.Count) studio agent tab(s) for $IssueId — stage: $Stage"
    foreach ($tab in $launchedTabs) {
        Write-Host "   $($tab.Title)"
    }

    if ($PassThru) {
        return $launchedTabs
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
