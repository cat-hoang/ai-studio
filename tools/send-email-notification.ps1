param(
    [Parameter(Mandatory)]
    [string]$JsonPayload
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

$data = $JsonPayload | ConvertFrom-Json
$templateName = $data.templateName
$tplData = $data.data

# Read config
$ratatoskRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $ratatoskRoot 'config.local.yaml'
$configContent = Get-Content $configPath -Raw

function Get-YamlValue($content, $key) {
    if ($content -match "$key`:\s*`"?([^`"\r\n]+)`"?") {
        return $Matches[1].Trim().Trim('"').Trim("'")
    }
    throw "$key not found in config.local.yaml"
}

$smtpFrom = Get-YamlValue $configContent 'smtp_from'
$smtpTo   = Get-YamlValue $configContent 'smtp_to'
$statePath = Join-Path $ratatoskRoot 'temp\state.json'
$linkCommonPath = Join-Path $PSScriptRoot 'ratatosk-ediprod-link-common.ps1'

if ([string]::IsNullOrWhiteSpace($smtpFrom)) { throw 'smtp_from is empty' }
if ([string]::IsNullOrWhiteSpace($smtpTo))   { throw 'smtp_to is empty' }
if (-not (Test-Path -LiteralPath $linkCommonPath)) { throw "Shared ediProd link helper not found: $linkCommonPath" }
. $linkCommonPath

# --- OAuth2 token management via browser auth + Graph API ---
$tenantId = '8b493985-e1b4-4b95-ade6-98acafdbdb01'
$clientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c'  # Microsoft Office first-party app
$scope    = 'https://graph.microsoft.com/Mail.Send offline_access'
$tokenCachePath = Join-Path $ratatoskRoot '.oauth-token-cache.json'

function Get-GraphAccessToken {
    if (Test-Path $tokenCachePath) {
        $cache = Get-Content $tokenCachePath -Raw | ConvertFrom-Json
        $expiry = [DateTimeOffset]::FromUnixTimeSeconds($cache.expires_on)
        if ($expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
            return $cache.access_token
        }
        if ($cache.refresh_token) {
            try {
                $refreshBody = @{
                    client_id     = $clientId
                    grant_type    = 'refresh_token'
                    refresh_token = $cache.refresh_token
                    scope         = $scope
                }
                $resp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $refreshBody
                $tokenData = @{
                    access_token  = $resp.access_token
                    refresh_token = if ($resp.refresh_token) { $resp.refresh_token } else { $cache.refresh_token }
                    expires_on    = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeSeconds()
                }
                $tokenData | ConvertTo-Json | Set-Content $tokenCachePath -Encoding UTF8
                return $resp.access_token
            } catch {
                $null = $_
            }
        }
    }

    # Use device code flow — works with any tenant, no redirect URI issues
    $deviceCodeBody = @{
        client_id = $clientId
        scope     = $scope
    }
    $deviceResp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $deviceCodeBody

    Write-Information $deviceResp.message -InformationAction Continue
    Start-Process $deviceResp.verification_uri

    # Poll for token
    $interval = $deviceResp.interval
    $expiresIn = $deviceResp.expires_in
    $elapsed = 0
    $resp = $null
    while ($elapsed -lt $expiresIn) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        try {
            $tokenBody = @{
                client_id   = $clientId
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $deviceResp.device_code
            }
            $resp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
            break
        } catch {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errBody.error -eq 'authorization_pending') { continue }
            if ($errBody.error -eq 'slow_down') { $interval += 5; continue }
            throw "Auth failed: $($errBody.error_description)"
        }
    }
    if (-not $resp) { throw 'Device code authentication timed out' }

    $tokenData = @{
        access_token  = $resp.access_token
        refresh_token = $resp.refresh_token
        expires_on    = [DateTimeOffset]::UtcNow.AddSeconds($resp.expires_in).ToUnixTimeSeconds()
    }
    $tokenData | ConvertTo-Json | Set-Content $tokenCachePath -Encoding UTF8
    return $resp.access_token
}

# --- Build email subject + body ---
$subject = ''
$body = ''

switch ($templateName) {
    'task-summary' {
        $jobTitle = if ($tplData.PSObject.Properties['jobTitle']) { [string]$tplData.jobTitle } else { '' }
        $prHtml = '<li>(none)</li>'
        if ($tplData.prUrls -and @($tplData.prUrls).Count -gt 0) {
            $prHtml = ($tplData.prUrls | ForEach-Object { "<li><a href='$_'>$_</a></li>" }) -join ''
        }
        $summaryHtml = if ($tplData.summary) {
            '<h3>Final Summary</h3><p>' + [System.Net.WebUtility]::HtmlEncode($tplData.summary) + '</p>'
        } else {
            ''
        }
        $changesHtml = if ($tplData.changes -and @($tplData.changes).Count -gt 0) {
            '<h3>Changes</h3><ul>' + (($tplData.changes | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join '') + '</ul>'
        } else {
            ''
        }
        $testingHtml = if ($tplData.testing -and @($tplData.testing).Count -gt 0) {
            '<h3>Testing</h3><ul>' + (($tplData.testing | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join '') + '</ul>'
        } else {
            ''
        }
        $reportPathHtml = if ($tplData.reportPath) {
            '<p><strong>Saved report:</strong> <code>' + [System.Net.WebUtility]::HtmlEncode($tplData.reportPath) + '</code></p>'
        } else {
            ''
        }
        $subject = "Ratatosk: $($tplData.jobNumber) - $($tplData.status)"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;">' +
            "<h2>Task Summary: $($tplData.jobNumber)</h2>" +
            '<table style="border-collapse:collapse;width:100%;max-width:600px;">' +
            "<tr><td style='padding:6px;font-weight:bold;'>Job</td><td style='padding:6px;'>$(Get-EdiProdLinkHtml -JobNumber $tplData.jobNumber -JobGuid $tplData.jobGuid -StatePath $statePath)$(if (-not [string]::IsNullOrWhiteSpace($jobTitle)) { ' · ' + [System.Net.WebUtility]::HtmlEncode($jobTitle) })</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Type</td><td style='padding:6px;'>$($tplData.taskType)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Task Sequence</td><td style='padding:6px;'>$($tplData.taskSequence)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Description</td><td style='padding:6px;'>$($tplData.description)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Zone</td><td style='padding:6px;'>$($tplData.zone)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Status</td><td style='padding:6px;'>$($tplData.status)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Duration</td><td style='padding:6px;'>$($tplData.duration)</td></tr>" +
            "</table>$summaryHtml$changesHtml$testingHtml<h3>Pull Requests</h3><ul>$prHtml</ul>$reportPathHtml</body></html>"
    }
    'task-started' {
        $jobTitle = if ($tplData.PSObject.Properties['jobTitle']) { [string]$tplData.jobTitle } else { '' }
        $jobLabel = if (-not [string]::IsNullOrWhiteSpace($jobTitle)) { "$($tplData.jobNumber) · $([System.Net.WebUtility]::HtmlEncode($jobTitle))" } else { $tplData.jobNumber }
        $subject = "Ratatosk: $($tplData.jobNumber) - Started"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;">' +
            '<div style="background-color:#dff6dd;border-left:4px solid #107c10;padding:12px;margin-bottom:16px;">' +
            '<h2 style="color:#107c10;margin-top:0;">Task Started</h2></div>' +
            '<table style="border-collapse:collapse;width:100%;max-width:600px;">' +
            "<tr><td style='padding:6px;font-weight:bold;'>Job</td><td style='padding:6px;'>$(Get-EdiProdLinkHtml -JobNumber $tplData.jobNumber -JobGuid $tplData.jobGuid -StatePath $statePath) · $([System.Net.WebUtility]::HtmlEncode($jobTitle))</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Type</td><td style='padding:6px;'>$($tplData.taskType)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Task Sequence</td><td style='padding:6px;'>$($tplData.taskSequence)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Description</td><td style='padding:6px;'>$($tplData.description)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Zone</td><td style='padding:6px;'>$($tplData.zone)</td></tr>" +
            "</table></body></html>"
    }
    'daily-report' {
        $rowsHtml = ''
        if ($tplData.workers) {
            $tplData.workers | ForEach-Object {
                $rowsHtml += "<tr><td style='padding:6px;border:1px solid #ddd;'>$($_.name)</td>" +
                    "<td style='padding:6px;border:1px solid #ddd;'>$($_.zone)</td>" +
                    "<td style='padding:6px;border:1px solid #ddd;'>$($_.status)</td>" +
                    "<td style='padding:6px;border:1px solid #ddd;'>$($_.jobNumber)</td>" +
                    "<td style='padding:6px;border:1px solid #ddd;'>$($_.completedCount)</td>" +
                    "<td style='padding:6px;border:1px solid #ddd;'>$($_.failedCount)</td></tr>"
            }
        }
        $subject = "Ratatosk Daily Report - $($tplData.date)"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;">' +
            "<h2>Ratatosk Daily Report - $($tplData.date)</h2>" +
            "<p><strong>Completed:</strong> $($tplData.totalCompleted) | <strong>Failed:</strong> $($tplData.totalFailed) | <strong>Queued:</strong> $($tplData.totalQueued)</p>" +
            '<table style="border-collapse:collapse;width:100%;">' +
            '<thead><tr style="background-color:#0078d4;color:white;">' +
            '<th style="padding:8px;border:1px solid #ddd;">Worker</th>' +
            '<th style="padding:8px;border:1px solid #ddd;">Zone</th>' +
            '<th style="padding:8px;border:1px solid #ddd;">Status</th>' +
            '<th style="padding:8px;border:1px solid #ddd;">Current Job</th>' +
            '<th style="padding:8px;border:1px solid #ddd;">Completed</th>' +
            '<th style="padding:8px;border:1px solid #ddd;">Failed</th>' +
            "</tr></thead><tbody>$rowsHtml</tbody></table></body></html>"
    }
    'failed-alert' {
        $logText = if ($tplData.logs) { [System.Net.WebUtility]::HtmlEncode($tplData.logs) } else { '(no logs)' }
        $subject = "Ratatosk Task Failed: $($tplData.jobNumber)"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;">' +
            '<div style="background-color:#fde7e9;border-left:4px solid #d13438;padding:12px;margin-bottom:16px;">' +
            '<h2 style="color:#d13438;margin-top:0;">Task Failed</h2></div>' +
            '<table style="border-collapse:collapse;width:100%;max-width:600px;">' +
            "<tr><td style='padding:6px;font-weight:bold;'>Job Number</td><td style='padding:6px;'>$(Get-EdiProdLinkHtml -JobNumber $tplData.jobNumber -JobGuid $tplData.jobGuid -StatePath $statePath)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Task Sequence</td><td style='padding:6px;'>$($tplData.taskSequence)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Type</td><td style='padding:6px;'>$($tplData.taskType)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Zone</td><td style='padding:6px;'>$($tplData.zone)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Duration</td><td style='padding:6px;'>$($tplData.duration)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Timestamp</td><td style='padding:6px;'>$($tplData.timestamp)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Error</td><td style='padding:6px;color:#d13438;'>$($tplData.error)</td></tr>" +
            "</table><h3>Logs</h3><pre style='background-color:#f4f4f4;padding:12px;border-radius:4px;overflow-x:auto;font-size:12px;'>$logText</pre></body></html>"
    }
    'user-input-request' {
        $optionsHtml = '<li>(freeform response)</li>'
        if ($tplData.options -and @($tplData.options).Count -gt 0) {
            $optionsHtml = ($tplData.options | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join ''
        }
        $questionHtml = [System.Net.WebUtility]::HtmlEncode($tplData.question)
        $subject = "Ratatosk Input Needed: $($tplData.jobNumber) [$($tplData.requestId)]"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;">' +
            '<div style="background-color:#fff4ce;border-left:4px solid #ffb900;padding:12px;margin-bottom:16px;">' +
            '<h2 style="margin-top:0;">Ratatosk needs your input</h2></div>' +
            '<table style="border-collapse:collapse;width:100%;max-width:700px;">' +
            "<tr><td style='padding:6px;font-weight:bold;'>Job Number</td><td style='padding:6px;'>$(Get-EdiProdLinkHtml -JobNumber $tplData.jobNumber -JobGuid $tplData.jobGuid)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Task Sequence</td><td style='padding:6px;'>$($tplData.taskSequence)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Type</td><td style='padding:6px;'>$($tplData.taskType)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Zone</td><td style='padding:6px;'>$($tplData.zone)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Question Type</td><td style='padding:6px;'>$($tplData.questionType)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Severity</td><td style='padding:6px;'>$($tplData.severity)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Answer Mode</td><td style='padding:6px;'>$($tplData.answerMode)</td></tr>" +
            "<tr><td style='padding:6px;font-weight:bold;'>Request Id</td><td style='padding:6px;font-family:Consolas,monospace;'>$($tplData.requestId)</td></tr>" +
            "</table>" +
            "<h3>Question</h3><p>$questionHtml</p>" +
            "<h3>Suggested options</h3><ul>$optionsHtml</ul>" +
            '<h3>How to respond</h3>' +
            '<ol>' +
            '<li>Reply to this email and keep the subject unchanged, or</li>' +
            "<li>Use the Ratatosk dashboard command bar: <code>reply $($tplData.jobNumber) your answer</code></li>" +
            '</ol>' +
            '</body></html>'
    }
    'status-report' {
        $counts = $tplData.counts
        $startable = if ($tplData.startableJobs) { @($tplData.startableJobs) } else { @() }
        $workers = if ($tplData.workers) { @($tplData.workers) } else { @() }
        $completed = if ($tplData.completedJobs) { @($tplData.completedJobs) } else { @() }
        $failed = if ($tplData.failedJobs) { @($tplData.failedJobs) } else { @() }
        $waiting = if ($tplData.waitingQueue) { @($tplData.waitingQueue) } else { @() }

        function Local-Safe($v) { [System.Net.WebUtility]::HtmlEncode([string]$v) }
        function Local-Row($items, $showCmd) {
            if ($items.Count -eq 0) { return '<li style="color:#667085;">(none)</li>' }
            ($items | ForEach-Object {
                $jn = Local-Safe $_.jobNumber
                $tt = Local-Safe $_.taskType
                $sm = Local-Safe $_.summary
                $seq = [string]$_.taskSequence
                $seqBadge = if (-not [string]::IsNullOrWhiteSpace($seq)) { " <span style='padding:1px 6px;border-radius:999px;background:#f6f3ff;color:#53389e;font-size:11px;'>Task $seq</span>" } else { '' }
                $naBadge = if ([bool]$_.neverAutoStart) { " <span style='padding:1px 6px;border-radius:999px;background:#fdf4ff;color:#c026d3;font-size:11px;'>🚫 Never Auto</span>" } else { '' }
                $cmdHtml = if ($showCmd) {
                    $cmdText = Local-Safe "ratatosk: start $($_.jobNumber)$(if (-not [string]::IsNullOrWhiteSpace($seq)) { " --task $seq" })"
                    "<br><code style='background:#f8f9fa;padding:2px 5px;font-size:12px;'>$cmdText</code>"
                } else { '' }
                $actLabel = if ($_.activityStatus) { " <span style='color:#667085;'>($(Local-Safe $_.activityStatus))</span>" } else { '' }
                "<li style='margin-bottom:8px;'><strong>$jn</strong>$seqBadge$naBadge  <span style='color:#667085;'>$tt</span>  —  $sm$actLabel$cmdHtml</li>"
            }) -join ''
        }

        $neverAutoNote = if (@($startable | Where-Object { [bool]$_.neverAutoStart }).Count -gt 0) {
            "<p style='padding:8px 12px;border-left:4px solid #c026d3;background:#fdf4ff;margin:12px 0;'><strong>🚫 Never Auto:</strong> $(@($startable | Where-Object { [bool]$_.neverAutoStart }).Count) task(s) will not start automatically.</p>"
        } else { '' }

        $countLine = if ($counts) { "Startable: $($counts.startableJobs)  ·  Queue: $($counts.waitingQueue)  ·  Workers: $($counts.workers)  ·  Completed: $($counts.completedJobs)  ·  Failed: $($counts.failedJobs)" } else { '' }
        $subject = "Ratatosk Status: $countLine"
        $body = '<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#333;max-width:720px;">' +
            '<h2 style="margin-bottom:4px;">📊 Ratatosk Status</h2>' +
            "<p style='color:#667085;'>$(Local-Safe $countLine)</p>" +
            $neverAutoNote +
            "<h3 style='margin:20px 0 6px;'>⚡ Startable Tasks</h3><ul style='margin:0;padding:0;'>" + (Local-Row $startable $true) + '</ul>' +
            "<h3 style='margin:20px 0 6px;'>🔄 Active Workers</h3><ul style='margin:0;padding:0;'>" + (Local-Row $workers $false) + '</ul>' +
            "<h3 style='margin:20px 0 6px;'>📥 Waiting Queue</h3><ul style='margin:0;padding:0;'>" + (Local-Row $waiting $false) + '</ul>' +
            "<h3 style='margin:20px 0 6px;'>✅ Completed</h3><ul style='margin:0;padding:0;'>" + (Local-Row $completed $false) + '</ul>' +
            "<h3 style='margin:20px 0 6px;'>❌ Failed</h3><ul style='margin:0;padding:0;'>" + (Local-Row $failed $false) + '</ul>' +
            '</body></html>'
    }
    default {
        throw "Unknown template: $templateName"
    }
}

# --- Send via Microsoft Graph ---
$recipients = $smtpTo -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

try {
    $accessToken = Get-GraphAccessToken

    $toRecipients = @($recipients | ForEach-Object { @{ emailAddress = @{ address = $_ } } })

    $graphPayload = @{
        message = @{
            subject = $subject
            body = @{ contentType = 'HTML'; content = $body }
            toRecipients = $toRecipients
        }
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 10

    $sendSuccess = $false
    $sendError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $null = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Method POST -Headers @{ Authorization = "Bearer $accessToken" } -ContentType 'application/json; charset=utf-8' -Body $graphPayload -TimeoutSec 30
            $sendSuccess = $true
            break
        } catch {
            $sendError = $_.Exception.Message
            if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
        }
    }

    if ($sendSuccess) {
        [PSCustomObject]@{ success = $true; template = $templateName } | ConvertTo-Json
    } else {
        [PSCustomObject]@{ success = $false; template = $templateName; error = $sendError } | ConvertTo-Json
    }
} catch {
    [PSCustomObject]@{ success = $false; template = $templateName; error = $_.Exception.Message } | ConvertTo-Json
}
