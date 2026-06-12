<#
.SYNOPSIS
Focus a Windows Terminal tab whose title contains the given job number.

.DESCRIPTION
The dashboard's "Jump to Tab" button previously invoked
`wt.exe -w 0 focus-tab --title "<jobNumber>"`, but `focus-tab` does not
accept `--title`. Passing that malformed action to a running WT instance
could terminate the host window — observed as worker tabs "crashing".

This helper uses UIAutomation to locate the TabItem whose Name contains
the job number and selects it, then brings the hosting WT window to the
foreground. It exits 0 on success and 1 when no match is found.

.PARAMETER JobNumber
Substring to match against tab titles (case-insensitive). The launcher
sets titles like "{icon} {jobNumber} {taskType}", so the raw job number
is a reliable match.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_\-]{3,40}$')]
    [string]$JobNumber
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -Namespace Autotask.Native -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@

$automation = [System.Windows.Automation.AutomationElement]
$root = $automation::RootElement

# WT's hosting window class has changed over releases. Match any top-level
# window whose process is WindowsTerminal.exe to stay version-agnostic.
$wtWindows = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition
) | Where-Object {
    try {
        $procId = $_.Current.ProcessId
        $proc = Get-Process -Id $procId -ErrorAction Stop
        $proc.ProcessName -ieq 'WindowsTerminal'
    } catch {
        $false
    }
}

if (-not $wtWindows) {
    Write-Error "No Windows Terminal windows are running."
    exit 1
}

$tabCondition = New-Object System.Windows.Automation.PropertyCondition(
    $automation::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::TabItem
)

foreach ($wtWindow in $wtWindows) {
    $tabs = $wtWindow.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $tabCondition
    )
    foreach ($tab in $tabs) {
        $name = $tab.Current.Name
        if ($name -and $name.IndexOf($JobNumber, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $selectionItem = $null
            if ($tab.TryGetCurrentPattern(
                    [System.Windows.Automation.SelectionItemPattern]::Pattern,
                    [ref]$selectionItem)) {
                $selectionItem.Select()
            } else {
                $invoke = $null
                if ($tab.TryGetCurrentPattern(
                        [System.Windows.Automation.InvokePattern]::Pattern,
                        [ref]$invoke)) {
                    $invoke.Invoke()
                } else {
                    continue
                }
            }

            $handle = [System.IntPtr]$wtWindow.Current.NativeWindowHandle
            [void][Autotask.Native.Win32]::SetForegroundWindow($handle)
            Write-Output "Focused tab '$name'."
            exit 0
        }
    }
}

Write-Error "No Windows Terminal tab matches '$JobNumber'."
exit 1
