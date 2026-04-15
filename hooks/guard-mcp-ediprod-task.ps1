[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookDecision {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('approve', 'block')]
        [string]$Decision,

        [string]$Reason = '',
        [string]$SystemMessage = ''
    )

    [PSCustomObject]@{
        decision      = $Decision
        reason        = $Reason
        systemMessage = $SystemMessage
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $hookInput = $inputText | ConvertFrom-Json

    # Extract the action parameter from the tool input
    $toolInput = $hookInput.tool_input
    if (-not $toolInput) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $action = [string]$toolInput.action

    $prohibited = @('complete', 'start', 'claim', 'claim-and-start')
    if ($action -notin $prohibited) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $reason = switch ($action) {
        'complete'        { "Action 'complete' sets the task to CLS. Ratatosk workers must never close tasks — humans close them manually after review." }
        'start'           { "Action 'start' sets the task to WRK. Use 'suspend' instead to signal Ratatosk is working on this task." }
        'claim'           { "Action 'claim' sets the task to WRK. Use 'suspend' instead to signal Ratatosk is working on this task." }
        'claim-and-start' { "Action 'claim-and-start' sets the task to WRK. Use 'suspend' instead to signal Ratatosk is working on this task." }
    }

    Write-HookDecision `
        -Decision 'block' `
        -Reason "Ratatosk: ediProd task action '$action' is prohibited." `
        -SystemMessage "$reason The only permitted ediProd-tasks-action is 'suspend'. Record timestamps via ediProd-tasks-notes-append and leave the task in SUS."
    exit 0
} catch {
    Write-HookDecision -Decision 'approve' -SystemMessage "Ratatosk guard-mcp-ediprod-task hook failed open: $($_.Exception.Message)"
    exit 0
}
