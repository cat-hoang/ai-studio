#Requires -Version 7.0
<#
.SYNOPSIS
    Autotask orchestrator installer.
.DESCRIPTION
    Sets up directories, configuration, and CLI-specific entrypoints for the
    Autotask orchestrator. Run from any directory; paths are absolute.
#>
[CmdletBinding()]
param(
    [switch]$Force  # Overwrite config.local.yaml even if it exists
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Status  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "[-] $Msg" -ForegroundColor Red }

function Test-Command {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$orchestratorRoot  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$setupDir          = Join-Path $orchestratorRoot 'setup'
$commandsDir       = Join-Path $orchestratorRoot 'commands'
$claudeCommandsDir = Join-Path $env:USERPROFILE '.claude' 'commands'
$copilotHelperPath = Join-Path $orchestratorRoot 'tools\invoke-autotask-copilot.ps1'
$templateFile      = Join-Path $orchestratorRoot 'config.local.yaml.template'
$localConfigFile   = Join-Path $orchestratorRoot 'config.local.yaml'

$workspaceDir      = Join-Path $orchestratorRoot 'workspaces'
$artifactsCacheDir = Join-Path $orchestratorRoot 'artifacts-cache'

Write-Host ''
Write-Host '=========================================' -ForegroundColor Magenta
Write-Host '  Autotask Orchestrator Installer v1.0'   -ForegroundColor Magenta
Write-Host '=========================================' -ForegroundColor Magenta
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
Write-Status 'Checking prerequisites...'

$requiredPrereqs = @(
    @{ Name = 'node';   Label = 'Node.js' },
    @{ Name = 'git';    Label = 'Git' },
    @{ Name = 'wt';     Label = 'Windows Terminal' }
)

$missing = @()
foreach ($p in $requiredPrereqs) {
    if (Test-Command $p.Name) {
        Write-Ok "$($p.Label) found"
    } else {
        Write-Err "$($p.Label) NOT found ($($p.Name))"
        $missing += $p.Label
    }
}

if ($missing.Count -gt 0) {
    throw "Missing prerequisites: $($missing -join ', '). Please install them before continuing."
}

$claudeInstalled = Test-Command 'claude'
$copilotInstalled = Test-Command 'copilot'

if ($claudeInstalled) {
    Write-Ok 'Claude CLI found'
} else {
    Write-Warn 'Claude CLI not found'
}

if ($copilotInstalled) {
    Write-Ok 'GitHub Copilot CLI found'
} else {
    Write-Warn 'GitHub Copilot CLI not found'
}

if (-not ($claudeInstalled -or $copilotInstalled)) {
    throw 'Either Claude CLI or GitHub Copilot CLI must be installed to use Autotask.'
}

$defaultWorkerCli = if ($claudeInstalled -and $copilotInstalled) { 'auto' } elseif ($claudeInstalled) { 'claude' } else { 'copilot' }

# ---------------------------------------------------------------------------
# 2. Create workspace directories
# ---------------------------------------------------------------------------
Write-Status 'Creating workspace directories...'

foreach ($dir in @($workspaceDir, $artifactsCacheDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Ok "Created $dir"
    } else {
        Write-Ok "Exists  $dir"
    }
}

# ---------------------------------------------------------------------------
# 3. Copy config template
# ---------------------------------------------------------------------------
Write-Status 'Setting up local configuration...'

if ((Test-Path $localConfigFile) -and -not $Force) {
    Write-Ok 'config.local.yaml already exists (use -Force to overwrite)'
} else {
    Copy-Item -Path $templateFile -Destination $localConfigFile -Force
    Write-Ok 'Copied config.local.yaml.template -> config.local.yaml'
}

# ---------------------------------------------------------------------------
# 4. Prompt for local settings
# ---------------------------------------------------------------------------
Write-Status 'Configuring local settings...'

$content = Get-Content $localConfigFile -Raw

function Set-YamlValue {
    param([string]$Content, [string]$Key, [string]$Prompt, [string]$Default)
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    $pattern = '(?m)^(' + [regex]::Escape($Key) + ':\s*)"[^"]*"'
    $replacement = '${1}"' + $value + '"'
    $result = [regex]::Replace($Content, $pattern, $replacement)
    return $result
}

function Set-YamlValueOptional {
    param([string]$Content, [string]$Key, [string]$Prompt)
    $value = Read-Host "$Prompt (optional, press Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Content }
    $pattern = '(?m)^(' + [regex]::Escape($Key) + ':\s*)"[^"]*"'
    $replacement = '${1}"' + $value + '"'
    return [regex]::Replace($Content, $pattern, $replacement)
}

$content = Set-YamlValue $content 'worker_cli'  'Worker CLI (auto|claude|copilot)'    $defaultWorkerCli
$content = Set-YamlValueOptional $content 'smtp_from'  'SMTP from address'
$content = Set-YamlValueOptional $content 'smtp_to'    'SMTP to address'

Set-Content -Path $localConfigFile -Value $content -NoNewline
Write-Ok 'config.local.yaml updated'

# ---------------------------------------------------------------------------
# 5. Create command symlinks
# ---------------------------------------------------------------------------
Write-Status 'Creating command symlinks...'

if ($claudeInstalled) {
    if (-not (Test-Path $claudeCommandsDir)) {
        New-Item -ItemType Directory -Path $claudeCommandsDir -Force | Out-Null
    }

    $commandFiles = @(
        'autotask-start.md',
        'autotask-queue.md',
        'autotask-status.md',
        'autotask-wrapup.md'
    )

    foreach ($cmd in $commandFiles) {
        $source = Join-Path $commandsDir $cmd
        $target = Join-Path $claudeCommandsDir $cmd

        if (-not (Test-Path $source)) {
            Write-Warn "Source command not found: $source (skipping - create it later)"
            continue
        }

        if (Test-Path $target) {
            Remove-Item $target -Force
        }

        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $source -Force | Out-Null
            Write-Ok "Linked $cmd"
        } catch {
            Write-Warn "Could not create symlink for $cmd (run as admin?): $($_.Exception.Message)"
            try {
                Copy-Item -Path $source -Destination $target -Force
                Write-Ok "Copied $cmd (symlink failed, used copy)"
            } catch {
                Write-Err "Failed to link or copy $cmd"
            }
        }
    }
} else {
    Write-Warn 'Skipping Claude slash command setup because Claude CLI is not installed.'
}

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
$workerCliMatch = [regex]::Match($content, '(?m)^worker_cli:\s*"([^"]*)"')
$workerCli = if ($workerCliMatch.Success) { $workerCliMatch.Groups[1].Value } else { $defaultWorkerCli }

Write-Host ''
Write-Host '=========================================' -ForegroundColor Magenta
Write-Host '  Setup Summary'                          -ForegroundColor Magenta
Write-Host '=========================================' -ForegroundColor Magenta
Write-Host ''
Write-Ok "Orchestrator root : $orchestratorRoot"
Write-Ok "Local config      : $localConfigFile"
Write-Ok "Worker CLI        : $workerCli"
Write-Ok "Workspaces        : $workspaceDir"
Write-Ok "Artifacts cache   : $artifactsCacheDir"
if ($claudeInstalled) {
    Write-Ok "Claude commands   : $claudeCommandsDir"
}
if ($copilotInstalled) {
    Write-Ok "Copilot helper    : $copilotHelperPath"
}
Write-Host ''
Write-Ok 'Autotask installation complete.'
Write-Host 'Claude Code / Copilot CLI: run /autotask-start to begin.' -ForegroundColor Cyan
Write-Host ''
