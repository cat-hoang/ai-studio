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

    # Extract the command string from Bash tool input
    $toolInput = $hookInput.tool_input
    if (-not $toolInput) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    $command = [string]$toolInput.command
    if ([string]::IsNullOrWhiteSpace($command)) {
        Write-HookDecision -Decision 'approve'
        exit 0
    }

    # Check for prohibited edi task lifecycle commands
    # Match: edi task complete|start|claim (with optional flags/args after)
    $prohibitedPattern = '(?:^|[|&;\s])edi\s+task\s+(complete|start|claim)\s'
    if ($command -match $prohibitedPattern) {
        $action = $Matches[1]
        $reason = switch ($action) {
            'complete' { "Command 'edi task complete' sets the task to CLS. Ratatosk workers must never close tasks — humans close them manually after review." }
            'start'    { "Command 'edi task start' sets the task to WRK. Use 'edi task suspend' instead to signal Ratatosk is working on this task." }
        }

        Write-HookDecision `
            -Decision 'block' `
            -Reason "Ratatosk: edi task '$action' is prohibited." `
            -SystemMessage "$reason The only permitted edi task lifecycle command is 'edi task suspend'. Record timestamps via 'edi task notes append' and leave the task in SUS."
        exit 0
    }

    Write-HookDecision -Decision 'approve'
    exit 0
} catch {
    Write-HookDecision -Decision 'approve' -SystemMessage "Ratatosk guard-bash-edi-task hook failed open: $($_.Exception.Message)"
    exit 0
}
