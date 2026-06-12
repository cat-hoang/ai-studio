Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')
. (Join-Path $PSScriptRoot 'autotask-config-common.ps1')

$script:AutotaskTeamsChatHelperPath = Join-Path (Get-AutotaskRootPath) 'tools\invoke-teams-chat.js'
$script:AutotaskTeamsNotificationPrefix = '[Autotask]'
$script:DefaultTeamsChatPollIntervalMs = 30000

function Get-AutotaskTeamsNotificationPrefix {
    return $script:AutotaskTeamsNotificationPrefix
}

function Test-AutotaskTeamsChatTargetConfigured {
    param(
        [Parameter(Mandatory)]
        [psobject]$Settings
    )

    switch ($Settings.targetMode.ToLowerInvariant()) {
        'self' { return $true }
        'person' { return -not [string]::IsNullOrWhiteSpace($Settings.target) }
        'chat' { return -not [string]::IsNullOrWhiteSpace($Settings.target) }
        'conversation-id' { return -not [string]::IsNullOrWhiteSpace($Settings.target) }
        default { return $false }
    }
}

function Get-AutotaskTeamsChatSettings {
    $configContent = Get-AutotaskConfigContent
    $targetMode = Get-AutotaskConfigTextValue -Content $configContent -Key 'teams_chat_target_mode' -Default 'self'
    if ([string]::IsNullOrWhiteSpace($targetMode)) {
        $targetMode = 'self'
    }

    $commandPrefix = Get-AutotaskConfigTextValue -Content $configContent -Key 'teams_chat_command_prefix' -Default 'autotask:'
    if ([string]::IsNullOrWhiteSpace($commandPrefix)) {
        $commandPrefix = 'autotask:'
    }

    $settings = [PSCustomObject]@{
        enabled = Get-AutotaskConfigBooleanValue -Content $configContent -Key 'teams_chat_enabled' -Default $false
        email = Get-AutotaskConfigTextValue -Content $configContent -Key 'teams_chat_email'
        targetMode = $targetMode.Trim().ToLowerInvariant()
        target = Get-AutotaskConfigTextValue -Content $configContent -Key 'teams_chat_target'
        commandPollingEnabled = Get-AutotaskConfigBooleanValue -Content $configContent -Key 'teams_chat_command_polling_enabled' -Default $false
        commandSendReplies = Get-AutotaskConfigBooleanValue -Content $configContent -Key 'teams_chat_command_send_replies' -Default $true
        commandPrefix = $commandPrefix
        pollingIntervalMs = Get-AutotaskConfigNumberValue -Content $configContent -Key 'teams_chat_polling_interval_ms' -Default $script:DefaultTeamsChatPollIntervalMs
        helperPath = $script:AutotaskTeamsChatHelperPath
    }

    $settings | Add-Member -MemberType NoteProperty -Name 'targetConfigured' -Value (Test-AutotaskTeamsChatTargetConfigured -Settings $settings)
    return $settings
}

function Get-AutotaskTeamsChatDisabledReason {
    param(
        [Parameter(Mandatory)]
        [psobject]$Settings,

        [switch]$ForCommandPolling
    )

    if (-not $Settings.enabled) {
        return 'teams_chat_enabled is false'
    }

    if ($Settings.targetMode -notin @('self', 'person', 'chat', 'conversation-id')) {
        return "Unsupported teams_chat_target_mode '$($Settings.targetMode)'"
    }

    if (-not $Settings.targetConfigured) {
        return "teams_chat_target is required when teams_chat_target_mode is '$($Settings.targetMode)'"
    }

    if (-not (Test-Path -LiteralPath $Settings.helperPath)) {
        return 'Teams chat helper script not found'
    }

    if (-not (Get-Command -Name 'node' -ErrorAction SilentlyContinue)) {
        return 'node is not available on PATH'
    }

    if ($ForCommandPolling -and -not $Settings.commandPollingEnabled) {
        return 'teams_chat_command_polling_enabled is false'
    }

    return ''
}

function Get-AutotaskTeamsChatState {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    if (-not $State.PSObject.Properties['teamsChat'] -or $null -eq $State.teamsChat) {
        Set-AutotaskProperty -Object $State -Name 'teamsChat' -Value ([PSCustomObject]@{})
    }

    if (-not $State.teamsChat.PSObject.Properties['conversation'] -or $null -eq $State.teamsChat.conversation) {
        Set-AutotaskProperty -Object $State.teamsChat -Name 'conversation' -Value ([PSCustomObject]@{
            targetMode = ''
            target = ''
            conversationId = ''
            targetDescription = ''
            resolvedAt = ''
        })
    }

    if (-not $State.teamsChat.PSObject.Properties['cursor'] -or $null -eq $State.teamsChat.cursor) {
        Set-AutotaskProperty -Object $State.teamsChat -Name 'cursor' -Value ([PSCustomObject]@{
            conversationId = ''
            lastProcessedMessageId = ''
            lastProcessedArrivalTime = ''
            updatedAt = ''
        })
    }

    if (-not $State.teamsChat.PSObject.Properties['lastPollAt']) {
        Set-AutotaskProperty -Object $State.teamsChat -Name 'lastPollAt' -Value ''
    }

    return $State.teamsChat
}

function Get-AutotaskTeamsChatConversationCache {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$Settings
    )

    $teamsChatState = Get-AutotaskTeamsChatState -State $State
    $conversationState = $teamsChatState.conversation
    if (
        [string]::Equals([string]$conversationState.targetMode, [string]$Settings.targetMode, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$conversationState.target, [string]$Settings.target, [System.StringComparison]::Ordinal) -and
        -not [string]::IsNullOrWhiteSpace([string]$conversationState.conversationId)
    ) {
        return $conversationState
    }

    return $null
}

function Set-AutotaskTeamsChatConversationCache {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [psobject]$Settings,

        [Parameter(Mandatory)]
        [string]$ConversationId,

        [string]$TargetDescription = ''
    )

    $teamsChatState = Get-AutotaskTeamsChatState -State $State
    $conversationState = $teamsChatState.conversation
    $conversationState.targetMode = [string]$Settings.targetMode
    $conversationState.target = [string]$Settings.target
    $conversationState.conversationId = [string]$ConversationId
    $conversationState.targetDescription = [string]$TargetDescription
    $conversationState.resolvedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function Get-AutotaskTeamsChatCursor {
    param(
        [Parameter(Mandatory)]
        [psobject]$State
    )

    return (Get-AutotaskTeamsChatState -State $State).cursor
}

function Set-AutotaskTeamsChatCursor {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [string]$ConversationId = '',
        [string]$LastProcessedMessageId = '',
        [string]$LastProcessedArrivalTime = ''
    )

    $cursor = Get-AutotaskTeamsChatCursor -State $State
    $cursor.conversationId = [string]$ConversationId
    $cursor.lastProcessedMessageId = [string]$LastProcessedMessageId
    $cursor.lastProcessedArrivalTime = [string]$LastProcessedArrivalTime
    $cursor.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function Invoke-AutotaskTeamsChat {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('resolve-target', 'send-message', 'send-file', 'get-messages')]
        [string]$Action,

        [Parameter(Mandatory)]
        [psobject]$Settings,

        [string]$ConversationId = '',
        [string]$Content = '',
        [string]$Format = 'markdown',
        [string]$Subject = '',
        [string]$FilePath = '',
        [string]$Caption = '',
        [int]$Limit = 50
    )

    $disabledReason = Get-AutotaskTeamsChatDisabledReason -Settings $Settings
    if (-not [string]::IsNullOrWhiteSpace($disabledReason)) {
        throw $disabledReason
    }

    $arguments = @(
        $Settings.helperPath,
        '--action', $Action,
        '--target-mode', [string]$Settings.targetMode
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.email)) {
        $arguments += @('--email', [string]$Settings.email)
    }

    if (-not [string]::IsNullOrWhiteSpace($ConversationId)) {
        $arguments += @('--conversation-id', [string]$ConversationId)
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Settings.target)) {
        $arguments += @('--target', [string]$Settings.target)
    }

    if ($Action -eq 'send-message') {
        $arguments += @('--content', [string]$Content)
        if (-not [string]::IsNullOrWhiteSpace($Format)) {
            $arguments += @('--format', [string]$Format)
        }
        if (-not [string]::IsNullOrWhiteSpace($Subject)) {
            $arguments += @('--subject', [string]$Subject)
        }
    }

    if ($Action -eq 'send-file') {
        if ([string]::IsNullOrWhiteSpace($FilePath)) {
            throw '--FilePath is required for send-file action'
        }
        $arguments += @('--file', [string]$FilePath)
        if (-not [string]::IsNullOrWhiteSpace($Caption)) {
            $arguments += @('--caption', [string]$Caption)
        }
        if (-not [string]::IsNullOrWhiteSpace($Subject)) {
            $arguments += @('--subject', [string]$Subject)
        }
    }

    if ($Action -eq 'get-messages' -and $Limit -gt 0) {
        $arguments += @('--limit', [string]$Limit)
    }

    $output = & node @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    if ([string]::IsNullOrWhiteSpace($output)) {
        if ($exitCode -eq 0) {
            throw 'Teams chat helper returned no output.'
        }

        throw "Teams chat helper failed with exit code $exitCode and no output."
    }

    try {
        $result = $output | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Teams chat helper returned invalid JSON: $output"
    }

    if ($exitCode -ne 0 -or -not $result.success) {
        $errorMessage = if ($result -and $result.error) { [string]$result.error } else { "Teams chat helper failed with exit code $exitCode." }
        throw $errorMessage
    }

    return $result
}
