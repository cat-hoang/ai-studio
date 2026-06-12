[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = '',
    [Parameter(Mandatory)]
    [string]$Response,

    [string]$RequestId = '',
    [ValidateSet('dashboard', 'email', 'manual')]
    [string]$Source = 'manual',
    [string]$Responder = '',
    [string]$MessageId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')

function New-AutotaskUserInputSnapshot {
    param(
        [Parameter(Mandatory)]
        [psobject]$Request
    )

    return [PSCustomObject]@{
        requestId = [string]$Request.requestId
        question = [string]$Request.question
        questionType = [string]$Request.questionType
        severity = [string]$Request.severity
        answerMode = [string]$Request.answerMode
        options = @($Request.options)
        state = [string]$Request.state
        resolutionState = [string]$Request.resolutionState
        requestedAt = [string]$Request.requestedAt
        respondedAt = [string]$Request.respondedAt
        consumedAt = [string]$Request.consumedAt
        response = [string]$Request.response
        source = [string]$Request.source
        responder = [string]$Request.responder
        messageId = [string]$Request.messageId
    }
}

$state = Read-AutotaskState
$worker = Get-AutotaskWorker -State $state -JobNumber $JobNumber -TaskSequence $TaskSequence
if (-not $worker) {
    throw "Worker not found for job $JobNumber"
}

$request = $worker.userInputRequest
if (-not $request) {
    throw "Worker $JobNumber does not have a pending user input request."
}

$resolvedRequestId = if ($RequestId) { $RequestId } else { [string]$request.requestId }
if ([string]$request.requestId -ne $resolvedRequestId) {
    throw "RequestId $resolvedRequestId does not match the current pending request for $JobNumber."
}

$receivedAt = Get-Date -Format 'o'
Set-AutotaskProperty -Object $request -Name 'state' -Value 'answered'
Set-AutotaskProperty -Object $request -Name 'resolutionState' -Value 'answered'
Set-AutotaskProperty -Object $request -Name 'respondedAt' -Value $receivedAt
Set-AutotaskProperty -Object $request -Name 'response' -Value $Response
Set-AutotaskProperty -Object $request -Name 'source' -Value $Source
Set-AutotaskProperty -Object $request -Name 'responder' -Value $Responder
Set-AutotaskProperty -Object $request -Name 'messageId' -Value $MessageId
Set-AutotaskProperty -Object $worker -Name 'status' -Value 'running'
Set-AutotaskProperty -Object $worker -Name 'activityStatus' -Value 'input-received'
Set-AutotaskProperty -Object $worker -Name 'activityMessage' -Value 'User input received; resume processing.'
Set-AutotaskWorkerHeartbeat -Worker $worker -Timestamp $receivedAt
$snapshot = New-AutotaskUserInputSnapshot -Request $request
Set-AutotaskProperty -Object $worker -Name 'lastUserInput' -Value $snapshot

if (-not $worker.PSObject.Properties['inputHistory']) {
    Set-AutotaskProperty -Object $worker -Name 'inputHistory' -Value @()
}

$history = @($worker.inputHistory)
$history += $snapshot
Set-AutotaskProperty -Object $worker -Name 'inputHistory' -Value $history

Write-AutotaskState -State $state

if ($worker.workspacePath) {
    Save-AutotaskWorkspaceArtifact -WorkspacePath ([string]$worker.workspacePath) -FileName 'current-user-input-request.json' -Content $request | Out-Null
    Save-AutotaskWorkspaceArtifact -WorkspacePath ([string]$worker.workspacePath) -FileName 'last-user-input.json' -Content $worker.lastUserInput | Out-Null
}

$worker.lastUserInput | ConvertTo-Json -Depth 10
