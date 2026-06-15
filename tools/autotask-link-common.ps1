function Get-StateJobUrl {
    param(
        [string]$JobNumber,
        [string]$StatePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($JobNumber)) {
        return ''
    }

    # The issue's web URL (GitHub issue html_url) is recorded on each job in
    # state.json as `jobUrl`. Look it up across all buckets.
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath)) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($state.workers) + @($state.completedJobs) + @($state.failedJobs) + @($state.waitingQueue)
            $match = @($items | Where-Object { $_.jobNumber -eq $JobNumber -and -not [string]::IsNullOrWhiteSpace([string]$_.jobUrl) }) | Select-Object -First 1
            if ($match) {
                return [string]$match.jobUrl
            }
        } catch { }
    }

    return ''
}

function Get-IssueWebLink {
    param(
        [string]$JobNumber,
        [string]$JobUrl = '',
        [string]$StatePath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($JobUrl)) {
        return $JobUrl.Trim()
    }
    return Get-StateJobUrl -JobNumber $JobNumber -StatePath $StatePath
}

function Get-IssueLinkHtml {
    param(
        [string]$JobNumber,
        [string]$JobUrl = '',
        [string]$StatePath = ''
    )

    $safeJobNumber = [System.Net.WebUtility]::HtmlEncode($JobNumber)
    $webLink = Get-IssueWebLink -JobNumber $JobNumber -JobUrl $JobUrl -StatePath $StatePath
    if ([string]::IsNullOrWhiteSpace($webLink)) {
        return $safeJobNumber
    }

    return "<a href='$webLink'>$safeJobNumber</a>"
}

function Get-IssueMarkdownLink {
    param(
        [string]$JobNumber,
        [string]$JobUrl = '',
        [string]$StatePath = ''
    )

    $webLink = Get-IssueWebLink -JobNumber $JobNumber -JobUrl $JobUrl -StatePath $StatePath
    if ([string]::IsNullOrWhiteSpace($webLink)) {
        return "$JobNumber"
    }

    return "[$JobNumber]($webLink)"
}
