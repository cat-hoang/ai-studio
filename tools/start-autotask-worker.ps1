[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$JobNumber,

    [ValidateSet('start', 'retry')]
    [string]$Mode = 'start',

    [string]$TaskSequence = '',
    [string]$TaskType = '',
    [string]$Description = '',

    [switch]$NoLaunch,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autotask-state-common.ps1')

function Get-ConfigContent {
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item)) {
            continue
        }

        $chunks.Add([System.IO.File]::ReadAllText($item, [System.Text.Encoding]::UTF8))
    }

    return [string]::Join([Environment]::NewLine, $chunks)
}

function Get-ConfigTextValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    $lines = $Content -split "`r?`n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        $line = $lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^(?<name>[^:]+):\s*(?<value>.*)$') {
            continue
        }

        if ($matches['name'].Trim() -ne $Key) {
            continue
        }

        $value = $matches['value'].Trim()
        if ($value.Contains('#')) {
            $value = $value.Split('#', 2)[0].Trim()
        }

        return $value.Trim("'`"")
    }

    return $Default
}

function Get-ConfigListBlockValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $lines = $Content -split "`r?`n"
    $items = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $baseIndent = 0

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if (-not $inSection) {
            if ($line -match '^(?<indent>\s*)' + [regex]::Escape($Key) + ':\s*$') {
                $inSection = $true
                $baseIndent = $matches['indent'].Length
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $currentIndent = ($rawLine -replace '^(\s*).*$', '$1').Length
        if ($currentIndent -le $baseIndent -and $line -match '^[^#\s].*:\s*') {
            break
        }

        if ($line -match '^\s*-\s*(?<value>.+?)\s*$') {
            $items.Add($matches['value'].Trim().Trim("'`""))
        }
    }

    return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-ConfigMapListValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $lines = $Content -split "`r?`n"
    $result = @{}
    $inSection = $false
    $baseIndent = 0
    $currentMapKey = ''

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if (-not $inSection) {
            if ($line -match '^(?<indent>\s*)' + [regex]::Escape($Key) + ':\s*$') {
                $inSection = $true
                $baseIndent = $matches['indent'].Length
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $currentIndent = ($rawLine -replace '^(\s*).*$', '$1').Length
        if ($currentIndent -le $baseIndent -and $line -match '^[^#\s].*:\s*') {
            break
        }

        if ($line -match '^\s*(?<mapKey>[^:#]+):\s*$' -and $currentIndent -gt $baseIndent) {
            $currentMapKey = $matches['mapKey'].Trim().Trim("'`"")
            if (-not $result.ContainsKey($currentMapKey)) {
                $result[$currentMapKey] = @()
            }
            continue
        }

        if ($line -match '^\s*-\s*(?<value>.+?)\s*$' -and -not [string]::IsNullOrWhiteSpace($currentMapKey)) {
            $value = $matches['value'].Trim().Trim("'`"")
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result[$currentMapKey] = @($result[$currentMapKey]) + @($value)
            }
        }
    }

    foreach ($mapKey in @($result.Keys)) {
        $result[$mapKey] = @($result[$mapKey] | Select-Object -Unique)
    }

    return $result
}

function Get-FirstNonEmptyValue {
    param(
        [string[]]$Values
    )

    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return ''
}

function Get-UniqueStringArray {
    param(
        [object[]]$Values
    )

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ($null -eq $value) {
            continue
        }

        foreach ($entry in @($value)) {
            if ($null -eq $entry) {
                continue
            }

            $text = "$entry".Trim()
            if (-not [string]::IsNullOrWhiteSpace($text) -and -not $items.Contains($text)) {
                $items.Add($text)
            }
        }
    }

    Write-Output -NoEnumerate ([string[]]$items.ToArray())
    return
}

function Get-TextTokens {
    param(
        [string[]]$Text
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Text)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $spacedText = ($entry -replace '([a-z0-9])([A-Z])', '$1 $2')
        foreach ($token in ($spacedText -split '[^A-Za-z0-9]+')) {
            $normalizedToken = $token.Trim().ToLowerInvariant()
            if ($normalizedToken.Length -ge 2 -and -not $tokens.Contains($normalizedToken)) {
                $tokens.Add($normalizedToken)
            }
        }
    }

    Write-Output -NoEnumerate ([string[]]$tokens.ToArray())
    return
}

function Get-ProductRepoKeywords {
    param(
        [string]$GroupName,
        [string[]]$Repos
    )

    $keywords = Get-TextTokens -Text @($GroupName, $Repos)
    switch -Regex ($GroupName.ToLowerInvariant()) {
        'rating' {
            $keywords = Get-UniqueStringArray -Values @($keywords, @('rating', 'rate', 'rates', 'glow', 'ucg', 'mapping'))
        }
        'cargowise' {
            $keywords = Get-UniqueStringArray -Values @($keywords, @('cw', 'cargowise', 'customs', 'commodity', 'enterprise', 'masterfiles', 'database', 'schema', 'sql'))
        }
        'ratesservice' {
            $keywords = Get-UniqueStringArray -Values @($keywords, @('ratesservice', 'service', 'native', 'api', 'quote'))
        }
    }

    Write-Output -NoEnumerate ([string[]]@($keywords))
    return
}

function Resolve-JobRepoSelection {
    param(
        [Parameter(Mandatory)]
        [psobject]$Job,

        [string[]]$DefaultRepos = @(),

        [hashtable]$ProductRepoMapping = @{}
    )

    $explicitRepos = Get-UniqueStringArray -Values @((Get-ObjectPropertyValue -Object $Job -Name 'repos' -Default @()))
    if ($explicitRepos.Count -gt 0) {
        return [PSCustomObject]@{
            repoGroup = Get-FirstNonEmptyValue -Values @([string](Get-ObjectPropertyValue -Object $Job -Name 'repoGroup' -Default ''), 'custom')
            repos = @($explicitRepos)
            selectionMode = 'explicit-repos'
            reason = 'Using repos recorded on the job.'
        }
    }

    $explicitRepoGroup = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $Job -Name 'repoGroup' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'product' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'productArea' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'batchRepoGroup' -Default '')
    )

    if (-not [string]::IsNullOrWhiteSpace($explicitRepoGroup)) {
        foreach ($candidateGroup in @($ProductRepoMapping.Keys)) {
            if ($candidateGroup.Equals($explicitRepoGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [PSCustomObject]@{
                    repoGroup = $candidateGroup
                    repos = @($ProductRepoMapping[$candidateGroup])
                    selectionMode = 'explicit-group'
                    reason = "Using configured repo group '$candidateGroup' recorded on the job."
                }
            }
        }
    }

    $jobTokens = Get-TextTokens -Text @(
        [string](Get-ObjectPropertyValue -Object $Job -Name 'taskType' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'summary' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'description' -Default ''),
        [string](Get-ObjectPropertyValue -Object $Job -Name 'source' -Default '')
    )

    $bestGroup = ''
    $bestRepos = @()
    $bestScore = 0
    $bestMatchedTokens = @()
    foreach ($candidateGroup in @($ProductRepoMapping.Keys)) {
        $repos = @($ProductRepoMapping[$candidateGroup])
        if ($repos.Count -eq 0) {
            continue
        }

        $keywords = Get-ProductRepoKeywords -GroupName $candidateGroup -Repos $repos
        $matchedTokens = @($keywords | Where-Object { $jobTokens -contains $_ } | Select-Object -Unique)
        $score = $matchedTokens.Count
        if ($score -gt $bestScore) {
            $bestGroup = $candidateGroup
            $bestRepos = @($repos)
            $bestScore = $score
            $bestMatchedTokens = @($matchedTokens)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($bestGroup) -and $bestScore -ge 2) {
        return [PSCustomObject]@{
            repoGroup = $bestGroup
            repos = @($bestRepos)
            selectionMode = 'heuristic-group'
            reason = "Inferred repo group '$bestGroup' from task signals: $($bestMatchedTokens -join ', ')."
        }
    }

    $fallbackRepos = @($DefaultRepos)
    if ($fallbackRepos.Count -eq 0 -and $ProductRepoMapping.Count -gt 0) {
        $fallbackRepos = Get-UniqueStringArray -Values @($ProductRepoMapping.Values)
    }

    return [PSCustomObject]@{
        repoGroup = ''
        repos = @($fallbackRepos)
        selectionMode = if ($fallbackRepos.Count -gt 0) { 'default-repos' } else { 'unresolved' }
        reason = if ($fallbackRepos.Count -gt 0) {
            'Falling back to default repos because no repo-group match was strong enough.'
        } else {
            'No repo selection could be resolved from config.'
        }
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [Parameter(Mandatory)]
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if (-not $Object.PSObject.Properties[$Name]) {
        return $Default
    }

    return $Object.$Name
}

function Get-RepoNameFromPrUrl {
    param(
        [string]$PrUrl
    )

    if ([string]::IsNullOrWhiteSpace($PrUrl)) {
        return ''
    }

    if ($PrUrl -match '^https?://[^/]+/[^/]+/(?<repo>[^/]+)/pull/\d+(?:/.*)?$') {
        return $matches['repo']
    }

    return ''
}

function Test-SourceBranchExists {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [string]$Repository = ''
    )

    $localBranch = Invoke-Git -Arguments @('-C', $RepositoryPath, 'branch', '--list', $BranchName) -Repository $Repository
    if (-not [string]::IsNullOrWhiteSpace($localBranch)) {
        return $true
    }

    $remoteBranch = Invoke-Git -Arguments @('-C', $RepositoryPath, 'branch', '--remotes', '--list', "origin/$BranchName") -Repository $Repository
    return -not [string]::IsNullOrWhiteSpace($remoteBranch)
}

function Resolve-RepoBranchTargetsFromPrs {
    param(
        [Parameter(Mandatory)]
        [psobject]$Job,

        [Parameter(Mandatory)]
        [string[]]$Repos
    )

    $targets = @{}
    $prUrls = Get-UniqueStringArray -Values @(
        (Get-ObjectPropertyValue -Object $Job -Name 'prUrls' -Default @()),
        (Get-ObjectPropertyValue -Object $Job -Name 'prs' -Default @())
    )

    $prUrls = @($prUrls)
    if ($prUrls.Count -eq 0) {
        return [PSCustomObject]@{
            prUrls = @()
            repoBranches = @{}
        }
    }

    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
    foreach ($prUrl in $prUrls) {
        $fallbackRepoName = Get-RepoNameFromPrUrl -PrUrl $prUrl
        $resolvedRepoName = $fallbackRepoName
        $resolvedBranchName = ''

        if ($ghCommand) {
            try {
                $ghRaw = & $ghCommand.Source pr view $prUrl --json headRefName,headRepository 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ghRaw.Trim())) {
                    $prInfo = $ghRaw | ConvertFrom-Json -ErrorAction Stop
                    $headRepository = Get-ObjectPropertyValue -Object $prInfo -Name 'headRepository' -Default $null
                    $resolvedRepoName = Get-FirstNonEmptyValue -Values @(
                        [string](Get-ObjectPropertyValue -Object $headRepository -Name 'name' -Default ''),
                        $fallbackRepoName
                    )
                    $resolvedBranchName = [string](Get-ObjectPropertyValue -Object $prInfo -Name 'headRefName' -Default '')
                }
            } catch {
            }
        }

        if ([string]::IsNullOrWhiteSpace($resolvedRepoName) -or [string]::IsNullOrWhiteSpace($resolvedBranchName)) {
            continue
        }

        if ($Repos -notcontains $resolvedRepoName) {
            continue
        }

        if (-not $targets.ContainsKey($resolvedRepoName)) {
            $targets[$resolvedRepoName] = $resolvedBranchName
        }
    }

    return [PSCustomObject]@{
        prUrls = $prUrls
        repoBranches = $targets
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Repository = ''
    )

    $output = & git @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $repoLabel = if ([string]::IsNullOrWhiteSpace($Repository)) { '' } else { " for $Repository" }
        throw "Git command failed${repoLabel}: git $($Arguments -join ' ')`n$output"
    }

    return $output.Trim()
}

function Test-StringStartsWith {
    param(
        [string]$Value,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        return $false
    }

    return $Value.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Ensure-WorkspaceRepo {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,

        [Parameter(Mandatory)]
        [string]$RepoName,

        [Parameter(Mandatory)]
        [string]$GitSourceRoot,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [string]$PreferredWorkBranch = ''
    )

    $targetRepoPath = Join-Path $WorkspacePath $RepoName
    if (-not (Test-Path -LiteralPath (Join-Path $targetRepoPath '.git'))) {
        $sourceRepoPath = Join-Path $GitSourceRoot $RepoName
        if (-not (Test-Path -LiteralPath $sourceRepoPath)) {
            throw "Source repo not found: $sourceRepoPath"
        }

        $cloneBranch = ''
        $resolvedPreferredBranch = $PreferredWorkBranch.Trim()
        if (-not [string]::IsNullOrWhiteSpace($resolvedPreferredBranch) -and (Test-SourceBranchExists -RepositoryPath $sourceRepoPath -BranchName $resolvedPreferredBranch -Repository $RepoName)) {
            $cloneBranch = $resolvedPreferredBranch
        }

        $preferredBranch = $DefaultBranch.Trim()
        if ([string]::IsNullOrWhiteSpace($cloneBranch) -and -not [string]::IsNullOrWhiteSpace($preferredBranch)) {
            $preferredExists = Invoke-Git -Arguments @('-C', $sourceRepoPath, 'branch', '--list', $preferredBranch) -Repository $RepoName
            if (-not [string]::IsNullOrWhiteSpace($preferredExists)) {
                $cloneBranch = $preferredBranch
            }
        }

        if ([string]::IsNullOrWhiteSpace($cloneBranch)) {
            try {
                $originHead = Invoke-Git -Arguments @('-C', $sourceRepoPath, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -Repository $RepoName
                if ($originHead -match '^origin/(?<branch>.+)$') {
                    $originBranch = $matches['branch']
                    $originBranchExists = Invoke-Git -Arguments @('-C', $sourceRepoPath, 'branch', '--list', $originBranch) -Repository $RepoName
                    if (-not [string]::IsNullOrWhiteSpace($originBranchExists)) {
                        $cloneBranch = $originBranch
                    }
                }
            } catch {
            }
        }

        if ([string]::IsNullOrWhiteSpace($cloneBranch)) {
            foreach ($candidate in @('main', 'master')) {
                $candidateExists = Invoke-Git -Arguments @('-C', $sourceRepoPath, 'branch', '--list', $candidate) -Repository $RepoName
                if (-not [string]::IsNullOrWhiteSpace($candidateExists)) {
                    $cloneBranch = $candidate
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($cloneBranch)) {
            $cloneBranch = Invoke-Git -Arguments @('-C', $sourceRepoPath, 'rev-parse', '--abbrev-ref', 'HEAD') -Repository $RepoName
        }

        Invoke-Git -Arguments @('clone', '--quiet', '--single-branch', '--branch', $cloneBranch, $sourceRepoPath, $targetRepoPath) -Repository $RepoName | Out-Null
    }

    $sourceRepoPath = Join-Path $GitSourceRoot $RepoName
    $resolvedWorkBranch = Get-FirstNonEmptyValue -Values @($PreferredWorkBranch, $BranchName)
    $currentBranch = Invoke-Git -Arguments @('-C', $targetRepoPath, 'rev-parse', '--abbrev-ref', 'HEAD') -Repository $RepoName
    $hasLocalChanges = -not [string]::IsNullOrWhiteSpace((Invoke-Git -Arguments @('-C', $targetRepoPath, 'status', '--porcelain') -Repository $RepoName))

    if (-not [string]::IsNullOrWhiteSpace($PreferredWorkBranch) -and (Test-SourceBranchExists -RepositoryPath $sourceRepoPath -BranchName $PreferredWorkBranch -Repository $RepoName)) {
        if ((Test-StringStartsWith -Value $currentBranch -Prefix $PreferredWorkBranch) -or (Test-StringStartsWith -Value $PreferredWorkBranch -Prefix $currentBranch)) {
            return $currentBranch
        }

        if ($hasLocalChanges -and -not [string]::IsNullOrWhiteSpace($currentBranch) -and ((Test-StringStartsWith -Value $currentBranch -Prefix $resolvedWorkBranch) -or (Test-StringStartsWith -Value $resolvedWorkBranch -Prefix $currentBranch))) {
            return $currentBranch
        }

        Invoke-Git -Arguments @('-C', $targetRepoPath, 'fetch', '--quiet', 'origin', $PreferredWorkBranch) -Repository $RepoName | Out-Null
        Invoke-Git -Arguments @('-C', $targetRepoPath, 'checkout', '--quiet', '-B', $PreferredWorkBranch, "origin/$PreferredWorkBranch") -Repository $RepoName | Out-Null
        return $PreferredWorkBranch
    } else {
        $branchExists = Invoke-Git -Arguments @('-C', $targetRepoPath, 'branch', '--list', $resolvedWorkBranch) -Repository $RepoName
        if ((Test-StringStartsWith -Value $currentBranch -Prefix $resolvedWorkBranch) -or (Test-StringStartsWith -Value $resolvedWorkBranch -Prefix $currentBranch)) {
            return $currentBranch
        }

        if ($hasLocalChanges -and -not [string]::IsNullOrWhiteSpace($currentBranch) -and ((Test-StringStartsWith -Value $currentBranch -Prefix $resolvedWorkBranch) -or (Test-StringStartsWith -Value $resolvedWorkBranch -Prefix $currentBranch))) {
            return $currentBranch
        }

        if ([string]::IsNullOrWhiteSpace($branchExists)) {
            Invoke-Git -Arguments @('-C', $targetRepoPath, 'checkout', '--quiet', '-b', $resolvedWorkBranch) -Repository $RepoName | Out-Null
        } else {
            Invoke-Git -Arguments @('-C', $targetRepoPath, 'checkout', '--quiet', $resolvedWorkBranch) -Repository $RepoName | Out-Null
        }

        return $resolvedWorkBranch
    }
}

function Get-WorkspaceMode {
    param(
        [string]$TaskType
    )

    # Task types that only need read access — no cloning required
    $referenceTypes = @('INV', 'CBS', 'CBF', 'CRV', 'PRV', 'QDT', 'QDC', 'CCT', 'TLS', 'TLR', 'IDC')
    $normalized = $TaskType.Trim().ToUpper()
    if ($referenceTypes -contains $normalized) {
        return 'reference'
    }

    return 'clone'
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

# Get-TaskTypeForSequence: resolves the task type for a specific task sequence
# from the dashboard's in-memory startable-jobs cache, so the terminal tab caption
# shows "WI# DEV" instead of "WI# unknown".
# Returns empty string on any failure — worker start is never blocked.
function Get-TaskTypeForSequence {
    param(
        [Parameter(Mandatory)]
        [string]$JobNumber,

        [Parameter(Mandatory)]
        [string]$TaskSequence,

        [Parameter(Mandatory)]
        [string]$AutotaskRoot
    )

    # Ask the local dashboard server for the startable-jobs cache, which already
    # has task types from the startable poller (the issue-source adapter).
    try {
        $configContent = Get-ConfigContent -Path @(
            (Join-Path $AutotaskRoot 'config.yaml'),
            (Join-Path $AutotaskRoot 'config.local.yaml')
        )
        $port = Get-FirstNonEmptyValue -Values @(
            (Get-ConfigTextValue -Content $configContent -Key 'dashboard_port'),
            '3210'
        )
        $stateUrl = "http://localhost:$port/api/state"
        $dashState = Invoke-RestMethod -Uri $stateUrl -Method GET -TimeoutSec 5 -ErrorAction Stop
        $match = @($dashState.startableJobs) | Where-Object {
            $_.jobNumber -eq $JobNumber -and (
                [string]::IsNullOrWhiteSpace($TaskSequence) -or
                [string]$_.taskSequence -eq $TaskSequence
            )
        } | Select-Object -First 1
        if ($match -and -not [string]::IsNullOrWhiteSpace([string]$match.taskType)) {
            return ([string]$match.taskType).Trim().ToUpper()
        }

        # If not in top-level startableJobs, check startableTasks inside any matching job
        $jobMatch = @($dashState.startableJobs) | Where-Object { $_.jobNumber -eq $JobNumber } | Select-Object -First 1
        if ($jobMatch) {
            $taskMatch = @($jobMatch.startableTasks) | Where-Object { [string]$_.taskSequence -eq $TaskSequence } | Select-Object -First 1
            if ($taskMatch -and -not [string]::IsNullOrWhiteSpace([string]$taskMatch.taskType)) {
                return ([string]$taskMatch.taskType).Trim().ToUpper()
            }
        }
    } catch {
        # Dashboard not running or unreachable
    }

    return ''
}

function Get-JobEntry {
    param(
        [Parameter(Mandatory)]
        [psobject]$State,

        [Parameter(Mandatory)]
        [string]$ResolvedJobNumber,

        [string]$TaskSequence = ''
    )

    $waitingJob = @($State.waitingQueue | Where-Object { Test-AutotaskJobMatch -Job $_ -JobNumber $ResolvedJobNumber -TaskSequence $TaskSequence }) | Select-Object -First 1
    $failedJob = @($State.failedJobs | Where-Object { Test-AutotaskJobMatch -Job $_ -JobNumber $ResolvedJobNumber -TaskSequence $TaskSequence }) | Select-Object -First 1
    $completedJob = @($State.completedJobs | Where-Object { Test-AutotaskJobMatch -Job $_ -JobNumber $ResolvedJobNumber -TaskSequence $TaskSequence }) | Select-Object -First 1
    $worker = Get-AutotaskWorker -State $State -JobNumber $ResolvedJobNumber -TaskSequence $TaskSequence

    return [PSCustomObject]@{
        waitingJob = $waitingJob
        failedJob = $failedJob
        completedJob = $completedJob
        worker = $worker
    }
}

function Main {
    $resolvedJobNumber = $JobNumber.Trim().ToUpperInvariant()
    if ($resolvedJobNumber -notmatch '^(WI|CS|PRJ)\d{8}$') {
        throw "Invalid job number: $JobNumber"
    }

    $autotaskRoot = Get-AutotaskRootPath
    $configContent = Get-ConfigContent -Path @(
        (Join-Path $autotaskRoot 'config.yaml'),
        (Join-Path $autotaskRoot 'config.local.yaml')
    )

    $workerCli = Get-ConfigTextValue -Content $configContent -Key 'worker_cli' -Default 'claude'
    if ([string]::IsNullOrWhiteSpace($workerCli)) {
        $workerCli = 'claude'
    }

    $workspaceRootConfig = Get-ConfigTextValue -Content $configContent -Key 'workspace_root' -Default 'workspaces'
    $gitSourceRootConfig = Get-ConfigTextValue -Content $configContent -Key 'git_source_root'
    $branchPrefix = Get-ConfigTextValue -Content $configContent -Key 'branch_prefix'
    if ([string]::IsNullOrWhiteSpace($branchPrefix)) {
        $branchPrefix = Get-ConfigTextValue -Content $configContent -Key 'staff_code'
    }
    $defaultBranch = Get-ConfigTextValue -Content $configContent -Key 'crikey_default_branch' -Default 'master'
    $defaultRepos = @(Get-ConfigListBlockValue -Content $configContent -Key 'default_repos')
    $productRepoMapping = Get-ConfigMapListValue -Content $configContent -Key 'product_repo_mapping'

    if ([string]::IsNullOrWhiteSpace($gitSourceRootConfig)) {
        throw 'git_source_root is not configured.'
    }

    $workspaceRootPath = Resolve-AutotaskPath -Path $workspaceRootConfig
    $gitSourceRootPath = Resolve-AutotaskPath -Path $gitSourceRootConfig
    $workspacePath = Join-Path $workspaceRootPath $resolvedJobNumber
    $workspaceRelativePath = ConvertTo-AutotaskRelativePath -Path $workspacePath
    $promptFilePath = Join-Path $workspacePath '.autotask-prompt.md'
    $branchName = '{0}/{1}' -f $branchPrefix.TrimEnd('/'), $resolvedJobNumber

    if (-not (Test-Path -LiteralPath $workspacePath)) {
        New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    }

    $state = Read-AutotaskState
    $jobEntry = Get-JobEntry -State $state -ResolvedJobNumber $resolvedJobNumber -TaskSequence $TaskSequence
    if ($jobEntry.worker) {
        throw "$resolvedJobNumber already has an active worker."
    }

    # If a completed job exists, only block when the completed entry matches the requested task sequence.
    # When no task sequence is supplied, only block if the completed job has no taskSequence (single-task WI).
    if ($jobEntry.completedJob) {
        $completedTaskSeq = [string](Get-ObjectPropertyValue -Object $jobEntry.completedJob -Name 'taskSequence' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($TaskSequence)) {
            if ($completedTaskSeq -eq $TaskSequence) {
                throw "$resolvedJobNumber task $TaskSequence is already completed. Clean it up before starting again."
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($completedTaskSeq)) {
                throw "$resolvedJobNumber is already completed. Clean it up before starting again."
            }
        }
    }

    $job = $null
    $retryCount = 0
    if ($Mode -eq 'retry') {
        if ($jobEntry.failedJob) {
            $job = $jobEntry.failedJob
            $existingRetryCount = Get-ObjectPropertyValue -Object $job -Name 'retryCount' -Default 0
            $retryCount = if ($null -ne $existingRetryCount -and "$existingRetryCount".Trim()) { [int]$existingRetryCount + 1 } else { 1 }
        } elseif ($jobEntry.waitingJob) {
            $job = $jobEntry.waitingJob
            $retryCount = [int](Get-ObjectPropertyValue -Object $job -Name 'retryCount' -Default 0)
        } else {
            throw "$resolvedJobNumber is not in failed jobs or waiting queue."
        }
    } elseif ($jobEntry.failedJob) {
        throw "$resolvedJobNumber is in failed jobs. Use retry instead of start."
    } elseif ($jobEntry.waitingJob) {
        $job = $jobEntry.waitingJob
        $retryCount = [int](Get-ObjectPropertyValue -Object $job -Name 'retryCount' -Default 0)
    } else {
        $job = [PSCustomObject]@{
            jobNumber = $resolvedJobNumber
            jobGuid = ''
            taskSequence = $TaskSequence
            taskType = (Get-FirstNonEmptyValue -Values @($TaskType, 'unknown'))
            summary = (Get-FirstNonEmptyValue -Values @($Description, $resolvedJobNumber))
            description = (Get-FirstNonEmptyValue -Values @($Description, $resolvedJobNumber))
            zone = 0
            source = 'dashboard-command'
            sources = @('dashboard-command')
            queuedVia = 'dashboard-command'
            queuedAt = (Get-Date).ToUniversalTime().ToString('o')
            retryCount = 0
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TaskSequence)) {
        Set-AutotaskProperty -Object $job -Name 'taskSequence' -Value $TaskSequence
    }

    if (-not [string]::IsNullOrWhiteSpace($TaskType)) {
        Set-AutotaskProperty -Object $job -Name 'taskType' -Value $TaskType
    }

    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        Set-AutotaskProperty -Object $job -Name 'summary' -Value $Description
        Set-AutotaskProperty -Object $job -Name 'description' -Value $Description
    }

    $repoSelection = Resolve-JobRepoSelection -Job $job -DefaultRepos $defaultRepos -ProductRepoMapping $productRepoMapping
    $repos = @($repoSelection.repos)
    if ($repos.Count -eq 0) {
        throw 'No repositories were resolved for worker start. Configure default_repos or product_repo_mapping.'
    }

    # Resolve taskType from the job object before determining workspace mode
    $resolvedTaskType = Get-FirstNonEmptyValue -Values @(
        $TaskType,
        [string](Get-ObjectPropertyValue -Object $job -Name 'taskType' -Default ''),
        'unknown'
    )
    $workspaceMode = Get-WorkspaceMode -TaskType $resolvedTaskType

    $branchTargets = Resolve-RepoBranchTargetsFromPrs -Job $job -Repos $repos
    $repoBranchTargets = @{}
    foreach ($entry in $branchTargets.repoBranches.GetEnumerator()) {
        $repoBranchTargets[$entry.Key] = $entry.Value
    }
    $existingPrUrls = @($branchTargets.prUrls)

    $autotaskMetaDir = Join-Path $workspacePath '.autotask'
    if (-not (Test-Path -LiteralPath $autotaskMetaDir)) {
        New-Item -ItemType Directory -Path $autotaskMetaDir | Out-Null
    }

    if ($workspaceMode -eq 'reference') {
        # Read-only task: point worker at git_source_root paths directly, no cloning
        $repoPaths = @{}
        foreach ($repo in $repos) {
            $repoPaths[$repo] = Join-Path $gitSourceRootPath $repo
        }
        $repoPathsJson = $repoPaths | ConvertTo-Json -Depth 3
        Write-Utf8File -Path (Join-Path $autotaskMetaDir 'repo-paths.json') -Content $repoPathsJson
    } else {
        # Clone mode: worker handles cloning in Phase 1 for responsiveness (terminal opens immediately)
    }

    $branchNamesInUse = @($repoBranchTargets.Values | Select-Object -Unique)
    $effectiveBranchName = if ($branchNamesInUse.Count -eq 1) { [string]$branchNamesInUse[0] } else { $branchName }

    $repoBranchSummary = if ($repoBranchTargets.Count -gt 0) {
        (($repoBranchTargets.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ')
    } else {
        ''
    }

    # Enrich summary/description from the issue source when they are missing or just the job number
    $currentSummary = [string](Get-ObjectPropertyValue -Object $job -Name 'summary' -Default '')
    $currentDesc = [string](Get-ObjectPropertyValue -Object $job -Name 'description' -Default '')
    $needsEnrichment = (
        ([string]::IsNullOrWhiteSpace($currentSummary) -or $currentSummary -eq $resolvedJobNumber) -and
        ([string]::IsNullOrWhiteSpace($currentDesc) -or $currentDesc -eq $resolvedJobNumber)
    )
    if ($needsEnrichment) {
        try {
            $enrichScript = Join-Path $PSScriptRoot 'enrich-autotask-job.ps1'
            if (Test-Path -LiteralPath $enrichScript) {
                $enrichArgs = @('-JobNumber', $resolvedJobNumber)
                $jobTaskSeq = [string](Get-ObjectPropertyValue -Object $job -Name 'taskSequence' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($jobTaskSeq)) {
                    $enrichArgs += @('-TaskSequence', $jobTaskSeq)
                }
                $enrichJson = & $enrichScript @enrichArgs 2>$null | Out-String
                if (-not [string]::IsNullOrWhiteSpace($enrichJson)) {
                    $enriched = $enrichJson | ConvertFrom-Json -ErrorAction Stop
                    $eSummary = [string](Get-ObjectPropertyValue -Object $enriched -Name 'summary' -Default '')
                    $eDesc = [string](Get-ObjectPropertyValue -Object $enriched -Name 'description' -Default '')
                    $eGuid = [string](Get-ObjectPropertyValue -Object $enriched -Name 'jobGuid' -Default '')
                    $eZone = if ($null -ne $enriched.zone) { [int]$enriched.zone } else { 0 }
                    if (-not [string]::IsNullOrWhiteSpace($eSummary)) {
                        Set-AutotaskProperty -Object $job -Name 'summary' -Value $eSummary
                    }
                    if (-not [string]::IsNullOrWhiteSpace($eDesc)) {
                        Set-AutotaskProperty -Object $job -Name 'description' -Value $eDesc
                    }
                    if (-not [string]::IsNullOrWhiteSpace($eGuid) -and [string]::IsNullOrWhiteSpace($jobGuid)) {
                        $jobGuid = $eGuid
                        Set-AutotaskProperty -Object $job -Name 'jobGuid' -Value $eGuid
                    }
                    if ($eZone -ne 0 -and $zone -eq 0) {
                        $zone = $eZone
                        Set-AutotaskProperty -Object $job -Name 'zone' -Value $eZone
                    }
                }
            }
        } catch { }
    }

    $description = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $job -Name 'description' -Default ''),
        [string](Get-ObjectPropertyValue -Object $job -Name 'summary' -Default ''),
        $resolvedJobNumber
    )
    $jobTitle = Get-FirstNonEmptyValue -Values @(
        [string](Get-ObjectPropertyValue -Object $job -Name 'summary' -Default ''),
        $resolvedJobNumber
    )
    $taskType = Get-FirstNonEmptyValue -Values @([string](Get-ObjectPropertyValue -Object $job -Name 'taskType' -Default ''), 'unknown')
    $taskSequence = [string](Get-ObjectPropertyValue -Object $job -Name 'taskSequence' -Default '')

    # If taskType is still unknown but we have a task sequence, look it up from the
    # startable cache so the terminal tab shows "WI# DEV" instead of "WI# unknown".
    if ($taskType -eq 'unknown' -and -not [string]::IsNullOrWhiteSpace($taskSequence)) {
        $fetchedTaskType = Get-TaskTypeForSequence -JobNumber $resolvedJobNumber -TaskSequence $taskSequence -AutotaskRoot $autotaskRoot
        if (-not [string]::IsNullOrWhiteSpace($fetchedTaskType)) {
            $taskType = $fetchedTaskType
            Set-AutotaskProperty -Object $job -Name 'taskType' -Value $taskType
        }
    }
    $zoneText = Get-ObjectPropertyValue -Object $job -Name 'zone' -Default 0
    $zone = if ($null -ne $zoneText -and "$zoneText".Trim()) { [int]$zoneText } else { 0 }
    if ($zone -eq 0) {
        $defaultZoneText = Get-ConfigTextValue -Content $configContent -Key 'default_zone' -Default '0'
        $parsedDefault = 0
        if ([int]::TryParse($defaultZoneText, [ref]$parsedDefault) -and $parsedDefault -ne 0) {
            $zone = $parsedDefault
        }
    }
    $jobGuid = [string](Get-ObjectPropertyValue -Object $job -Name 'jobGuid' -Default '')
    $source = Get-FirstNonEmptyValue -Values @([string](Get-ObjectPropertyValue -Object $job -Name 'source' -Default ''), 'dashboard-command')
    $sources = @((Get-ObjectPropertyValue -Object $job -Name 'sources' -Default @()))
    if ($sources.Count -eq 0) {
        $sources = @($source)
    }

    $staffCode = $branchPrefix.TrimEnd('/')
    $toolsDir = Join-Path $autotaskRoot 'tools'
    $agentsDir = Join-Path $autotaskRoot 'agents'
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $startedAtLocal = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $promptContent = @"
You are Autotask Task Worker for $resolvedJobNumber ($taskType).
Read your full instructions from ``$agentsDir\task-worker.md``.
Your workspace is $workspaceRelativePath.
Autotask root is $autotaskRoot.
Your job number is $resolvedJobNumber, task sequence is $taskSequence, task type is $taskType, zone is $zone, staff code is $staffCode.
Task started at: $startedAtLocal (local time) — use this exact string when posting the [${staffCode}] Started: note as a GitHub issue comment, do NOT call Get-Date for the start time.
Task description: $description
Workspace mode: $workspaceMode$(if ($workspaceMode -eq 'reference') { " - repos are read-only references in git_source_root; see .autotask\repo-paths.json for paths. Do NOT clone repos. If you discover code changes are needed, request user input before proceeding." } else { " - clone each repo from git_source_root during Phase 1 workspace setup." })
Git source root: $gitSourceRootPath
Existing PR URLs: $(if ($existingPrUrls.Count -gt 0) { $existingPrUrls -join ', ' } else { '(none)' })
Preferred repo branches: $(if ([string]::IsNullOrWhiteSpace($repoBranchSummary)) { "(default $branchPrefix/ branch)" } else { $repoBranchSummary })
Selected repos: $($repos -join ', ')
Repo selection: $(if (-not [string]::IsNullOrWhiteSpace([string]$repoSelection.repoGroup)) { "$($repoSelection.repoGroup) ($($repoSelection.selectionMode))" } else { [string]$repoSelection.selectionMode })
Repo selection reason: $([string]$repoSelection.reason)
Keep the existing terminal tab title exactly as launched. Do not rename the terminal tab or set an application title.
Publish your live activity via ``$toolsDir\set-autotask-worker-activity.ps1`` using granular statuses such as starting, workspace-verify, syncing, planning, thinking, researching, triaging, designing, implementing, coding, building, validating, testing, documenting, reviewing, creating-pr, waiting-review, awaiting-user-input, input-received, retrying, blocked, completed, and failed. Update it often whenever your actual work changes.
When you choose a build/test scope or reuse/download shared Crikey artifacts, record it with ``$toolsDir\update-autotask-build-plan.ps1`` so Autotask can track targeted plans and shared artifact usage.
If a build or test failure appears unrelated to your targeted scope, environment, or baseline artifacts, run ``$toolsDir\classify-autotask-build-failure.ps1`` before finalizing so the failure is labelled correctly.
If you need a user decision, use ``$toolsDir\request-autotask-user-input.ps1`` and then wait with ``$toolsDir\wait-for-autotask-user-input.ps1``.
When you finish or fail, do not stop silently. Run ``$toolsDir\finalize-autotask-worker.ps1 -TaskSequence $taskSequence`` (when task sequence is known) so Autotask always captures a final report, updates temp/state.json, and sends the completion or failure report.
Begin work immediately.
"@
    Write-Utf8File -Path $promptFilePath -Content $promptContent

    $worker = [PSCustomObject]@{
        jobNumber = $resolvedJobNumber
        jobGuid = $jobGuid
        taskSequence = $taskSequence
        taskType = $taskType
        zone = $zone
        summary = $jobTitle
        description = $description
        status = 'running'
        phase = 'starting'
        startedAt = $startedAt
        workspacePath = $workspaceRelativePath
        branch = $effectiveBranchName
        prs = @($existingPrUrls)
        prUrls = @($existingPrUrls)
        repoBranches = $repoBranchTargets
        repoGroup = [string]$repoSelection.repoGroup
        repos = @($repos)
        batchSelectionMode = [string]$repoSelection.selectionMode
        batchSelectionReason = [string]$repoSelection.reason
        workspaceMode = $workspaceMode
        subAgents = @()
        source = $source
        sources = @($sources)
        queuedVia = [string](Get-ObjectPropertyValue -Object $job -Name 'queuedVia' -Default '')
        queuedAt = [string](Get-ObjectPropertyValue -Object $job -Name 'queuedAt' -Default '')
        retryCount = $retryCount
        activityStatus = 'starting'
        activityMessage = 'Launching worker from dashboard start.'
        artifactUsage = New-AutotaskArtifactUsage -Branch $effectiveBranchName -Timestamp $startedAt
        buildPlan = New-AutotaskBuildPlan -Timestamp $startedAt
        buildFailure = New-AutotaskBuildFailure
        lastHeartbeatAt = $startedAt
        lastUpdated = $startedAt
    }

    $originalWaitingQueue = @($state.waitingQueue)
    $originalFailedJobs = @($state.failedJobs)
    $originalWorkers = @($state.workers)

    $jobKey = Get-AutotaskJobObjectKey -Job $job
    $state.waitingQueue = @($state.waitingQueue | Where-Object { (Get-AutotaskJobObjectKey -Job $_) -ne $jobKey })
    $state.failedJobs = @($state.failedJobs | Where-Object { (Get-AutotaskJobObjectKey -Job $_) -ne $jobKey })
    $state.workers = @($state.workers) + $worker
    Write-AutotaskState -State $state

    $launchResult = $null
    try {
        if (-not $NoLaunch) {
            $launchResult = & (Join-Path $PSScriptRoot 'launch-autotask-worker.ps1') `
                -Cli $workerCli `
                -JobNumber $resolvedJobNumber `
                -TaskType $taskType `
                -Zone $zone `
                -WorkspacePath $workspacePath `
                -PromptFile $promptFilePath `
                -PluginDir $autotaskRoot `
                -PassThru
        }
    } catch {
        $state.waitingQueue = $originalWaitingQueue
        $state.failedJobs = $originalFailedJobs
        $state.workers = $originalWorkers
        Write-AutotaskState -State $state
        throw
    }

    $result = [PSCustomObject]@{
        success = $true
        jobNumber = $resolvedJobNumber
        mode = $Mode
        workerCli = if ($launchResult) { [string]$launchResult.Cli } else { $workerCli }
        requestedWorkerCli = $workerCli
        workspacePath = $workspaceRelativePath
        branch = $effectiveBranchName
        prUrls = @($existingPrUrls)
        repoBranches = $repoBranchTargets
        repoGroup = [string]$repoSelection.repoGroup
        repos = @($repos)
        batchSelectionMode = [string]$repoSelection.selectionMode
        batchSelectionReason = [string]$repoSelection.reason
        launched = -not $NoLaunch
        message = if ($Mode -eq 'retry') {
            "Started retry worker for $resolvedJobNumber."
        } else {
            "Started worker for $resolvedJobNumber."
        }
    }

    # Send task-started notifications (best-effort — do not fail the start on notification error)
    try {
        $toolsDir = $PSScriptRoot
        $teamsScript = Join-Path $toolsDir 'send-teams-notification.ps1'
        $emailScript = Join-Path $toolsDir 'send-email-notification.ps1'
        $notificationData = @{
            jobNumber    = $resolvedJobNumber
            jobGuid      = [string]$job.jobGuid
            jobTitle     = $jobTitle
            taskSequence = $taskSequence
            taskType     = $taskType
            description  = [string]$job.description
            zone         = $zone
            workspacePath = $workspaceRelativePath
        }
        $notificationPayload = (@{ templateName = 'task-started'; data = $notificationData } | ConvertTo-Json -Depth 10 -Compress)
        if (Test-Path -LiteralPath $teamsScript) {
            & $teamsScript -JsonPayload $notificationPayload | Out-Null
        }
        if (Test-Path -LiteralPath $emailScript) {
            & $emailScript -JsonPayload $notificationPayload | Out-Null
        }
    } catch {
        # Notification failure is non-fatal
        Write-Warning "Failed to send task-started notification: $_"
    }

    $json = $result | ConvertTo-Json -Depth 10
    $global:LASTEXITCODE = 0
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    Write-Output $json

    if ($PassThru) {
        [PSCustomObject]@{
            Json = $json
            Result = $result
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
