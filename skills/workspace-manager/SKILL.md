# Workspace Manager

## Purpose

Manage per-work-item workspaces: create isolated repo clones, reuse existing workspaces, clean up completed ones, and list all workspaces with their status.

## Configuration

Read settings from:
- `config.yaml`
- `config.local.yaml` (overrides)

Relevant config keys:
- `workspace_root` -- directory where all workspaces live (e.g., `.\workspaces`)
- `git_source_root` -- local path to source repos for cloning (e.g., `..\Git\GitHub\WiseTechGlobal`)
- `product_repo_mapping` -- mapping of product name to list of repos to clone (e.g., `Forwarding: [CargoWise, Glow, Glow.CargoWiseOne]`)
- `state_file` -- path to temp/state.json (default: `temp/state.json`)

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `operation` | Yes | -- | One of: `create`, `reuse`, `cleanup`, `cleanup-all-completed`, `list` |
| `jobNumber` | Depends | -- | Required for `create`, `reuse`, `cleanup`. The work item / job number (e.g., `WI-12345`) |
| `product` | Depends | -- | Required for `create`. Product name to determine which repos to clone (e.g., `Forwarding`) |
| `description` | No | -- | Optional short description appended to branch name for readability (e.g., `fix-rate-calc`) |

## Operations

### create(jobNumber, product)

Create a new isolated workspace for a work item.

#### Step 1: Validate Inputs

- `jobNumber` and `product` are required. If missing, print error and stop.
- Look up `product` in `product_repo_mapping` from config. If not found, print available products and stop.

#### Step 2: Create Workspace Directory

```bash
mkdir -p "${WORKSPACE_ROOT}/${JOB_NUMBER}"
```

If the directory already exists, warn the user and ask whether to reuse or overwrite.

#### Step 3: Shallow-Clone Repos

For each repo in the product's repo list, shallow-clone from the local source:

```bash
for repo in ${REPO_LIST}; do
    echo "--- Cloning $repo ---"
    git clone --depth 1 --single-branch --branch master "file://${GIT_SOURCE_ROOT}/${repo}" "${WORKSPACE_ROOT}/${JOB_NUMBER}/${repo}" 2>&1
    if [ $? -ne 0 ]; then
        echo "CLONE FAILED: $repo"
        exit 1
    fi
done
```

Using `file://` protocol with local repos is fast and avoids network overhead. The `--depth 1 --single-branch` flags minimize disk usage.

#### Step 4: Create Feature Branches

Create `{<staff_code>}/{jobNumber}` branches (with optional description suffix) in each cloned repo, replacing `<staff_code>` with the actual staff code prefix used in branch naming (e.g., ABC):

```bash
BRANCH_NAME="<staff_code>/${JOB_NUMBER}"
if [ -n "${DESCRIPTION}" ]; then
    BRANCH_NAME="<staff_code>/${JOB_NUMBER}-${DESCRIPTION}"
fi

for repo in ${REPO_LIST}; do
    echo "--- Creating branch ${BRANCH_NAME} in $repo ---"
    git -C "${WORKSPACE_ROOT}/${JOB_NUMBER}/${repo}" checkout -b "${BRANCH_NAME}" 2>&1
done
```

#### Step 5: Update State

Read `temp/state.json`, add or update the worker entry for this jobNumber:

```json
{
  "jobNumber": "WI-12345",
  "product": "Forwarding",
  "branch": "<staff_code>/WI-12345-fix-rate-calc",
  "workspacePath": ".\workspaces\WI-12345",
  "status": "active",
  "createdAt": "2026-03-21T10:00:00Z",
  "repos": ["CargoWise", "Glow", "Glow.CargoWiseOne"]
}
```

Write the updated temp/state.json back.

#### Output

```
Workspace created: {WORKSPACE_ROOT}/{JOB_NUMBER}
Branch: {BRANCH_NAME}
Repos: {comma-separated list}
```

---

### reuse(jobNumber)

Check if an existing workspace can be reused.

#### Step 1: Check Workspace Exists

```bash
if [ -d "${WORKSPACE_ROOT}/${JOB_NUMBER}" ]; then
    echo "Workspace found: ${WORKSPACE_ROOT}/${JOB_NUMBER}"
else
    echo "No workspace found for ${JOB_NUMBER}"
    exit 1
fi
```

#### Step 2: Verify Branches

For each repo in the workspace, verify the feature branch exists and is checked out, replace <staff_code> with the actual staff code prefix used in branch naming (e.g., ABC):

```bash
for repo in $(ls "${WORKSPACE_ROOT}/${JOB_NUMBER}"); do
    if [ -d "${WORKSPACE_ROOT}/${JOB_NUMBER}/${repo}/.git" ]; then
        currentBranch=$(git -C "${WORKSPACE_ROOT}/${JOB_NUMBER}/${repo}" rev-parse --abbrev-ref HEAD)
        echo "${repo}: on branch ${currentBranch}"
        if [[ ! "$currentBranch" == <staff_code>/${JOB_NUMBER}* ]]; then
            echo "WARN: ${repo} is not on the expected <staff_code> branch"
        fi
    fi
done
```

#### Step 3: Update State

Update the worker entry's `status` to `active` and set `lastAccessedAt` timestamp.

#### Output

```
Workspace reused: {WORKSPACE_ROOT}/{JOB_NUMBER}
```
Return the workspace path to the caller.

---

### cleanup(jobNumber)

Delete a workspace and update state.

#### Step 1: Delete Workspace Directory

```bash
if [ -d "${WORKSPACE_ROOT}/${JOB_NUMBER}" ]; then
    rm -rf "${WORKSPACE_ROOT}/${JOB_NUMBER}"
    echo "Deleted workspace: ${WORKSPACE_ROOT}/${JOB_NUMBER}"
else
    echo "No workspace found for ${JOB_NUMBER}"
fi
```

#### Step 2: Update State

Remove the worker entry for this jobNumber from `temp/state.json`.

#### Output

```
Workspace cleaned up: {JOB_NUMBER}
```

---

### cleanup-all-completed()

Delete all workspaces whose status is `completed` in temp/state.json.

#### Step 1: Read State

Read `temp/state.json` and find all entries with `"status": "completed"`.

#### Step 2: Delete Each

```bash
for workspace in ${COMPLETED_WORKSPACES}; do
    rm -rf "${workspace}"
    echo "Deleted: ${workspace}"
done
```

#### Step 3: Update State

Remove all completed entries from `temp/state.json`.

#### Output

```
Cleaned up {count} completed workspaces.
```

---

### list()

List all workspaces with disk usage and status.

#### Step 1: Read State and Disk Usage

```bash
powershell -NoProfile -Command "
$stateFile = 'temp/state.json'
$state = Get-Content $stateFile | ConvertFrom-Json
foreach ($worker in $state.workers) {
    $path = $worker.workspacePath
    if (Test-Path $path) {
        $size = (Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 1)
        Write-Output ('{0} | {1} | {2} MB | {3}' -f $worker.jobNumber, $worker.status, $sizeMB, $worker.branch)
    } else {
        Write-Output ('{0} | {1} | MISSING | {2}' -f $worker.jobNumber, $worker.status, $worker.branch)
    }
}
"
```

#### Output

A table:
```
Job Number  | Status    | Disk Usage | Branch
------------|-----------|------------|-------
WI-12345    | active    | 1240.5 MB  | <staff_code>/WI-12345-fix-rate-calc
WI-67890    | completed | 980.2 MB   | <staff_code>/WI-67890-add-field
```

## Notes

- Shallow clones (`--depth 1`) keep workspace creation fast. If deeper history is needed later, use `git fetch --unshallow` in the specific repo.
- The `file://` clone protocol avoids GitHub rate limits and is nearly instant for local repos.
- `temp/state.json` is the single source of truth for workspace tracking. Always read-modify-write it atomically (read, parse, modify in memory, write back).
- Branch naming convention `<staff_code>/{jobNumber}` is required by the WTG workflow. The optional description suffix is for human readability only.
- When deleting workspaces, use `rm -rf` carefully. The skill always operates under `workspace_root` and never deletes outside it.
