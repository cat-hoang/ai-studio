[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [string]$TaskSequence = '',
    [string]$RequestId = '',
    [int]$PollSeconds = 5,
    [int]$TimeoutSeconds = 86400
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ratatosk-state-common.ps1')

function New-RatatoskUserInputSnapshot {
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

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ((Get-Date) -lt $deadline) {
    $state = Read-RatatoskState
    $worker = Get-RatatoskWorker -State $state -JobNumber $JobNumber -TaskSequence $TaskSequence
    if (-not $worker) {
        throw "Worker not found for job $JobNumber"
    }

    $request = $worker.userInputRequest
    if ($request) {
        $matchesRequest = ([string]::IsNullOrWhiteSpace($RequestId) -or [string]$request.requestId -eq $RequestId)
        if ($matchesRequest -and [string]$request.state -eq 'answered') {
            $consumedAt = Get-Date -Format 'o'
            Set-RatatoskProperty -Object $request -Name 'state' -Value 'consumed'
            Set-RatatoskProperty -Object $request -Name 'resolutionState' -Value 'consumed'
            Set-RatatoskProperty -Object $request -Name 'consumedAt' -Value $consumedAt

            $responseObject = New-RatatoskUserInputSnapshot -Request $request

            if ($worker.PSObject.Properties['lastUserInput'] -and $worker.lastUserInput -and [string]$worker.lastUserInput.requestId -eq [string]$request.requestId) {
                Set-RatatoskProperty -Object $worker.lastUserInput -Name 'state' -Value 'consumed'
                Set-RatatoskProperty -Object $worker.lastUserInput -Name 'resolutionState' -Value 'consumed'
                Set-RatatoskProperty -Object $worker.lastUserInput -Name 'consumedAt' -Value $consumedAt
            } else {
                Set-RatatoskProperty -Object $worker -Name 'lastUserInput' -Value $responseObject
            }

            if ($worker.PSObject.Properties['inputHistory']) {
                $history = @($worker.inputHistory)
                foreach ($entry in $history) {
                    if ([string]$entry.requestId -eq [string]$request.requestId) {
                        Set-RatatoskProperty -Object $entry -Name 'state' -Value 'consumed'
                        Set-RatatoskProperty -Object $entry -Name 'resolutionState' -Value 'consumed'
                        Set-RatatoskProperty -Object $entry -Name 'consumedAt' -Value $consumedAt
                    }
                }
                Set-RatatoskProperty -Object $worker -Name 'inputHistory' -Value $history
            }

            Set-RatatoskProperty -Object $worker -Name 'status' -Value 'running'
            Set-RatatoskProperty -Object $worker -Name 'activityStatus' -Value 'running'
            Set-RatatoskProperty -Object $worker -Name 'activityMessage' -Value 'Processing resumed after user input.'
            Set-RatatoskWorkerHeartbeat -Worker $worker
            Set-RatatoskProperty -Object $worker -Name 'userInputRequest' -Value $null
            Write-RatatoskState -State $state

            if ($worker.workspacePath) {
                Save-RatatoskWorkspaceArtifact -WorkspacePath ([string]$worker.workspacePath) -FileName 'last-user-input.json' -Content $worker.lastUserInput | Out-Null
                $requestArtifactPath = Join-Path (Ensure-RatatoskWorkspaceDirectory -WorkspacePath ([string]$worker.workspacePath)) 'current-user-input-request.json'
                if (Test-Path -LiteralPath $requestArtifactPath) {
                    Remove-Item -LiteralPath $requestArtifactPath -Force
                }
            }

            $responseObject | ConvertTo-Json -Depth 10
            return
        }
    }

    Start-Sleep -Seconds $PollSeconds
}

throw "Timed out waiting for user input for $JobNumber"
