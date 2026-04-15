[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

function Get-FirstNonEmptyValue {
    param([string[]]$Values)
    foreach ($v in $Values) { if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() } }
    return ''
}

# Returns a PSCustomObject with summary, description, jobGuid, and zone
# by querying the edi CLI. Best-effort: returns empty strings on failure.

$result = [PSCustomObject]@{
    summary     = ''
    description = ''
    jobGuid     = ''
    zone        = 0
}

$ediCmd = Get-Command 'edi' -ErrorAction SilentlyContinue
if ($null -eq $ediCmd) {
    $result | ConvertTo-Json -Compress
    return
}

try {
    # Fetch job title
    $wiJson = & edi workitem get $JobNumber --format json 2>$null | Out-String
    if (-not [string]::IsNullOrWhiteSpace($wiJson)) {
        $wi = $wiJson | ConvertFrom-Json -ErrorAction Stop
        $result.summary = Get-FirstNonEmptyValue -Values @(
            [string](Get-ObjectPropertyValue -Object $wi -Name 'title' -Default ''),
            [string](Get-ObjectPropertyValue -Object $wi -Name 'summary' -Default ''),
            [string](Get-ObjectPropertyValue -Object $wi -Name 'name' -Default '')
        )

        # Extract GUID from attached documents
        foreach ($doc in @($wi.attachedDocuments)) {
            $m = [regex]::Match([string]$doc.url, 'ediprod:///I(?:WorkItem|SupportIncident|Project)/([0-9a-fA-F\-]{36})/')
            if ($m.Success) { $result.jobGuid = $m.Groups[1].Value; break }
        }
    }

    # Fetch task description and zone when taskSequence is known
    if (-not [string]::IsNullOrWhiteSpace($TaskSequence)) {
        $tasksJson = & edi --format jsonl task list $JobNumber 2>$null | Out-String
        $seqNum = [int]$TaskSequence
        foreach ($line in ($tasksJson -split "`r?`n")) {
            if ($line -notmatch '^\s*\{') { continue }
            try {
                $t = $line | ConvertFrom-Json -ErrorAction Stop
                $s = Get-FirstNonEmptyValue -Values @(
                    [string](Get-ObjectPropertyValue -Object $t -Name 'sequence' -Default ''),
                    [string](Get-ObjectPropertyValue -Object $t -Name 'taskSequence' -Default ''),
                    [string](Get-ObjectPropertyValue -Object $t -Name 'seq' -Default '')
                )
                if (-not [string]::IsNullOrWhiteSpace($s) -and [int]$s -eq $seqNum) {
                    $typeObj = Get-ObjectPropertyValue -Object $t -Name 'type' -Default $null
                    $typeDesc = if ($null -ne $typeObj -and $typeObj -is [PSCustomObject]) {
                        [string](Get-ObjectPropertyValue -Object $typeObj -Name 'description' -Default '')
                    } elseif ($null -ne $typeObj) {
                        [string]$typeObj
                    } else { '' }
                    $result.description = Get-FirstNonEmptyValue -Values @(
                        [string](Get-ObjectPropertyValue -Object $t -Name 'description' -Default ''),
                        $typeDesc
                    )
                    $zText = [string](Get-ObjectPropertyValue -Object $t -Name 'zone' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($zText)) {
                        try { $result.zone = [int]$zText } catch { }
                    }
                    break
                }
            } catch { }
        }
    }
} catch { }

$result | ConvertTo-Json -Compress
