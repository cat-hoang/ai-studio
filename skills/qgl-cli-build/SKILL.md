# QGL CLI Build

## Purpose

Run QGL (QuickGetLatest) as a true headless CLI process — no GUI window — to build a CW workspace branch locally. This is the autonomous alternative to launching the GUI `Quick Get Latest.exe`.

## Background: Two QGL Binaries

| Binary | Location | Behaviour |
|--------|----------|-----------|
| `Quick Get Latest.exe` | `C:\Program Files (x86)\WiseTech Global\Quick Get Latest\` | Blazor WebView GUI — **always opens a window**, single-instance, ignores `CreateNoWindow` / `-WindowStyle Hidden` |
| `QuickGetLatest.exe` | `C:\Program Files (x86)\WiseTech Global\CrikeyMonitor\QGL\` | True console app — **no window**, safe for autonomous use. Installed by **CrikeyMonitor**, not the GUI installer. |

The CLI exe is installed by CrikeyMonitor at `C:\Program Files (x86)\WiseTech Global\CrikeyMonitor\QGL\QuickGetLatest.exe`. It ships with slightly older DLLs than the GUI installer. Because the GUI and CLI versions may diverge over time, copy the CLI to a local writeable folder and sync DLLs from the GUI before use.

## Configuration

Read settings from:
- `config.yaml`
- `config.local.yaml` (overrides)

Relevant config keys:
- `workspace_root` — root directory of all workspaces
- `standard_workspace` — path to the standard (master-branch) workspace, e.g. `C:\BS\git\GitHub\WiseTechGlobal\CargoWise` (used as the prebuilt DLL cache by QGL `-LocalDependencies`)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `workspacePath` | Yes | — | Root of the CW workspace to build, e.g. `C:\BS\autotask\workspaces\WI00971062\CargoWise` |
| `branch` | Yes | — | Branch to check out and build, e.g. `ABC/WI00971062` |
| `maxThreadCount` | No | `10` | Parallel build thread count |
| `configuration` | No | `Debug` | MSBuild configuration |
| `pullFromOrigin` | No | `master` | Remote branch to merge into the checked-out branch before building |

## Setup: CLI Binary

### Step 1: Check if CrikeyMonitor is installed

The CLI ships with CrikeyMonitor (not the GUI QGL installer). Check the standard path first:

```powershell
$clikeyPath = "C:\Program Files (x86)\WiseTech Global\CrikeyMonitor\QGL\QuickGetLatest.exe"
Test-Path $clikeyPath   # True = already installed, skip to Step 2
```

If not installed, it can also be downloaded from ProGet. The version tag is in `version.txt` at the GUI install folder:
```
DATProduction/CrikeyClient/QGL/QGL-20260209-043543.zip
```
Download and extract to `C:\BS\autotask\tools\QGL-CLI\`.

### Step 2: Copy CLI to a local writeable folder and sync DLLs from GUI

The CrikeyMonitor CLI folder is read-only (system Program Files). Copy it to a local folder so DLLs can be patched. The GUI installer ships a newer version of `QuickGetLatest.Core.dll`; the CLI must use the same version or it crashes with:
```
InvalidOperationException: Sequence contains more than one element
  at BuildStepLoader.LoadResolveDependencyBuildSteps()
```

```powershell
$cliSrc = "C:\Program Files (x86)\WiseTech Global\CrikeyMonitor\QGL"
$cliDst = "C:\BS\autotask\tools\QGL-CLI"
$guiDir = "C:\Program Files (x86)\WiseTech Global\Quick Get Latest"

# One-time copy
if (-not (Test-Path $cliDst)) { New-Item -ItemType Directory -Path $cliDst -Force | Out-Null }
Copy-Item "$cliSrc\*" $cliDst -Recurse -Force

# Sync overlapping DLLs from GUI (GUI is authoritative for shared DLLs)
Get-ChildItem $guiDir -Filter "*.dll" | ForEach-Object {
    $target = Join-Path $cliDst $_.Name
    if (Test-Path $target) { Copy-Item $_.FullName $target -Force }
}

# Verify
(Get-Item "$cliDst\QuickGetLatest.Core.dll").VersionInfo.FileVersion  # Should match GUI version
```

Key DLLs to verify: `QuickGetLatest.Core.dll`, `QuickGetLatest.Common.dll` — versions must match the GUI.

After upgrading the installed GUI QGL, repeat the DLL sync step to keep the local CLI folder current.

### Step 3: Record CLI path

The local copy is the path to use. Optionally record in `config.local.yaml`:
```yaml
qgl_cli_exe: "C:\\BS\\autotask\\tools\\QGL-CLI\\QuickGetLatest.exe"
```

## Execution Steps

### Step 1: VPN Preflight

Invoke the `vpn-preflight` skill. QGL downloads dependency artifacts; VPN must be active.

### Step 2: Pre-kill lingering compiler processes

After any `dotnet build` run, `VBCSCompiler.exe` holds locks on output DLLs. QGL's clean step fails with `UnauthorizedAccess` if these are still running.

```powershell
# Kill VBCSCompiler and any lingering dotnet processes
Get-Process | Where-Object { $_.Name -match "VBCSCompiler|dotnet" } | ForEach-Object {
    Write-Host "Killing PID $($_.Id) ($($_.Name))"
    Stop-Process -Id $_.Id -Force
}
Start-Sleep -Seconds 2
```

### Step 3: Generate a timestamped log path

```powershell
$timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logDir      = "$env:LOCALAPPDATA\WiseTech Global\QuickGetLatest\Logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile     = Join-Path $logDir "QGL4GIT.$timestamp.log"
```

Also write the log path to `qgl-current-log.txt` in the workspace parent so it can be retrieved later:
```powershell
Set-Content -Path (Join-Path (Split-Path $workspacePath) "qgl-current-log.txt") -Value $logFile
```

### Step 4: Run QGL CLI headlessly

```powershell
$qglExe = "C:\BS\autotask\tools\QGL-CLI\QuickGetLatest.exe"   # local copy with synced DLLs

& $qglExe `
    -NoGui `
    -BuildAll `
    "-Dependencies:Rebuild" `
    "-Configuration:$configuration" `
    "-MaxThreadCount:$maxThreadCount" `
    "-GitCheckoutBranch:$branch" `
    "-GitPullFromOrigin:$pullFromOrigin" `
    -RetryDownloadOnTimeoutCount:0 `
    "-GitTarget:$workspacePath" `
    "-OutputLogFile:$logFile"
```

**Flag notes:**
- `-NoGui` — console-only mode; exits without waiting for keypress after completion
- `-BuildAll` — full build (vs `-QuickBuild` which only builds changed projects, less reliable for CI parity)
- `-QuickBuild` — builds only projects with source changes (use when you only want to verify your WI's assemblies compile)
- `-BuildCheckedOut` — dependency build: builds changed projects AND their dependents (intermediate option)
- `-Dependencies:Rebuild` — builds all dependency branches locally using prebuilt DLLs from standard workspace for unchanged projects (equivalent to the older `-LocalDependencies` flag in some versions)
- `-Dependencies:Retrieve` — downloads dependency artifacts from ProGet DAT cache instead of building locally
- `-GitPullFromOrigin:master` — merges latest `origin/master` into the checked-out branch before building
- `-RetryDownloadOnTimeoutCount:0` — don't retry slow artifact downloads (prevents hanging)
- `-GitPullFromOrigin:master` — merges latest `origin/master` into the checked-out branch before building
- `-RetryDownloadOnTimeoutCount:0` — don't retry slow artifact downloads (prevents hanging)

### Step 5: Monitor progress

The log file is written in real-time. Tail it from another shell if you want live output:

```powershell
Get-Content $logFile -Wait -Tail 30
```

Or wait for QGL to exit (it runs synchronously when called this way).

### Step 6: Parse results from log

Key patterns in the QGL log:

| Pattern | Meaning |
|---------|---------|
| `Built: Enterprise.Foo.dll` | Assembly compiled successfully |
| `Build failed: Enterprise.Foo.dll` | Assembly failed — look for error lines nearby |
| `Skipping: Enterprise.Foo.dll` | Assembly skipped (DLL already up-to-date or source unchanged) |
| `Retrieve ...` | Downloading a dependency artifact from ProGet |
| `ExitCode = -1` | Dependency download failed |
| `Path N: Enterprise.Foo.dll` | QGL resolved this assembly to path slot N |

**Parse failures:**
```powershell
$failures = Select-String -Path $logFile -Pattern "Build failed:"
$failures | ForEach-Object { Write-Host $_.Line }
```

**Parse built assemblies:**
```powershell
$built = Select-String -Path $logFile -Pattern "^Built:" | ForEach-Object { $_.Line -replace "^Built:\s*","" }
```

### Step 7: Classify failures

Before treating failures as bugs in your WI:

1. **Check if the failure exists on `master` in the standard workspace** — if yes, it is a pre-existing master bug and NOT your responsibility.
2. **Check if the failing DLL is one of your WI's changed projects** — if not, it may be a dependency/infrastructure issue.

Known recurring pre-existing failures (as of 2026-Q1) that should be ignored:
- `Enterprise.Registry.Business.dll` — `YardDashboard*Registry` types undefined (master regression)
- `CargoWise.ResourceStrings.Cache.Test.dll` — `WTG.NUnit.TestFramework` version mismatch
- `Enterprise.Client.Common.Test.dll` — `TestRequiresAdminPrivileges` ambiguous reference
- `Enterprise.Build.Database.Script.Test.dll` — SQL access level error

### Output

On success, summarise:
```
QGL build complete.
  Log: {logFile}
  Built: {count} assemblies
  Failed: {count} assemblies (list if any)
  Pre-existing master failures: {count} (not our WI)
  WI-owned failures: {count} (need fixing)
```

## Understanding `-Dependencies:Rebuild` Behaviour

This is the most important concept for WI local builds.

**What QGL does with `-Dependencies:Rebuild`:**
1. Determines which projects have source changes vs `master` (via git diff)
2. **Recompiles only the changed projects** from source
3. **Copies prebuilt DLLs from the standard workspace** (`C:\BS\git\GitHub\WiseTechGlobal\CargoWise\Bin\`) for all unchanged projects

**Consequence for WIs that move types between assemblies:**

If your WI adds a type to Assembly A (e.g. `IJobForProfitShare` added to `MasterFiles.Business`) and another of your changed assemblies (Assembly B: `Accounting.Integration`) references it via `TypeForwardedTo`, then Assembly C (`Rating.ProfitShare`) which depends on both may fail to build locally with false errors like:
- `CS0266 Cannot implicitly convert JobHeader to IJobForProfitShare`
- `CS0246 The type 'IJobForProfitShare' could not be found`

These errors occur because QGL copied the **pre-WI master version** of Assembly A from the standard workspace (which doesn't have the new type). They are **not real code bugs** — CI (Crikey) builds everything from scratch in the correct order and will succeed.

**When to trust local QGL vs Crikey CI:**
- Local QGL with `-LocalDependencies` is reliable for WIs that only modify code within existing types/members
- For WIs that **introduce new types**, **move types between assemblies**, or **change interface contracts**, the CI Crikey build is the authoritative check
- If QGL shows errors only in assemblies that you cannot easily build locally (because their deps are from standard workspace), use Crikey CI as verification

## DependencyCache Management

QGL caches downloaded ProGet artifact zips in:
```
C:\Users\{user}\AppData\Local\WiseTech Global\QuickGetLatest\DependencyCache\
```

Each subfolder is a content-hash key. If an artifact is corrupt, has wrong subfolder structure, or is the wrong version, builds will fail with `ExitCode = -1` on the `Retrieve ...` step.

### Diagnosing DependencyCache issues

Match the failing `Retrieve` line to the cache folder:
```
Retrieve WiseTechGlobal/CargoWise.Database/Database (releases/CW20260318), Debug ExitCode = -1
```

Look for the cache entry with a hash that corresponds to this artifact. Check its contents match what `Build.xml` expects (use `Build.xml` to find the expected subfolder layout for the artifact).

Common layout issues:
- **Missing `net48\` or `net8.0\` subfolders** — QGL expects DLLs under framework-specific subdirs; flat layout fails
- **Wrong DLL version** — e.g. `CargoWise.TestFramework.NUnit.Shared.dll` from before a NUnit migration commit

### Fixing a bad cache entry

Copy the correct files from the standard workspace's Bin:
```powershell
$cacheDir = "$env:LOCALAPPDATA\WiseTech Global\QuickGetLatest\DependencyCache"
# Find the relevant cache entry subfolder, then copy correct DLLs into it:
$cacheEntry = Join-Path $cacheDir "<hash-folder>"
Copy-Item "C:\BS\git\GitHub\WiseTechGlobal\CargoWise\Bin\SomeDll.dll" `
          (Join-Path $cacheEntry "net8.0\SomeDll.dll") -Force
```

## Notes

- **One instance at a time**: QGL acquires a workspace lock. Do not run multiple QGL processes against the same workspace simultaneously.
- **Git side-effects**: `-GitPullFromOrigin:master` performs a real `git merge` into the workspace. The workspace's `HEAD` will advance. This does NOT affect the remote (no push).
- **File locks**: Always kill `VBCSCompiler.exe` and any `dotnet` processes before running QGL. Otherwise the clean step fails with `UnauthorizedAccess` on DLL files.
- **Version sync**: After upgrading the installed GUI QGL, repeat the DLL copy procedure (Step 2 of Setup) to keep the CLI in sync.
- **Configuration parameter syntax**: Use colon separators, not equals: `-Configuration:Debug` not `-Configuration=Debug`.
- **Path parameters with spaces**: Wrap in quotes: `"-GitTarget:C:\path with spaces\CargoWise"`.
- **Log default location**: `%LOCALAPPDATA%\WiseTech Global\QuickGetLatest\Logs\` — each run creates a new timestamped `QGL4GIT.*.log`.
- **Build.xml**: QGL's project/solution list and dependency graph comes from `CargoWise\Build.xml`. Entries list which DLLs belong to which solution and which ProGet artifacts to download.
