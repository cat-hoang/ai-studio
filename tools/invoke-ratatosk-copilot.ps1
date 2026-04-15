[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('start', 'queue', 'status', 'wrapup')]
    [string]$Command,

    [string]$Arguments,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OrchestratorRoot {
    return [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-RatatoskPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$CommandPath,

        [Parameter(Mandatory)]
        [string]$LauncherPath,

        [string]$ArgumentsText
    )

    $argumentSection = if ([string]::IsNullOrWhiteSpace($ArgumentsText)) {
        'No extra arguments were supplied.'
    } else {
        "Additional user arguments:`n$ArgumentsText"
    }

    return @"
You are operating inside the Ratatosk orchestrator repository.

Read and execute the instructions in:
$CommandPath

Treat that file as the authoritative playbook for this Ratatosk command.
When worker tabs need to be spawned, respect worker_cli from config.local.yaml and use $LauncherPath instead of hard-coding a CLI executable.

$argumentSection
"@
}

function Main {
    $orchestratorRoot = Get-OrchestratorRoot
    $commandPath = Join-Path $orchestratorRoot ("commands\ratatosk-{0}.md" -f $Command)
    $launcherPath = Join-Path $orchestratorRoot 'tools\launch-ratatosk-worker.ps1'
    $pluginManifestPath = Join-Path $orchestratorRoot 'plugin.json'

    if (-not (Test-Path -LiteralPath $commandPath)) {
        throw "Ratatosk command playbook not found: $commandPath"
    }

    if (-not (Test-Path -LiteralPath $pluginManifestPath)) {
        throw "Copilot plugin manifest not found: $pluginManifestPath"
    }

    if ($null -eq (Get-Command -Name 'copilot' -ErrorAction SilentlyContinue)) {
        throw 'GitHub Copilot CLI is required but was not found on PATH.'
    }

    $prompt = Get-RatatoskPrompt -CommandPath $commandPath -LauncherPath $launcherPath -ArgumentsText $Arguments
    $argumentList = @(
        '-i', $prompt,
        '--plugin-dir', $orchestratorRoot,
        '--allow-all',
        '--no-ask-user',
        '--add-dir', $orchestratorRoot
    )

    if ($PSCmdlet.ShouldProcess($Command, 'Launch Ratatosk in Copilot CLI')) {
        Push-Location -LiteralPath $orchestratorRoot
        try {
            & copilot @argumentList
        } finally {
            Pop-Location
        }
    }

    if ($PassThru) {
        [PSCustomObject]@{
            Command = $Command
            CommandPath = $commandPath
            PluginDir = $orchestratorRoot
            PluginManifestPath = $pluginManifestPath
            ArgumentList = $argumentList
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
