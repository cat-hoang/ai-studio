Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AutotaskRoot = Split-Path -Parent $PSScriptRoot
$script:AutotaskLocalConfigPath = Join-Path $script:AutotaskRoot 'config.local.yaml'
$script:AutotaskTokenCachePath = Join-Path $script:AutotaskRoot '.oauth-token-cache.json'
$script:AutotaskTenantId = '8b493985-e1b4-4b95-ade6-98acafdbdb01'
$script:AutotaskClientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c'

function Get-AutotaskConfigContent {
    if (-not (Test-Path -LiteralPath $script:AutotaskLocalConfigPath)) {
        throw "Config file not found: $script:AutotaskLocalConfigPath"
    }

    return Get-Content -LiteralPath $script:AutotaskLocalConfigPath -Raw
}

function Get-AutotaskConfigValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [switch]$AllowEmpty
    )

    $pattern = '(?m)^{0}:\s*"?([^"\r\n]*)"?' -f [regex]::Escape($Key)
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "$Key not found in config.local.yaml"
    }

    $value = $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) {
        throw "$Key is empty in config.local.yaml"
    }

    return $value
}

function ConvertTo-GraphScopeString {
    param(
        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    return ($Scopes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ' '
}

function Test-ScopesSatisfied {
    param(
        [string[]]$CachedScopes,
        [string[]]$RequiredScopes
    )

    if (-not $CachedScopes -or $CachedScopes.Count -eq 0) {
        return $false
    }

    $cached = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($scope in $CachedScopes) {
        if (-not [string]::IsNullOrWhiteSpace($scope)) {
            [void]$cached.Add($scope)
        }
    }

    foreach ($scope in $RequiredScopes) {
        if ([string]::IsNullOrWhiteSpace($scope)) {
            continue
        }

        if (-not $cached.Contains($scope)) {
            return $false
        }
    }

    return $true
}

function Save-GraphTokenCache {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken,

        [string]$RefreshToken,

        [Parameter(Mandatory)]
        [int64]$ExpiresOn,

        [Parameter(Mandatory)]
        [string[]]$Scopes
    )

    $tokenData = @{
        access_token = $AccessToken
        refresh_token = $RefreshToken
        expires_on = $ExpiresOn
        scopes = @($Scopes | Select-Object -Unique)
    }

    $tokenData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:AutotaskTokenCachePath -Encoding UTF8
}

function Get-CacheValue {
    param(
        [Parameter(Mandatory)]
        [psobject]$Cache,

        [Parameter(Mandatory)]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Cache) {
        return $Default
    }

    if (-not $Cache.PSObject.Properties[$Name]) {
        return $Default
    }

    return $Cache.$Name
}

function Get-GraphAccessToken {
    param(
        [string[]]$Scopes = @('https://graph.microsoft.com/Mail.Send', 'offline_access')
    )

    $scopeString = ConvertTo-GraphScopeString -Scopes $Scopes

    if (Test-Path -LiteralPath $script:AutotaskTokenCachePath) {
        $cache = Get-Content -LiteralPath $script:AutotaskTokenCachePath -Raw | ConvertFrom-Json
        $cacheScopes = @(Get-CacheValue -Cache $cache -Name 'scopes' -Default @())
        $expiresOn = Get-CacheValue -Cache $cache -Name 'expires_on' -Default 0
        $accessToken = [string](Get-CacheValue -Cache $cache -Name 'access_token' -Default '')
        $refreshToken = [string](Get-CacheValue -Cache $cache -Name 'refresh_token' -Default '')
        $expiry = if ($expiresOn) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$expiresOn) } else { [DateTimeOffset]::MinValue }

        if ((Test-ScopesSatisfied -CachedScopes $cacheScopes -RequiredScopes $Scopes) -and $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
            return $accessToken
        }

        if ($refreshToken) {
            try {
                $refreshBody = @{
                    client_id = $script:AutotaskClientId
                    grant_type = 'refresh_token'
                    refresh_token = $refreshToken
                    scope = $scopeString
                }

                $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$script:AutotaskTenantId/oauth2/v2.0/token" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $refreshBody
                $resolvedRefreshToken = if ($response.PSObject.Properties['refresh_token'] -and $response.refresh_token) { $response.refresh_token } else { $refreshToken }
                Save-GraphTokenCache -AccessToken $response.access_token -RefreshToken $resolvedRefreshToken -ExpiresOn ([DateTimeOffset]::UtcNow.AddSeconds($response.expires_in).ToUnixTimeSeconds()) -Scopes $Scopes
                return $response.access_token
            } catch {
                Write-Warning "Graph token refresh failed, falling back to device code authentication: $($_.Exception.Message)"
            }
        }
    }

    Write-Host 'Requesting device code for Microsoft login...'
    $deviceCodeBody = @{
        client_id = $script:AutotaskClientId
        scope = $scopeString
    }

    $deviceResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$script:AutotaskTenantId/oauth2/v2.0/devicecode" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $deviceCodeBody
    $deviceCodeMessage = $deviceResponse.message
    Write-Host $deviceCodeMessage
    $logPath = Join-Path $script:AutotaskRoot 'device-code.log'
    "$(Get-Date -Format 'o') [device-code] $deviceCodeMessage" | Set-Content -LiteralPath $logPath -Encoding UTF8
    Start-Process $deviceResponse.verification_uri

    $interval = [int]$deviceResponse.interval
    $expiresIn = [int]$deviceResponse.expires_in
    $elapsed = 0
    $tokenResponse = $null

    while ($elapsed -lt $expiresIn) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval

        try {
            $tokenBody = @{
                client_id = $script:AutotaskClientId
                grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $deviceResponse.device_code
            }

            $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$script:AutotaskTenantId/oauth2/v2.0/token" -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
            break
        } catch {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errBody.error -eq 'authorization_pending') { continue }
            if ($errBody.error -eq 'slow_down') { $interval += 5; continue }
            throw "Graph authentication failed: $($errBody.error_description)"
        }
    }

    if (-not $tokenResponse) {
        throw 'Device code authentication timed out'
    }

    Save-GraphTokenCache -AccessToken $tokenResponse.access_token -RefreshToken $tokenResponse.refresh_token -ExpiresOn ([DateTimeOffset]::UtcNow.AddSeconds($tokenResponse.expires_in).ToUnixTimeSeconds()) -Scopes $Scopes
    Write-Host 'Authentication successful - token cached'
    return $tokenResponse.access_token
}

function ConvertFrom-HtmlToPlainText {
    param(
        [string]$Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    Add-Type -AssemblyName System.Web
    $text = [regex]::Replace($Html, '<br\s*/?>', "`n", 'IgnoreCase')
    $text = [regex]::Replace($text, '</p\s*>', "`n`n", 'IgnoreCase')
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [System.Web.HttpUtility]::HtmlDecode($text)
    $text = $text -replace "`r", ''
    $text = [regex]::Replace($text, "[ \t]+", ' ')
    $text = [regex]::Replace($text, "`n{3,}", "`n`n")
    return $text.Trim()
}

function Send-GraphMail {
    param(
        [Parameter(Mandatory)]
        [string[]]$ToRecipients,

        [Parameter(Mandatory)]
        [string]$Subject,

        [Parameter(Mandatory)]
        [string]$HtmlBody,

        [bool]$SaveToSentItems = $true
    )

    $recipients = @($ToRecipients | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($recipients.Count -eq 0) {
        throw 'At least one recipient is required.'
    }

    $accessToken = Get-GraphAccessToken -Scopes @('https://graph.microsoft.com/Mail.Send', 'offline_access')
    $graphPayload = @{
        message = @{
            subject = $Subject
            body = @{
                contentType = 'HTML'
                content = $HtmlBody
            }
            toRecipients = @($recipients | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $SaveToSentItems
    } | ConvertTo-Json -Depth 10

    $null = Invoke-RestMethod `
        -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' `
        -Method POST `
        -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body $graphPayload
}
