[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = '',

    [Parameter(Mandatory)]
    [string]$TaskType,

    [Parameter(Mandatory)]
    [string]$Question,

    [ValidateSet('clarification', 'decision', 'approval', 'dependency', 'risk', 'other')]
    [string]$QuestionType = 'clarification',

    [ValidateSet('low', 'medium', 'high', 'critical')]
    [string]$Severity = 'medium',

    [ValidateSet('freeform', 'options')]
    [string]$AnswerMode = 'freeform',

    [Parameter(Mandatory)]
    [string]$RequestId,

    [int]$Zone = 0,
    [string[]]$Options = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $PSCommandPath
$teamsScript = Join-Path $toolsDir 'send-teams-notification.ps1'
$emailScript = Join-Path $toolsDir 'send-email-notification.ps1'

function Invoke-NotificationScript {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [hashtable]$Payload,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $resultText = & $ScriptPath -JsonPayload ($Payload | ConvertTo-Json -Depth 10 -Compress)
    if (-not $resultText) {
        throw "$Label notification script returned no result."
    }

    $result = $resultText | ConvertFrom-Json
    if (-not $result.success) {
        $message = if ($result.error) { $result.error } else { 'Unknown notification failure.' }
        throw "$Label notification failed: $message"
    }

    return $result
}

$data = @{
    jobNumber = $JobNumber
    taskSequence = $TaskSequence
    taskType = $TaskType
    zone = $Zone
    question = $Question
    questionType = $QuestionType
    severity = $Severity
    answerMode = $AnswerMode
    requestId = $RequestId
    options = @($Options)
}

if ($PSCmdlet.ShouldProcess($JobNumber, 'Send user-input notifications')) {
    $teamsResult = Invoke-NotificationScript -ScriptPath $teamsScript -Payload @{
        templateName = 'user-input-request'
        data = $data
    } -Label 'Teams'

    $emailResult = Invoke-NotificationScript -ScriptPath $emailScript -Payload @{
        templateName = 'user-input-request'
        data = $data
    } -Label 'Email'

    [PSCustomObject]@{
        success = $true
        jobNumber = $JobNumber
        requestId = $RequestId
        teams = $teamsResult
        email = $emailResult
    } | ConvertTo-Json -Depth 10
}
