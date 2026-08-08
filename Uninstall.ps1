<#
    Uninstall.ps1  --  undo Install.ps1.

    Removes the shortcuts, the launcher and the generated icons, and stops the
    tray agent if it is running.

    Your files, your links and your sync history are left completely alone.
    config\links.json, state\ and the log stay where they are, so reinstalling
    picks up exactly where you left off. Nothing in either folder of any link
    is touched.
#>

[CmdletBinding()]
param(
    # Also forget the links and sync history. Files on disk are still not
    # touched -- this only discards what the orchestrator remembers.
    [switch] $AlsoRemoveSettings
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$appName  = 'DriveRelay'
$launcher = Join-Path $root 'DriveRelayTray.vbs'

Write-Host "Uninstalling $appName"
Write-Host ''

# --- stop the tray ---------------------------------------------------------

$stopped = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like '*DriveRelayTray.ps1*' -or $_.CommandLine -like '*SyncOrchTray.ps1*') } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -Confirm:$false; $stopped++ } catch { }
    }
if ($stopped -gt 0) { Write-Host "Stopped $stopped running tray agent(s)." }

# --- shortcuts and launcher -----------------------------------------------

$startupDir   = [Environment]::GetFolderPath('Startup')
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) $appName
$oldStartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Sync Orchestrator'

$targets = @(
    (Join-Path $startupDir "$appName.lnk"),
    (Join-Path $startupDir 'Sync Orchestrator.lnk'),
    $startMenuDir,
    $oldStartMenu,
    $launcher,
    (Join-Path $root 'SyncOrchTray.vbs')
)

foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed $t"
    }
}

# --- any leftover scheduled task ------------------------------------------

foreach ($tname in @('DriveRelay', 'SyncOrchestrator')) {
    $task = Get-ScheduledTask -TaskName $tname -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $tname -Confirm:$false
        Write-Host "  removed scheduled task ($tname)"
    }
}

# --- optional: forget settings --------------------------------------------

if ($AlsoRemoveSettings) {
    foreach ($t in @((Join-Path $root 'config\links.json'), (Join-Path $root 'state'))) {
        if (Test-Path -LiteralPath $t) {
            Remove-Item -LiteralPath $t -Recurse -Force
            Write-Host "  removed $t"
        }
    }
    Write-Host ''
    Write-Host 'Links and sync history discarded. No files in any linked folder were touched.'
}

Write-Host ''
Write-Host 'Done. The scripts remain in place; run Install.ps1 to set it up again.'
if (-not $AlsoRemoveSettings) {
    Write-Host 'Your links and sync history were kept.'
}
