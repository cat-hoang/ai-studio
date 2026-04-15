[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('auto', 'claude', 'copilot')]
    [string]$Cli,

    [Parameter(Mandatory)]
    [string]$JobNumber,

    [Parameter(Mandatory)]
    [string]$TaskType,

    [Parameter(Mandatory)]
    [string]$WorkspacePath,

    [Parameter(Mandatory)]
    [string]$PromptFile,

    [string]$PluginDir = (Split-Path -Parent $PSScriptRoot),
    [int]$Zone = 0,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Resolve-WorkerCli {
    param(
        [string]$RequestedCli
    )

    $normalizedCli = ($RequestedCli ?? '').Trim().ToLowerInvariant()
    if ($normalizedCli -eq 'claude' -or $normalizedCli -eq 'copilot') {
        return $normalizedCli
    }

    $copilotHostDetected = @(
        $env:COPILOT_CLI,
        $env:COPILOT_RUN_APP
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($copilotHostDetected) {
        return 'copilot'
    }

    $claudeHostDetected = @(
        $env:CLAUDECODE,
        $env:CLAUDE_CODE,
        $env:CLAUDECODE_ENTRYPOINT,
        $env:CLAUDE_CODE_ENTRYPOINT
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($claudeHostDetected) {
        return 'claude'
    }

    $claudeAvailable = Test-CommandAvailable -Name 'claude'
    $copilotAvailable = Test-CommandAvailable -Name 'copilot'
    if ($claudeAvailable -and -not $copilotAvailable) { return 'claude' }
    if ($copilotAvailable -and -not $claudeAvailable) { return 'copilot' }

    return 'claude'
}

function ConvertTo-EncodedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$CommandText
    )

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
}

function Get-LaunchStatusIcon {
    param(
        [Parameter(Mandatory)]
        [string]$TaskType
    )

    $normalizedTaskType = $TaskType.ToLowerInvariant()
    if ($normalizedTaskType -match 'investigat|analysis|triage') { return '🔎' }
    if ($normalizedTaskType -match 'review') { return '📝' }
    if ($normalizedTaskType -match 'test') { return '🧪' }
    return '⚙️'
}

function New-ClaudeTabArguments {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedWorkspacePath,

        [Parameter(Mandatory)]
        [string]$ResolvedPromptFile,

        [Parameter(Mandatory)]
        [string]$ResolvedPluginDir,

        [Parameter(Mandatory)]
        [string]$Title
    )

    # Prefer pwsh.exe (PS7) via full path; fall back to powershell.exe (PS5.1) if not found
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $shellExe = if ($pwshCmd) { $pwshCmd.Source } else { 'powershell.exe' }

    return @(
        '-w', '0',
        'new-tab',
        '--title', $Title,
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
        [Parameter(Mandatory)]
        [string]$ResolvedWorkspacePath,

        [Parameter(Mandatory)]
        [string]$ResolvedPromptFile,

        [Parameter(Mandatory)]
        [string]$ResolvedPluginDir,

        [Parameter(Mandatory)]
        [string]$Title
    )

    $escapedWorkspacePath = $ResolvedWorkspacePath.Replace("'", "''")
    $escapedPromptFile = $ResolvedPromptFile.Replace("'", "''")
    $escapedPluginDir = $ResolvedPluginDir.Replace("'", "''")

    $commandText = @"
# Normalise edi credentials from User-level env vars so edi CLI always works
# regardless of what the parent shell had in its session environment.
`$glowUser = [System.Environment]::GetEnvironmentVariable('GLOW_USERNAME', 'User')
`$glowPass = [System.Environment]::GetEnvironmentVariable('GLOW_PASSWORD', 'User')
if (`$glowUser) { `$env:GLOW_USERNAME = `$glowUser }
if (`$glowPass) { `$env:GLOW_PASSWORD = `$glowPass }
Set-Location -LiteralPath '$escapedWorkspacePath'
`$prompt = Get-Content -LiteralPath '$escapedPromptFile' -Raw -Encoding UTF8
copilot --plugin-dir '$escapedPluginDir' --allow-all --no-ask-user --add-dir '$escapedPluginDir' --add-dir '$escapedWorkspacePath' -i `$prompt
"@

    # Prefer pwsh.exe (PS7) via full path; fall back to powershell.exe (PS5.1) if not found
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $shellExe = if ($pwshCmd) { $pwshCmd.Source } else { 'powershell.exe' }

    return @(
        '-w', '0',
        'new-tab',
        '--title', $Title,
        '--suppressApplicationTitle',
        '-d', $ResolvedWorkspacePath,
        $shellExe,
        '-NoExit',
        '-NoProfile',
        '-EncodedCommand', (ConvertTo-EncodedCommand -CommandText $commandText)
    )
}

function Main {
    $resolvedWorkspacePath = Get-FullPath -Path $WorkspacePath
    $resolvedPromptFile = Get-FullPath -Path $PromptFile
    $resolvedPluginDir = Get-FullPath -Path $PluginDir
    $copilotPluginManifest = Join-Path $resolvedPluginDir 'plugin.json'
    $resolvedCli = Resolve-WorkerCli -RequestedCli $Cli
    $statusIcon = Get-LaunchStatusIcon -TaskType $TaskType
    $title = '{0} {1} {2}' -f $statusIcon, $JobNumber, $TaskType

    if (-not (Test-Path -LiteralPath $resolvedWorkspacePath)) {
        throw "Workspace path not found: $resolvedWorkspacePath"
    }

    if (-not (Test-Path -LiteralPath $resolvedPromptFile)) {
        throw "Prompt file not found: $resolvedPromptFile"
    }

    if (-not (Test-Path -LiteralPath $resolvedPluginDir)) {
        throw "Plugin directory not found: $resolvedPluginDir"
    }

    if (-not (Test-CommandAvailable -Name 'wt.exe')) {
        throw 'Windows Terminal (wt.exe) is required to launch Ratatosk workers.'
    }

    if (-not (Test-CommandAvailable -Name $resolvedCli)) {
        throw "Required worker CLI not found on PATH: $resolvedCli"
    }

    if ($resolvedCli -eq 'copilot' -and -not (Test-Path -LiteralPath $copilotPluginManifest)) {
        throw "Copilot plugin manifest not found: $copilotPluginManifest"
    }

    $argumentList = if ($resolvedCli -eq 'claude') {
        New-ClaudeTabArguments -ResolvedWorkspacePath $resolvedWorkspacePath -ResolvedPromptFile $resolvedPromptFile -ResolvedPluginDir $resolvedPluginDir -Title $title
    } else {
        New-CopilotTabArguments -ResolvedWorkspacePath $resolvedWorkspacePath -ResolvedPromptFile $resolvedPromptFile -ResolvedPluginDir $resolvedPluginDir -Title $title
    }

    if ($PSCmdlet.ShouldProcess($title, "Launch Ratatosk worker via $resolvedCli")) {
        & wt.exe @argumentList | Out-Null
    }

    if ($PassThru) {
        [PSCustomObject]@{
            RequestedCli = $Cli
            Cli = $resolvedCli
            JobNumber = $JobNumber
            TaskType = $TaskType
            Zone = $Zone
            WorkspacePath = $resolvedWorkspacePath
            PromptFile = $resolvedPromptFile
            PluginDir = $resolvedPluginDir
            Title = $title
            ArgumentList = $argumentList
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
