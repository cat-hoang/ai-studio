#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobNumber,
    [Parameter(Mandatory)][string]$TaskSequence,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $PSCommandPath
$script = Join-Path $toolsDir 'ratatosk-task-notes.ts'

# Write content to a temp file to avoid PowerShell argument-splitting on newlines.
$tempFile = Join-Path $env:TEMP "ratatosk-notes-$([System.IO.Path]::GetRandomFileName()).txt"
try {
    [System.IO.File]::WriteAllText($tempFile, $Content, [System.Text.Encoding]::UTF8)
    $rawLines = @(& bun $script --action set --jobNumber $JobNumber --taskSequence $TaskSequence --content-file $tempFile 2>$null)
} finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}
# bun/GlowClient may emit pino structured-log JSON lines to stdout (e.g. {"level":30,"msg":...})
# in non-TTY subprocess contexts. The actual result always contains a "success" key.
$jsonLine = $rawLines | Where-Object { $_.TrimStart().StartsWith('{') -and $_ -match '"success"\s*:' } | Select-Object -First 1
if (-not $jsonLine) {
    Write-Output (ConvertTo-Json @{ success = $false; error = 'Notes script produced no JSON output.' } -Compress)
} else {
    Write-Output $jsonLine.Trim()
}
