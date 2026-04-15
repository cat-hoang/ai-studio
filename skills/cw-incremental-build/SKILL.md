# CW Incremental Build

## Purpose

Build only the changed code on top of pre-built Crikey artifacts, rather than performing a full solution build. This dramatically reduces build times for local development and work-item branches.

## Configuration

Read settings from:
- `config.yaml`
- `config.local.yaml` (overrides)

Relevant config keys:
- `workspace_root` -- root directory containing all workspaces
- `product_repo_mapping` -- mapping of product names to repo directories
- `db_upgrade_command` -- database upgrade command template (default: `CargoWise\Bin\CargoWise.WindowsDesktop.exe . Odyssey -ConsoleDbUpgrader -NoSplash`)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `workspacePath` | Yes | -- | Root of the workspace (contains CargoWise, Glow, Glow.CargoWiseOne, etc.) |

## Execution Steps

### Step 1: Ensure Crikey Artifacts Present

Check if `{workspacePath}\CargoWise\Bin\` contains assemblies (at minimum, `CargoWise.WindowsDesktop.exe` or similar key DLLs).

```bash
ls "${WORKSPACE_PATH}/CargoWise/Bin/"*.dll 2>/dev/null | head -5
```

If the directory is empty or missing key assemblies, invoke the `crikey-build-artifacts` skill with the current branch and workspacePath before continuing. That skill should resolve and reuse the shared `artifacts_cache` directory under the Ratatosk repo root rather than downloading to a workspace-local cache. Wait for it to complete.

### Step 2: Merge Latest Master

For each repo directory in the workspace, merge `origin/master` to ensure the branch is up to date:

```bash
for repo in "${WORKSPACE_PATH}/CargoWise" "${WORKSPACE_PATH}/Glow" "${WORKSPACE_PATH}/Glow.CargoWiseOne" "${WORKSPACE_PATH}/NQTN" "${WORKSPACE_PATH}/RateComparator"; do
    if [ -d "$repo/.git" ]; then
        echo "--- Merging origin/master in $(basename $repo) ---"
        git -C "$repo" fetch origin master && git -C "$repo" merge origin/master --no-edit || echo "WARN: merge conflict in $(basename $repo)"
    fi
done
```

If any merge produces conflicts, report the conflicting files and stop. The user must resolve conflicts before proceeding.

### Step 3: Detect Changed Projects

For each repo, identify files changed relative to `origin/master`:

```bash
git -C "${WORKSPACE_PATH}/REPO_NAME" diff --name-only origin/master
```

From the changed file list, determine which `.csproj` files are affected. A file change affects a `.csproj` if:
- The changed file is directly listed in the `.csproj`, OR
- The changed file resides in the same directory (or subdirectory) as the `.csproj`

Collect the unique set of `.csproj` files that need building.

If Ratatosk job context is available, record the targeted scope so later failure analysis can tell whether the build stayed within plan:

```powershell
& "$RATATOSK_ROOT\tools\update-ratatosk-build-plan.ps1" `
  -JobNumber $jobNumber `
  -WorkspacePath $workspacePath `
  -BuildMode 'targeted' `
  -TargetProjects $changedProjects `
  -BuildCommands @('dotnet build --configuration Debug --no-restore') `
  -Notes @('Incremental build based on changed projects relative to origin/master.')
```

If no files have changed in any repo, print "No changes detected. Build skipped." and stop.

### Step 4: Build Changed Projects

Build each changed project using `dotnet build` or `msbuild`. Prefer `dotnet build` when available:

```bash
for proj in ${CHANGED_PROJECTS}; do
    echo "--- Building $proj ---"
    dotnet build "$proj" --configuration Debug --no-restore 2>&1
    if [ $? -ne 0 ]; then
        echo "BUILD FAILED: $proj"
        # Do not stop; collect all failures and report at end
    fi
done
```

If `dotnet build` is not suitable for certain projects (e.g., legacy .NET Framework), use msbuild:

```bash
powershell -NoProfile -Command "& 'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe' 'PROJECT_PATH' /p:Configuration=Debug /v:minimal"
```

Track all build failures. If any project fails to build, report all failures at the end but continue with the projects that did succeed.

If the failures appear to be outside the recorded target projects, stale baseline artifacts, or test infrastructure issues, classify them before finalizing:

```powershell
& "$RATATOSK_ROOT\tools\classify-ratatosk-build-failure.ps1" `
  -JobNumber $jobNumber `
  -WorkspacePath $workspacePath `
  -Phase 'build-verify' `
  -FailureText ($buildFailureLines -join [Environment]::NewLine) `
  -TargetProjects $changedProjects `
  -FailedProjects $failedProjects
```

### Step 5: Copy Build Outputs to CargoWise\Bin

For repos other than CargoWise itself (e.g., Glow, Glow.CargoWiseOne, NQTN, RateComparator), copy their build output DLLs into `CargoWise\Bin\`:

```bash
for repo in Glow Glow.CargoWiseOne NQTN RateComparator; do
    repoPath="${WORKSPACE_PATH}/${repo}"
    if [ -d "$repoPath" ]; then
        echo "--- Copying outputs from $repo ---"
        find "$repoPath" -path "*/bin/Debug/*" -name "*.dll" -exec cp -u {} "${WORKSPACE_PATH}/CargoWise/Bin/" \;
        find "$repoPath" -path "*/bin/Debug/*" -name "*.pdb" -exec cp -u {} "${WORKSPACE_PATH}/CargoWise/Bin/" \;
    fi
done
```

Use `-u` (update) flag so only newer files overwrite existing ones.

### Step 6: Database Upgrade

Run the database upgrader from `CargoWise\Bin\`:

```bash
powershell -NoProfile -Command "
$exe = '${WORKSPACE_PATH}\CargoWise\Bin\CargoWise.WindowsDesktop.exe'
if (Test-Path $exe) {
    & $exe . Odyssey -ConsoleDbUpgrader -NoSplash 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Output 'DB_UPGRADE_FAILED'; exit 1 }
    Write-Output 'DB_UPGRADE_OK'
} else {
    Write-Output 'WARN: CargoWise.WindowsDesktop.exe not found. Skipping DB upgrade.'
}
"
```

If the database upgrade fails, report the error but do not treat it as fatal -- the user may not need DB changes for their work item.

### Step 7: Verify Build Output

Check that key assemblies from changed projects exist in `CargoWise\Bin\`:

```bash
echo "--- Verifying build outputs in CargoWise\Bin ---"
for dll in ${EXPECTED_DLLS}; do
    if [ -f "${WORKSPACE_PATH}/CargoWise/Bin/${dll}" ]; then
        echo "OK: ${dll}"
    else
        echo "MISSING: ${dll}"
    fi
done
```

The expected DLLs are derived from the `.csproj` AssemblyName or project filename for each changed project.

If you run a narrowed test pass after the build, append those test targets with the same helper so Ratatosk retains both the build and test slices in one shared plan record.

### Output

Print a summary:
```
Incremental build complete.
  Changed projects: {count}
  Built successfully: {count}
  Build failures: {count} (list if any)
  DB upgrade: OK/FAILED/SKIPPED
  Missing assemblies: {count} (list if any)
```

## Notes

- This skill assumes Crikey artifacts provide a complete baseline build of `origin/master`. The incremental build only needs to compile the delta.
- If merge conflicts occur in Step 2, the skill stops and reports them. The user (or orchestrator) must resolve before retrying.
- Build failures in one project do not block other projects from building.
- The `find ... -exec cp` pattern in Step 5 is intentionally broad; it copies all DLLs from Debug output. This may copy more than strictly needed but ensures nothing is missed.

