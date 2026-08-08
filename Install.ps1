<#
    Install.ps1  --  set up DriveRelay to start with Windows.

    What it does, all under your own user account:

      1. Ensures the icon files exist.
      2. Writes a tiny .vbs launcher. Windows shortcuts cannot start a process
         truly hidden -- powershell.exe flashes a console window for a moment
         however you set the shortcut. WScript.Shell.Run with a window style of
         0 does not, and it is the standard way to launch a background script.
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

. (Join-Path $root 'lib\Settings.ps1')
Set-SettingsPath (Join-Path $root 'config\settings.json')

$appSettings = Get-AppSettings
if ($PSBoundParameters.ContainsKey('IntervalMinutes')) {
    $appSettings.IntervalMinutes = $IntervalMinutes
}
$appSettings.StartWithWindows = (-not $NoAutoStart)
Save-AppSettings -Settings $appSettings

$appName    = 'DriveRelay'
$assets     = Join-Path $root 'assets'
$iconPath   = Join-Path $assets 'DriveRelay.ico'
if (-not (Test-Path $iconPath)) { $iconPath = Join-Path $root 'DriveRelay.ico' }
$trayScript = Join-Path $root 'DriveRelayTray.ps1'
$uiScript   = Join-Path $root 'DriveRelayUI.ps1'
$launcher   = Join-Path $root 'DriveRelayTray.vbs'

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

$vbs = @"
' Launches the DriveRelay tray agent without a console window.
Dim fso, scriptDir, shell, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\DriveRelayTray.ps1"""
shell.Run cmd, 0, False
"@
Set-Content -LiteralPath $launcher -Value $vbs -Encoding ASCII
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

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath       = $Target
    $sc.Arguments        = $Arguments
    $sc.WorkingDirectory = $root
    $sc.WindowStyle      = 7          # minimised, belt and braces with the .vbs
    if ($Icon)        { $sc.IconLocation = "$Icon,0" }
    if ($Description) { $sc.Description  = $Description }
    $sc.Save()
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
             -Target 'wscript.exe' -Arguments ('"{0}"' -f $launcher) `
             -Icon $iconPath -Description 'Start the DriveRelay tray agent'
Write-Host ("  Start Menu: {0}" -f (Join-Path $startMenuDir "$appName.lnk"))

New-Shortcut -Path (Join-Path $startMenuDir "$appName Dashboard.lnk") `
             -Target 'powershell.exe' `
             -Arguments ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $uiScript) `
             -Icon $iconPath -Description 'Manage synced folders'
Write-Host ("  Start Menu: {0}" -f (Join-Path $startMenuDir "$appName Dashboard.lnk"))

if (-not $NoAutoStart) {
    New-Shortcut -Path (Join-Path $startupDir "$appName.lnk") `
                 -Target 'wscript.exe' -Arguments ('"{0}"' -f $launcher) `
                 -Icon $iconPath -Description 'Start DriveRelay with Windows'
    Write-Host ("  Startup:    {0}" -f (Join-Path $startupDir "$appName.lnk"))
}
else {
    Write-Host '  Startup:    skipped (-NoAutoStart)'
}

# --- 4. retire the scheduled task -----------------------------------------

foreach ($tname in @('DriveRelay', 'SyncOrchestrator')) {
    $task = Get-ScheduledTask -TaskName $tname -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $tname -Confirm:$false
        Write-Host "Removed old scheduled task ($tname) -- the tray agent runs passes now."
    }
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
Write-Host ("  wscript.exe `"{0}`"" -f $launcher)
Write-Host ''
Write-Host 'Note: Windows 11 hides new tray icons by default. If you do not see it by'
Write-Host 'the clock, click the chevron next to the clock -- it will be in there. To'
Write-Host 'keep it visible, drag it onto the taskbar, or turn it on under'
Write-Host 'Settings > Personalization > Taskbar > Other system tray icons.'
