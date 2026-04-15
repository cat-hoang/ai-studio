[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [Parameter(Mandatory)]
    [string]$Question,

    [string]$TaskSequence = '',
    [string]$TaskType = '',
    [int]$Zone = 0,
    [string]$WorkspacePath = '',
    [ValidateSet('clarification', 'decision', 'approval', 'dependency', 'risk', 'other')]
    [string]$QuestionType = 'clarification',
    [ValidateSet('low', 'medium', 'high', 'critical')]
    [string]$Severity = 'medium',
    [string[]]$Options = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

$state = Read-RatatoskState
$worker = Get-RatatoskWorker -State $state -JobNumber $JobNumber -TaskSequence $TaskSequence
if (-not $worker) {
    throw "Worker not found for job $JobNumber"
}

$resolvedTaskSequence = if ($TaskSequence) { $TaskSequence } else { [string]$worker.taskSequence }
$resolvedTaskType = if ($TaskType) { $TaskType } else { [string]$worker.taskType }
$resolvedZone = if ($PSBoundParameters.ContainsKey('Zone')) { $Zone } elseif ($null -ne $worker.zone) { [int]$worker.zone } else { 0 }
$resolvedWorkspacePath = if ($WorkspacePath) { $WorkspacePath } else { [string]$worker.workspacePath }
$relativeWorkspacePath = if ($resolvedWorkspacePath) { ConvertTo-RatatoskRelativePath -Path $resolvedWorkspacePath } else { '' }
$requestId = [guid]::NewGuid().ToString()
$requestedAt = Get-Date -Format 'o'
$answerMode = if ($Options.Count -gt 0) { 'options' } else { 'freeform' }

$request = [PSCustomObject]@{
    requestId = $requestId
    question = $Question
    questionType = $QuestionType
    severity = $Severity
    answerMode = $answerMode
    options = @($Options)
    state = 'pending'
    resolutionState = 'pending'
    requestedAt = $requestedAt
    respondedAt = ''
    consumedAt = ''
    response = ''
    source = ''
    responder = ''
    messageId = ''
}

Set-RatatoskProperty -Object $worker -Name 'status' -Value 'waiting-user-input'
Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value 'awaiting-user-input'
Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value $Question
Set-RatatoskWorkerHeartbeat -Worker $worker -Timestamp $requestedAt
if ($relativeWorkspacePath) {
    Set-RatatoskProperty -Object $worker -Name 'workspacePath' -Value $relativeWorkspacePath
}
Set-RatatoskProperty -Object $worker -Name 'userInputRequest' -Value $request

if (-not $worker.PSObject.Properties['inputHistory']) {
    Set-RatatoskProperty -Object $worker -Name 'inputHistory' -Value @()
}

Write-RatatoskState -State $state

if ($relativeWorkspacePath) {
    Save-RatatoskWorkspaceArtifact -WorkspacePath $relativeWorkspacePath -FileName 'current-user-input-request.json' -Content $request | Out-Null
}

& (Join-Path $PSScriptRoot 'send-user-input-request-notifications.ps1') -JobNumber $JobNumber -TaskSequence $resolvedTaskSequence -TaskType $resolvedTaskType -Question $Question -QuestionType $QuestionType -Severity $Severity -AnswerMode $answerMode -RequestId $requestId -Zone $resolvedZone -Options $Options | Out-Null

$request | ConvertTo-Json -Depth 10
