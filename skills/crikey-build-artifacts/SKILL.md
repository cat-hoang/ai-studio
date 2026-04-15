# Crikey Build Artifacts

## Purpose

Download pre-built CW build artifacts from the Crikey build system and extract them into `CargoWise\Bin\`. This avoids full local builds by fetching CI-produced binaries for the target branch.

## Configuration

Read settings from:
- `config.yaml`
- `config.local.yaml` (overrides)

Relevant config keys:
- `crikey_base_url` -- e.g., `https://crikey.wtg.zone`
- `crikey_build_configuration` -- e.g., `Debug` or `Release`
- `target_repository` -- the full URL of the target repo (e.g., `https://github.com/WiseTechGlobal/CargoWise`)
- `artifacts_max_cached` -- maximum number of cached artifact zips to retain (default: 10)
- `artifacts_cache` -- repo-relative path to the shared artifact cache directory (default: `artifacts-cache`)
- `credentials_file` -- path to credentials file (default: `~/.etc`)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `branch` | No | `master` | The branch to fetch artifacts for |
| `workspacePath` | Yes | -- | Root of the workspace containing `CargoWise\Bin\` |

## Execution Steps

### Step 1: VPN Preflight

Invoke the `vpn-preflight` skill. If it fails, stop immediately.

### Step 2: Load Configuration

Read `config.yaml` and `config.local.yaml`. Merge settings (local overrides base). Extract the values listed above.

Resolve the shared cache directory from `artifacts_cache` relative to the Ratatosk repo root (the directory containing `config.yaml`), not relative to the current workspace. Do not download into `{workspacePath}\.ratatosk\artifacts`.

```powershell
$ratatoskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$cacheSetting = 'artifacts-cache' # replace with merged config value
$cacheDir = if ([System.IO.Path]::IsPathRooted($cacheSetting)) {
    $cacheSetting
} else {
    Join-Path $ratatoskRoot $cacheSetting
}
```

### Step 3: Check Artifact Cache

Look in the shared artifacts cache directory for files matching the pattern `{branch}-*.zip` (e.g., `master-a1b2c3d4-e5f6-7890-abcd-ef1234567890.zip`).

```powershell
Get-ChildItem -Path $cacheDir -Filter "$branch-*.zip" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
```

If a matching file exists, skip to Step 5 (extraction) using that cached file.

If Ratatosk launched the worker with a job number, record the shared artifact decision before continuing:

```powershell
& "$RATATOSK_ROOT\tools\update-ratatosk-build-plan.ps1" `
  -JobNumber $jobNumber `
  -WorkspacePath $workspacePath `
  -ArtifactCacheStatus 'cache-hit' `
  -ArtifactPath $cachedFile.FullName `
  -ArtifactBuildId $cachedFile.BaseName `
  -CachePath $cacheDir `
  -ArtifactSource 'crikey-build-artifacts'
```

### Step 4: Download from Crikey

If no cache hit, download the artifact:

#### 4a: Get Latest Build Info

URL-encode the target repository URL, then query for the latest build:

```bash
powershell -NoProfile -Command "
$cred = Get-Content '$HOME/.etc' | ConvertFrom-StringData
$secPass = ConvertTo-SecureString $cred.password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($cred.username, $secPass)
$encodedRepo = [System.Uri]::EscapeDataString('TARGET_REPOSITORY_URL')
$resp = Invoke-RestMethod -Uri 'CRIKEY_BASE_URL/api/testresults/latestBuild?targetRepository='$encodedRepo'&branch=BRANCH' -Credential $credential -Authentication Negotiate -AllowUnencryptedAuthentication
$resp | ConvertTo-Json
"
```

If `~/.etc` does not contain parseable credentials, fall back to `-UseDefaultCredentials` (NTLM with current Windows session):

```bash
powershell -NoProfile -Command "
$encodedRepo = [System.Uri]::EscapeDataString('TARGET_REPOSITORY_URL')
$resp = Invoke-RestMethod -Uri 'CRIKEY_BASE_URL/api/testresults/latestBuild?targetRepository='$encodedRepo'&branch=BRANCH' -UseDefaultCredentials
$resp | ConvertTo-Json
"
```

Extract `userTestPk` (a GUID) from the JSON response.

#### 4b: Download Artifact Zip

```bash
powershell -NoProfile -Command "
$outPath = Join-Path 'CACHE_DIR' 'BRANCH-GUID.zip'
Invoke-WebRequest -Uri 'CRIKEY_BASE_URL/api/BuildArtifactRepository/userTestBuild?buildConfiguration=BUILD_CONFIG&userTestPk=GUID' -UseDefaultCredentials -OutFile $outPath
Write-Output $outPath
"
```

Replace placeholders:
- `CRIKEY_BASE_URL` with the configured base URL
- `BRANCH` with the branch parameter
- `GUID` with the `userTestPk` from step 4a
- `BUILD_CONFIG` with `crikey_build_configuration`

Verify the downloaded file exists and is a valid zip (non-zero size).

If Ratatosk job context is available, record the fresh download as well:

```powershell
& "$RATATOSK_ROOT\tools\update-ratatosk-build-plan.ps1" `
  -JobNumber $jobNumber `
  -WorkspacePath $workspacePath `
  -ArtifactCacheStatus 'downloaded' `
  -ArtifactPath $outPath `
  -ArtifactBuildId $userTestPk `
  -CachePath $cacheDir `
  -ArtifactSource 'crikey-build-artifacts'
```

### Step 5: Cache Cleanup

Sort cached artifacts by modification date and delete the oldest files beyond the `artifacts_max_cached` limit:

```bash
powershell -NoProfile -Command "
$maxCached = 10
$files = Get-ChildItem -Path $cacheDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending
if ($files.Count -gt $maxCached) {
    $files[$maxCached..($files.Count - 1)] | Remove-Item -Force
    Write-Output ('Cleaned up ' + ($files.Count - $maxCached) + ' old artifacts')
}
"
```

### Step 6: Clear Target Directory

Remove existing contents of `CargoWise\Bin\` in the workspace before extraction:

```bash
powershell -NoProfile -Command "
$binDir = 'WORKSPACE_PATH\CargoWise\Bin'
if (Test-Path $binDir) {
    Get-ChildItem -Path $binDir -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'Cleared CargoWise\Bin\'
} else {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Write-Output 'Created CargoWise\Bin\'
}
"
```

### Step 7: Extract Artifacts

Extract only the `Binaries\` folder from the zip into `CargoWise\Bin\`.

> ⚠️ **NEVER use `Expand-Archive`** to extract CW artifacts. `Expand-Archive` extracts the zip as-is, which produces a `Binaries\` folder alongside the source tree instead of a `Bin\` folder. The build system expects `CargoWise\Bin\`, not `CargoWise\Binaries\`. Always use the manual `ZipFile` extraction below which strips the `Binaries\` prefix and writes directly into `CargoWise\Bin\`.

**Important:** The Crikey artifact zip uses Windows-style backslash path separators (e.g., `Binaries\foo.dll`). Normalise `entry.FullName` to backslash before comparing — do **not** use `StartsWith('Binaries/')` because that forward-slash check will match zero entries and produce an empty Bin folder.

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead('PATH_TO_ZIP')
$binDir = 'WORKSPACE_PATH\CargoWise\Bin'
$prefix = 'Binaries\'
foreach ($entry in $zip.Entries) {
    $fullName = $entry.FullName.Replace('/', '\')
    if ($fullName.StartsWith($prefix) -and $fullName -ne $prefix) {
        $relativePath = $fullName.Substring($prefix.Length)
        $targetPath = Join-Path $binDir $relativePath
        $targetDir = Split-Path $targetPath -Parent
        if (!(Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        if ($entry.Length -gt 0) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
        }
    }
}
$zip.Dispose()
Write-Output 'Extraction complete'
```

### Output

On success, print:
```
Artifacts extracted to {workspacePath}\CargoWise\Bin\ from {branch}-{GUID}.zip
```

On failure at any step, print the error details and stop.

## Notes

- Always use NTLM authentication for Crikey endpoints. Never use basic auth or token auth.
- The `~/.etc` file contains credentials for NTLM. If parsing fails, fall back to `-UseDefaultCredentials`.
- The shared cache lives under the Ratatosk repo root via the `artifacts_cache` config setting. All workspaces should reuse that location.
- Never cache Crikey zips under a workspace-local path such as `.ratatosk\artifacts`.
- Cached artifacts are keyed by `{branch}-{GUID}` so different builds of the same branch produce separate cache entries.
- The `Binaries/` prefix inside the zip is stripped during extraction so files land directly in `CargoWise\Bin\`. The zip contains a `Binaries\` folder — the build system needs this as `Bin\`. Never rename or move the folder manually; always extract via the `ZipFile` approach above.
- **Never use `Expand-Archive`** — it dumps `Binaries\` into the workspace root instead of creating `Bin\`.

