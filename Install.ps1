<#
    Install.ps1  --  set up DriveRelay to start with Windows.

    What it does, all under your own user account:

      1. Ensures the icon files exist.
      2. Builds a tiny branded DriveRelay.exe launcher using Windows' built-in
         .NET Framework compiler. It starts PowerShell without a console window
         and gives Task Manager's Startup apps entry the DriveRelay name.
      3. Puts a shortcut in Startup, so the tray comes back after every reboot.
      4. Puts a shortcut in the Start Menu, so it can be started by hand.

    No administrator rights, no services, no registry beyond what a shortcut
    implies. Uninstall.ps1 reverses all of it.

    If a scheduled task from the earlier command-line setup exists, it is
    removed: the tray agent runs the passes now, and two schedulers driving the
    same links would just get in each other's way.
#>

[CmdletBinding()]
param(
    # Minutes between automatic passes.
    [int] $IntervalMinutes = 10,

    # Skip the Startup shortcut if you would rather launch it yourself.
    [switch] $NoAutoStart
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# A partial extraction must fail here, with the missing names, before anything
# is installed -- not later as a tray agent that dies invisibly at logon.
$required = @(
    'DriveRelay.ps1', 'DriveRelayTray.ps1', 'DriveRelayUI.ps1', 'config\excludes.txt',
    'tools\New-Launcher.ps1', 'tools\DriveRelayLauncher.cs', 'tools\New-Icons.ps1'
) + @('Actions', 'Availability', 'Conflicts', 'DashboardScan', 'FileIdentity', 'Hydration',
      'Icons', 'Logging', 'LogViewer', 'Manifest', 'Pass', 'Provider', 'Registry',
      'Settings', 'Settle', 'Startup' | ForEach-Object { "lib\$_.ps1" })
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missing.Count -gt 0) {
    throw ("These files are missing from {0}: {1}. Extract the whole DriveRelay folder again; nothing was installed." -f
           $root, ($missing -join ', '))
}

. (Join-Path $root 'lib\Settings.ps1')
. (Join-Path $root 'lib\Startup.ps1')
Set-SettingsPath (Join-Path $root 'config\settings.json')

# Settings are saved at the end, once the launcher and shortcuts exist, so a
# failed install does not leave StartWithWindows claiming a shortcut that was
# never made. Only an explicitly typed interval is written.
$typedInterval = $PSBoundParameters.ContainsKey('IntervalMinutes')
if ($typedInterval -and $IntervalMinutes -lt 1) {
    throw ("-IntervalMinutes must be at least 1 (got {0}); nothing was installed." -f $IntervalMinutes)
}

$appName    = 'DriveRelay'
$assets     = Join-Path $root 'assets'
$iconPath   = Join-Path $assets 'DriveRelay.ico'
if (-not (Test-Path $iconPath)) { $iconPath = Join-Path $root 'DriveRelay.ico' }
$trayScript = Join-Path $root 'DriveRelayTray.ps1'
$uiScript   = Join-Path $root 'DriveRelayUI.ps1'
$launcher   = Join-Path $root 'DriveRelay.exe'

Write-Host "Installing $appName"
Write-Host "  from $root"
Write-Host ''

# --- 1. icons --------------------------------------------------------------

if (-not (Test-Path $iconPath)) {
    Write-Host 'Drawing icons...'
    & (Join-Path $root 'tools\New-Icons.ps1') | Out-Null
}
if (-not (Test-Path $iconPath)) { throw "Icon was not created: $iconPath" }
Write-Host "  $iconPath"

# --- 2. hidden launcher ----------------------------------------------------

& (Join-Path $root 'tools\New-Launcher.ps1') -OutputPath $launcher -IconPath $iconPath
Write-Host "  $launcher"

# --- 3. shortcuts ----------------------------------------------------------

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Target,
        [string] $Arguments = '',
        [string] $Icon,
        [string] $Description
    )
    New-DriveRelayShortcut -Path $Path -Target $Target -WorkingDirectory $root `
                           -Arguments $Arguments -Icon $Icon -Description $Description
}

$startupDir   = [Environment]::GetFolderPath('Startup')
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) $appName

Write-Host 'Creating shortcuts...'

# Clean up legacy Sync Orchestrator shortcuts if present.
$oldStartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Sync Orchestrator'
if (Test-Path $oldStartMenu) { Remove-Item -LiteralPath $oldStartMenu -Recurse -Force -ErrorAction SilentlyContinue }
$oldStartup = Join-Path $startupDir 'Sync Orchestrator.lnk'
if (Test-Path $oldStartup) { Remove-Item -LiteralPath $oldStartup -Force -ErrorAction SilentlyContinue }

New-Shortcut -Path (Join-Path $startMenuDir "$appName.lnk") `
             -Target $launcher `
             -Icon $iconPath -Description 'Start the DriveRelay tray agent'
Write-Host ("  Start Menu: {0}" -f (Join-Path $startMenuDir "$appName.lnk"))

New-Shortcut -Path (Join-Path $startMenuDir "$appName Dashboard.lnk") `
             -Target 'powershell.exe' `
             -Arguments ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $uiScript) `
             -Icon $iconPath -Description 'Manage synced folders'
Write-Host ("  Start Menu: {0}" -f (Join-Path $startMenuDir "$appName Dashboard.lnk"))

# Same helper the dashboard's "Start with Windows" setting uses.
$startupShortcut = Set-StartupShortcut -Enabled (-not $NoAutoStart) -Root $root
if (-not $NoAutoStart) { Write-Host ("  Startup:    {0}" -f $startupShortcut) }
else                   { Write-Host '  Startup:    skipped (-NoAutoStart)' }

# --- 4. retire the scheduled task -----------------------------------------

foreach ($tname in @('DriveRelay', 'SyncOrchestrator')) {
    $task = Get-ScheduledTask -TaskName $tname -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $tname -Confirm:$false
        Write-Host "Removed old scheduled task ($tname) -- the tray agent runs passes now."
    }
}

$appSettings = Update-AppSettings -Change {
    param($st)
    if ($typedInterval) { $st.IntervalMinutes = $IntervalMinutes }
    $st.StartWithWindows = (-not $NoAutoStart)
}

Write-Host ''
# Report the interval actually in effect, not the parameter default. -IntervalMinutes
# is only written to settings when it was explicitly passed, so someone who set 30
# minutes earlier and reinstalls keeps 30 -- and used to be told it was 10.
Write-Host ("Installed. A pass runs every {0} minute(s) while you are signed in." -f $appSettings.IntervalMinutes)
Write-Host ("The first pass waits {0} seconds after logon, so the machine can finish" -f $appSettings.StartDelaySeconds)
Write-Host 'starting and your cloud client can mount its folders first.'
if ($appSettings.Paused) {
    Write-Host ''
    Write-Host 'Note: syncing is currently PAUSED in settings. The tray will start paused;'
    Write-Host 'use "Resume syncing" from its menu when you want passes to run.'
}
Write-Host ''
Write-Host 'Start it now with:'
Write-Host ("  & `"{0}`"" -f $launcher)
Write-Host ''
Write-Host 'Note: Windows 11 hides new tray icons by default. If you do not see it by'
Write-Host 'the clock, click the chevron next to the clock -- it will be in there. To'
Write-Host 'keep it visible, drag it onto the taskbar, or turn it on under'
Write-Host 'Settings > Personalization > Taskbar > Other system tray icons.'
