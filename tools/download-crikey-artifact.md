---
name: download-crikey-artifact
description: Downloads Crikey build artifacts for a given branch and build configuration. Uses NTLM authentication against the Crikey API to fetch the latest build, then downloads the artifact zip.
parameters:
  branch:
    type: string
    default: "master"
    description: The branch name to fetch the latest build for.
  targetRepo:
    type: string
    default: "https://github.com/wisetechglobal/CargoWise"
    description: The target repository URL registered in Crikey.
  buildConfig:
    type: string
    default: "Debug"
    description: The build configuration (Debug or Release).
  outputDir:
    type: string
    required: true
    description: The resolved shared artifacts cache directory under the Ratatosk repo root. Do not pass a workspace-local artifacts path.
---

# Download Crikey Artifact

Low-level tool for downloading build artifacts from the Crikey build system. This is consumed by the `crikey-build-artifacts` skill.

The caller must resolve `outputDir` from the Ratatosk `artifacts_cache` setting relative to the repo root before invoking this tool. Do not save into a workspace-local `.ratatosk\artifacts` directory.

## Constants

- **crikey_base_url**: `https://crikey.wtg.zone`

## Steps

### 1. Read NTLM credentials

Read credentials from `~/.etc`. These are used implicitly by PowerShell's `-UseDefaultCredentials` flag, which leverages the current Windows session's NTLM identity. No manual credential parsing is needed when using `-UseDefaultCredentials`.

### 2. Get latest build metadata

```powershell
$branch = "{{branch}}"
$targetRepo = "{{targetRepo}}"
$buildConfig = "{{buildConfig}}"
$outputDir = "{{outputDir}}"
$crikeyBase = "https://crikey.wtg.zone"

$encodedRepo = [System.Uri]::EscapeDataString($targetRepo)
$latestBuildUrl = "$crikeyBase/api/testresults/latestBuild?path=&targetRepository=$encodedRepo&branch=$branch"

$response = Invoke-WebRequest -Uri $latestBuildUrl -UseDefaultCredentials -UseBasicParsing
$buildInfo = $response.Content | ConvertFrom-Json
```

Send a GET request to:
```
{crikey_base_url}/api/testresults/latestBuild?path=&targetRepository={url_encoded_targetRepo}&branch={branch}
```

**Note:** The `path=` parameter is required (with empty value) even though it has no content.
Use NTLM authentication via `-UseDefaultCredentials`.

The `outputDir` value should already point at the shared Ratatosk artifact cache directory.

### 3. Extract userTestPk GUID

```powershell
$userTestPk = $buildInfo.userTestPk
if (-not $userTestPk) {
    throw "No userTestPk found in Crikey response for branch '$branch'"
}
Write-Host "Found userTestPk: $userTestPk"
```

Parse the JSON response and extract the `userTestPk` GUID field.

### 4. Download build artifact zip

```powershell
$artifactFileName = "$branch-$userTestPk.zip"
$artifactPath = Join-Path $outputDir $artifactFileName

# Check cache first
if (Test-Path $artifactPath) {
    Write-Host "Artifact already cached at $artifactPath"
    return @{
        artifactPath = $artifactPath
        userTestPk   = $userTestPk
        cached       = $true
    }
}

# Ensure output directory exists
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$artifactUrl = "$crikeyBase/api/BuildArtifactRepository/userTestBuild?buildConfiguration=$buildConfig&userTestPk=$userTestPk"
Invoke-WebRequest -Uri $artifactUrl -UseDefaultCredentials -UseBasicParsing -OutFile $artifactPath
Write-Host "Downloaded artifact to $artifactPath"
```

Send a GET request to:
```
{crikey_base_url}/api/BuildArtifactRepository/userTestBuild?buildConfiguration={buildConfig}&userTestPk={userTestPk}
```
Use NTLM authentication via `-UseDefaultCredentials`. Save the response body as `{outputDir}/{branch}-{GUID}.zip`.

### 5. Return result

```powershell
@{
    artifactPath = $artifactPath
    userTestPk   = $userTestPk
    cached       = $false
}
```

Return an object with:
- **artifactPath** (string): Full path to the downloaded zip file.
- **userTestPk** (string): The GUID identifying the build.
- **cached** (boolean): `true` if the file was already present in the cache, `false` if freshly downloaded.

## Full Script

```powershell
param(
    [string]$branch = "master",
    [string]$targetRepo = "https://github.com/wisetechglobal/CargoWise",
    [string]$buildConfig = "Debug",
    [Parameter(Mandatory)][string]$outputDir
)

$ErrorActionPreference = "Stop"
$crikeyBase = "https://crikey.wtg.zone"

# Step 2: Get latest build metadata
$encodedRepo = [System.Uri]::EscapeDataString($targetRepo)
$latestBuildUrl = "$crikeyBase/api/testresults/latestBuild?path=&targetRepository=$encodedRepo&branch=$branch"
$response = Invoke-WebRequest -Uri $latestBuildUrl -UseDefaultCredentials -UseBasicParsing
$buildInfo = $response.Content | ConvertFrom-Json

# Step 3: Extract GUID
$userTestPk = $buildInfo.userTestPk
if (-not $userTestPk) {
    throw "No userTestPk found in Crikey response for branch '$branch'"
}
Write-Host "Found userTestPk: $userTestPk"

# Step 4: Download or use cache
$artifactFileName = "$branch-$userTestPk.zip"
$artifactPath = Join-Path $outputDir $artifactFileName

if (Test-Path $artifactPath) {
    Write-Host "Artifact already cached at $artifactPath"
    [PSCustomObject]@{
        artifactPath = $artifactPath
        userTestPk   = [string]$userTestPk
        cached       = $true
    }
    return
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$artifactUrl = "$crikeyBase/api/BuildArtifactRepository/userTestBuild?buildConfiguration=$buildConfig&userTestPk=$userTestPk"
Write-Host "Downloading artifact from $artifactUrl ..."
Invoke-WebRequest -Uri $artifactUrl -UseDefaultCredentials -UseBasicParsing -OutFile $artifactPath
Write-Host "Downloaded artifact to $artifactPath"

[PSCustomObject]@{
    artifactPath = $artifactPath
    userTestPk   = [string]$userTestPk
    cached       = $false
}
```

## Error Handling

- If the Crikey API returns a non-200 status, PowerShell will throw automatically due to `$ErrorActionPreference = "Stop"`.
- If `userTestPk` is missing from the response, throw with a descriptive message.
- If the download fails mid-stream, the partial file should be cleaned up by the caller.

## Shared Cache Resolution Example

```powershell
$ratatoskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cacheSetting = 'artifacts-cache' # replace with merged config value
$outputDir = if ([System.IO.Path]::IsPathRooted($cacheSetting)) {
    $cacheSetting
} else {
    Join-Path $ratatoskRoot $cacheSetting
}
```
