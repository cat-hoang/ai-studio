#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobNumber,
    [Parameter(Mandatory)][string]$TaskSequence
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $PSCommandPath
$script = Join-Path $toolsDir 'ratatosk-task-notes.ts'

$rawLines = @(& bun $script --action get --jobNumber $JobNumber --taskSequence $TaskSequence 2>$null)
# bun/GlowClient may emit pino structured-log JSON lines to stdout (e.g. {"level":30,"msg":...})
# in non-TTY subprocess contexts. The actual result always contains a "success" key.
$jsonLine = $rawLines | Where-Object { $_.TrimStart().StartsWith('{') -and $_ -match '"success"\s*:' } | Select-Object -First 1
if (-not $jsonLine) {
    Write-Output (ConvertTo-Json @{ success = $false; error = 'Notes script produced no JSON output.' } -Compress)
} else {
    Write-Output $jsonLine.Trim()
}
