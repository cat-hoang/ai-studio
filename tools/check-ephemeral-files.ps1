# Checks for ephemeral files outside the temp\ directory and exits non-zero if any are found.
# Use this script as a CI gate to ensure ephemeral files are not committed to the repo root.

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$tempPrefix = [IO.Path]::Combine($root, 'temp')
$patterns = @('.oauth-token-cache.json', 'device-code.log', 'claude_*', '*.log', '*.tmp')
$found = @()

# Gather all files excluding those in temp\
$allFiles = Get-ChildItem -Path $root -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.FullName.StartsWith($tempPrefix, [System.StringComparison]::InvariantCultureIgnoreCase)) }

foreach ($p in $patterns) {
    foreach ($f in $allFiles) {
        try {
            if ($f.Name -like $p) { $found += $f.FullName }
        } catch {
            # ignore
        }
    }
}

if ($found.Count -gt 0) {
    Write-Host "Ephemeral files found outside temp\\ (this should be fixed):" -ForegroundColor Red
    $found | ForEach-Object { Write-Host " - $_" }
    Write-Host "Failing CI check." -ForegroundColor Red
    exit 1
}

Write-Host "No ephemeral files found outside temp\\."
exit 0
