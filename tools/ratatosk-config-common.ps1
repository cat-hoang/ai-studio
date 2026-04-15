Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RatatoskConfigRootPath {
    if (Get-Command -Name Get-RatatoskRootPath -ErrorAction SilentlyContinue) {
        return Get-RatatoskRootPath
    }

    return (Split-Path -Parent $PSScriptRoot)
}

function Get-RatatoskConfigContent {
    param(
        [string[]]$Paths = @()
    )

    $ratatoskRoot = Get-RatatoskConfigRootPath
    $effectivePaths = if ($Paths.Count -gt 0) {
        @($Paths)
    } else {
        @(
            (Join-Path $ratatoskRoot 'config.yaml'),
            (Join-Path $ratatoskRoot 'config.local.yaml')
        )
    }

    $chunks = foreach ($path in $effectivePaths) {
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path -Raw -Encoding UTF8
        }
    }

    return ($chunks -join [Environment]::NewLine)
}

function Get-RatatoskConfigTextValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    $lines = $Content -split "`r?`n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        $line = $lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^(?<name>[^:]+):\s*(?<value>.*)$') {
            continue
        }

        if ($matches['name'].Trim() -ne $Key) {
            continue
        }

        $value = $matches['value'].Trim()
        if ($value.Contains('#')) {
            $value = $value.Split('#', 2)[0].Trim()
        }

        return $value.Trim("'`"")
    }

    return $Default
}

function Get-RatatoskConfigBooleanValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [bool]$Default = $false
    )

    $rawValue = Get-RatatoskConfigTextValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $Default
    }

    switch ($rawValue.Trim().ToLowerInvariant()) {
        'true' { return $true }
        'yes' { return $true }
        '1' { return $true }
        'false' { return $false }
        'no' { return $false }
        '0' { return $false }
        default { return $Default }
    }
}

function Get-RatatoskConfigNumberValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [int]$Default = 0
    )

    $rawValue = Get-RatatoskConfigTextValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse($rawValue.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Get-RatatoskConfigListValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $rawValue = Get-RatatoskConfigTextValue -Content $Content -Key $Key
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return @()
    }

    return @(
        $rawValue.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}
