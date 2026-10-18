# Called by the packaged installer after copying the application. Shortcuts and
# uninstall registration belong to Inno Setup; this only persists its option.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallRoot,
    [Parameter(Mandatory)][ValidateSet(0, 1)][int] $StartWithWindows
)

$ErrorActionPreference = 'Stop'
. (Join-Path $InstallRoot 'lib\Settings.ps1')
Set-SettingsPath (Join-Path $InstallRoot 'config\settings.json')
$settings = Get-AppSettings
$settings.StartWithWindows = [bool]$StartWithWindows
Save-AppSettings -Settings $settings
