function Get-StateJobGuid {
    param(
        [string]$JobNumber,
        [string]$StatePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($JobNumber)) {
        return ''
    }

    # 1. Check state.json first
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath)) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($state.workers) + @($state.completedJobs) + @($state.failedJobs) + @($state.waitingQueue)
            $match = @($items | Where-Object { $_.jobNumber -eq $JobNumber -and -not [string]::IsNullOrWhiteSpace([string]$_.jobGuid) }) | Select-Object -First 1
            if ($match) {
                return [string]$match.jobGuid
            }
        } catch { }
    }

    # 2. Fallback: extract GUID from attached document URLs via edi CLI.
    # edi workitem get returns attachedDocuments with URLs like:
    #   ediprod:///IWorkItem/{WI_GUID}/{doc_GUID}.ext
    # Parse the WI GUID from the first matching URL.
    try {
        $ediCmd = Get-Command 'edi' -ErrorAction SilentlyContinue
        if ($null -ne $ediCmd) {
            $wiJson = & edi workitem get $JobNumber --format json 2>$null | Out-String
            if (-not [string]::IsNullOrWhiteSpace($wiJson)) {
                $wiObj = $wiJson | ConvertFrom-Json -ErrorAction Stop
                $docs = @($wiObj.attachedDocuments)
                foreach ($doc in $docs) {
                    $docUrl = [string]$doc.url
                    $m = [regex]::Match($docUrl, 'ediprod:///I(?:WorkItem|SupportIncident|Project)/([0-9a-fA-F\-]{36})/')
                    if ($m.Success) {
                        return $m.Groups[1].Value
                    }
                }
            }
        }
    } catch { }

    return ''
}

function Get-EdiProdWebLink {
    param(
        [string]$JobNumber,
        [string]$JobGuid = '',
        [string]$StatePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($JobNumber)) {
        return ''
    }

    $match = [regex]::Match($JobNumber.Trim(), '^(WI|CS|PRJ)(\d{8})$', 'IgnoreCase')
    if (-not $match.Success) {
        return ''
    }

    $type = $match.Groups[1].Value.ToUpperInvariant()
    $resolvedJobNumber = $type + $match.Groups[2].Value
    $resolvedGuid = if (-not [string]::IsNullOrWhiteSpace($JobGuid)) { $JobGuid.Trim() } else { Get-StateJobGuid -JobNumber $resolvedJobNumber -StatePath $StatePath }
    $controller = switch ($type) {
        'WI' { 'WorkItem' }
        'CS' { 'SupportIncident' }
        'PRJ' { 'Project' }
        default { '' }
    }

    if ([string]::IsNullOrWhiteSpace($controller)) {
        return ''
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedGuid)) {
        return "https://ediprod.cw.wisetechglobal.com/link/ShowEditForm/$controller/${resolvedGuid}?lang=en-gb"
    }

    # Fallback: provide a search URL for the job number when GUID is unavailable
    $encodedJob = [uri]::EscapeDataString($resolvedJobNumber)
    return "https://ediprod.cw.wisetechglobal.com/Query/Find?search=$encodedJob"
}

function Get-EdiProdLinkHtml {
    param(
        [string]$JobNumber,
        [string]$JobGuid = '',
        [string]$StatePath = ''
    )

    $safeJobNumber = [System.Net.WebUtility]::HtmlEncode($JobNumber)
    $webLink = Get-EdiProdWebLink -JobNumber $JobNumber -JobGuid $JobGuid -StatePath $StatePath
    if ([string]::IsNullOrWhiteSpace($webLink)) {
        return $safeJobNumber
    }

    return "<a href='$webLink'>$safeJobNumber</a>"
}

function Get-EdiProdMarkdownLink {
    param(
        [string]$JobNumber,
        [string]$JobGuid = '',
        [string]$StatePath = ''
    )

    $webLink = Get-EdiProdWebLink -JobNumber $JobNumber -JobGuid $JobGuid -StatePath $StatePath
    if ([string]::IsNullOrWhiteSpace($webLink)) {
        return "$JobNumber"
    }

    return "[$JobNumber]($webLink)"
}
