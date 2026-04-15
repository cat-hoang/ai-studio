[CmdletBinding()]
param(
    [int]$Top = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')
. (Join-Path $PSScriptRoot 'teams-chat-common.ps1')

function ConvertTo-TeamsPollResult {
    param(
        [bool]$Success = $true,
        [bool]$Disabled = $false,
        [string]$DisabledReason = '',
        [string]$ConversationId = '',
        [string]$TargetDescription = '',
        [string]$CurrentUserDisplayName = '',
        [AllowEmptyCollection()]
        [object[]]$CommandsProcessed = @(),
        [AllowEmptyCollection()]
        [object[]]$RejectedCommands = @(),
        [AllowEmptyCollection()]
        [string[]]$Warnings = @(),
        [AllowEmptyCollection()]
        [object[]]$MessagesSeen = @()
    )

    [PSCustomObject]@{
        success = $Success
        disabled = $Disabled
        disabledReason = $DisabledReason
        conversationId = $ConversationId
        targetDescription = $TargetDescription
        currentUserDisplayName = $CurrentUserDisplayName
        commandsProcessed = @($CommandsProcessed)
        rejectedCommands = @($RejectedCommands)
        warnings = @($Warnings)
        seenMessageCount = @($MessagesSeen).Count
        polledAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-MessageFieldValue {
    param(
        [object]$Message,
        [Parameter(Mandatory)]
        [string]$Name,
        $Default = ''
    )

    if ($null -eq $Message) {
        return $Default
    }

    if ($Message.PSObject.Properties[$Name]) {
        return $Message.$Name
    }

    return $Default
}

function ConvertTo-TeamsMessageTimestamp {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse($Value).UtcDateTime
    } catch {
        return $null
    }
}

function Get-NewTeamsMessages {
    param(
        [AllowEmptyCollection()]
        [object[]]$Messages = @(),

        [string]$LastProcessedMessageId = '',
        [string]$LastProcessedArrivalTime = ''
    )

    $orderedMessages = @($Messages)
    if ($orderedMessages.Count -eq 0) {
        return @()
    }

    if (-not [string]::IsNullOrWhiteSpace($LastProcessedMessageId)) {
        for ($index = $orderedMessages.Count - 1; $index -ge 0; $index--) {
            $candidateId = [string](Get-MessageFieldValue -Message $orderedMessages[$index] -Name 'id')
            $candidateArrivalTime = [string](Get-MessageFieldValue -Message $orderedMessages[$index] -Name 'originalArrivalTime')
            if ($candidateId -eq $LastProcessedMessageId -and $candidateArrivalTime -eq $LastProcessedArrivalTime) {
                if ($index -ge ($orderedMessages.Count - 1)) {
                    return @()
                }

                return @($orderedMessages[($index + 1)..($orderedMessages.Count - 1)])
            }
        }
    }

    $cursorTime = ConvertTo-TeamsMessageTimestamp -Value $LastProcessedArrivalTime
    if ($null -eq $cursorTime) {
        return $orderedMessages
    }

    return @(
        $orderedMessages | Where-Object {
            $messageTime = ConvertTo-TeamsMessageTimestamp -Value ([string](Get-MessageFieldValue -Message $_ -Name 'originalArrivalTime'))
            $null -ne $messageTime -and $messageTime -gt $cursorTime
        }
    )
}

function Get-CommandTextFromTeamsMessage {
    param(
        [string]$Text,
        [string]$Prefix
    )

    $trimmedText = [string]$Text
    if ([string]::IsNullOrWhiteSpace($trimmedText)) {
        return ''
    }

    $trimmedText = $trimmedText.Trim()
    $normalizedPrefix = if ([string]::IsNullOrWhiteSpace($Prefix)) { 'ratatosk:' } else { $Prefix.Trim() }
    if (-not $trimmedText.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ''
    }

    return $trimmedText.Substring($normalizedPrefix.Length).TrimStart()
}

function Send-TeamsCommandReply {
    param(
        [Parameter(Mandatory)]
        [psobject]$Settings,

        [Parameter(Mandatory)]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Warnings
    )

    try {
        Invoke-RatatoskTeamsChat -Action 'send-message'-Settings $Settings -ConversationId $ConversationId -Content $Text -Format 'markdown' | Out-Null
    } catch {
        $Warnings.Add("Failed to send Teams command reply: $($_.Exception.Message)")
    }
}

function Invoke-TeamsCommand {
    param(
        [Parameter(Mandatory)]
        [psobject]$Settings,

        [Parameter(Mandatory)]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [psobject]$Message,

        [Parameter(Mandatory)]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Warnings
    )

    $sourceMessageId= [string](Get-MessageFieldValue -Message $Message -Name 'id')
    $commandMessageId = "teams:${ConversationId}:${sourceMessageId}"
    $senderDisplayName = [string](Get-MessageFieldValue -Message $Message -Name 'senderDisplayName')
    $commandScriptPath = Join-Path $PSScriptRoot 'invoke-ratatosk-command.ps1'
    $commandOutput = & $commandScriptPath -CommandText $CommandText -Source 'teams-command-poller' -Responder $senderDisplayName -MessageId $commandMessageId 2>&1 | Out-String

    try {
        $commandResult = $commandOutput | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $commandResult = [PSCustomObject]@{
            success = $false
            duplicate = $false
            action = ''
            jobNumber = ''
            message = 'Ratatosk command failed.'
            error = "Command handler returned invalid JSON: $commandOutput"
        }
    }

    if ($Settings.commandSendReplies -and -not [bool]$commandResult.duplicate) {
        if ($commandResult.success) {
            $replyText = ('{0} Command ok: `{1}`' -f (Get-RatatoskTeamsNotificationPrefix), $CommandText)
            # For status commands, use the rich per-item markdown report when available
            $statusReport = ''
            if ([string]$commandResult.action -eq 'status') {
                $resultData = Get-MessageFieldValue -Message $commandResult -Name 'data'
                if ($null -ne $resultData) {
                    $statusReport = [string](Get-MessageFieldValue -Message $resultData -Name 'statusReport')
                }
            }
            # For notes commands, append the notes content as a code block
            $notesBlock = ''
            if ([string]$commandResult.action -eq 'notes') {
                $resultData = Get-MessageFieldValue -Message $commandResult -Name 'data'
                if ($null -ne $resultData) {
                    $notesText = [string](Get-MessageFieldValue -Message $resultData -Name 'notes')
                    if (-not [string]::IsNullOrWhiteSpace($notesText)) {
                        $notesBlock = "`n``````````text`n$notesText`n``````````"
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($statusReport)) {
                $replyText += ("`n" + $statusReport)
            } elseif (-not [string]::IsNullOrWhiteSpace($notesBlock)) {
                $replyText += ("`n" + [string]$commandResult.message + $notesBlock)
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$commandResult.message)) {
                $replyText += ("`n" + [string]$commandResult.message)
            }
            Send-TeamsCommandReply -Settings $Settings -ConversationId $ConversationId -Text $replyText -Warnings $Warnings
        } else {
            $replyText = ('{0} Command failed: `{1}`' -f (Get-RatatoskTeamsNotificationPrefix), $CommandText)
            if (-not [string]::IsNullOrWhiteSpace([string]$commandResult.error)) {
                $replyText += ("`n" + [string]$commandResult.error)
            }
            Send-TeamsCommandReply -Settings $Settings -ConversationId $ConversationId -Text $replyText -Warnings $Warnings
        }
    }

    # For status commands, also send email so the user gets it regardless of where they check
    if ($commandResult.success -and [string]$commandResult.action -eq 'status') {
        $statusData = Get-MessageFieldValue -Message $commandResult -Name 'data'
        if ($null -ne $statusData) {
            $statusReport = [string](Get-MessageFieldValue -Message $statusData -Name 'statusReport')
            if (-not [string]::IsNullOrWhiteSpace($statusReport)) {
                $broadcastPayload = [PSCustomObject]@{
                    templateName = 'status-report'
                    data = $statusData
                } | ConvertTo-Json -Depth 20
                $emailScript = Join-Path $PSScriptRoot 'send-email-notification.ps1'
                if (Test-Path -LiteralPath $emailScript) {
                    try { & $emailScript -JsonPayload $broadcastPayload 2>&1 | Out-Null } catch { }
                }
            }
        }
    }

    return [PSCustomObject]@{
        messageId = $commandMessageId
        sourceMessageId = $sourceMessageId
        senderDisplayName = $senderDisplayName
        command = $CommandText
        success = [bool]$commandResult.success
        duplicate = [bool]$commandResult.duplicate
        action = [string]$commandResult.action
        jobNumber = [string]$commandResult.jobNumber
        message = [string]$commandResult.message
        error = [string]$commandResult.error
        receivedAt = [string](Get-MessageFieldValue -Message $Message -Name 'originalArrivalTime')
    }
}

function Main {
    $settings = Get-RatatoskTeamsChatSettings
    $disabledReason = Get-RatatoskTeamsChatDisabledReason -Settings $settings -ForCommandPolling
    if (-not [string]::IsNullOrWhiteSpace($disabledReason)) {
        ConvertTo-TeamsPollResult -Disabled $true -DisabledReason $disabledReason | ConvertTo-Json -Depth 20
        return
    }

    $state = Read-RatatoskState
    $cachedConversation = Get-RatatoskTeamsChatConversationCache -State $state -Settings $settings
    $conversationId = if ($cachedConversation) { [string]$cachedConversation.conversationId } else { '' }
    $pollResult = Invoke-RatatoskTeamsChat -Action 'get-messages' -Settings $settings -ConversationId $conversationId -Limit $Top
    Set-RatatoskTeamsChatConversationCache -State $state -Settings $settings -ConversationId ([string]$pollResult.conversationId) -TargetDescription ([string]$pollResult.targetDescription)
    Set-RatatoskProperty -Object (Get-RatatoskTeamsChatState -State $state) -Name 'lastPollAt' -Value ((Get-Date).ToUniversalTime().ToString('o'))

    $cursor = Get-RatatoskTeamsChatCursor -State $state
    $messages = @(
        @($pollResult.messages) | Where-Object {
            $_ -and
            -not [bool](Get-MessageFieldValue -Message $_ -Name 'isDeleted' -Default $false)
        }
    )
    $newMessages = @(Get-NewTeamsMessages -Messages $messages -LastProcessedMessageId ([string]$cursor.lastProcessedMessageId) -LastProcessedArrivalTime ([string]$cursor.lastProcessedArrivalTime))
    $warnings = New-Object System.Collections.Generic.List[string]
    $commandsProcessed = New-Object System.Collections.Generic.List[object]
    $rejectedCommands = New-Object System.Collections.Generic.List[object]
    $notificationPrefix = Get-RatatoskTeamsNotificationPrefix

    foreach ($message in $newMessages) {
        $textContent = [string](Get-MessageFieldValue -Message $message -Name 'textContent')
        if ([string]::IsNullOrWhiteSpace($textContent)) {
            continue
        }

        $trimmedText = $textContent.Trim()
        if ($trimmedText.StartsWith($notificationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $commandText = Get-CommandTextFromTeamsMessage -Text $trimmedText -Prefix ([string]$settings.commandPrefix)
        if ([string]::IsNullOrWhiteSpace($commandText)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($commandText)) {
            $rejectedCommands.Add([PSCustomObject]@{
                sourceMessageId = [string](Get-MessageFieldValue -Message $message -Name 'id')
                senderDisplayName = [string](Get-MessageFieldValue -Message $message -Name 'senderDisplayName')
                error = "Teams command is empty after the prefix '$($settings.commandPrefix)'."
            })
            continue
        }

        $commandResult = Invoke-TeamsCommand -Settings $settings -ConversationId ([string]$pollResult.conversationId) -Message $message -CommandText $commandText -Warnings $warnings
        if ($commandResult.success) {
            $commandsProcessed.Add($commandResult)
        } else {
            $rejectedCommands.Add($commandResult)
        }
    }

    if ($newMessages.Count -gt 0) {
        $lastSeenMessage = $newMessages[$newMessages.Count - 1]
        Set-RatatoskTeamsChatCursor `
            -State $state `
            -ConversationId ([string]$pollResult.conversationId) `
            -LastProcessedMessageId ([string](Get-MessageFieldValue -Message $lastSeenMessage -Name 'id')) `
            -LastProcessedArrivalTime ([string](Get-MessageFieldValue -Message $lastSeenMessage -Name 'originalArrivalTime'))
    }

    Write-RatatoskState -State $state

    ConvertTo-TeamsPollResult `
        -ConversationId ([string]$pollResult.conversationId) `
        -TargetDescription ([string]$pollResult.targetDescription) `
        -CurrentUserDisplayName ([string]$pollResult.currentUserDisplayName) `
        -CommandsProcessed $commandsProcessed.ToArray() `
        -RejectedCommands $rejectedCommands.ToArray() `
        -Warnings ([string[]]$warnings.ToArray()) `
        -MessagesSeen @($newMessages) |
        ConvertTo-Json -Depth 20
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
