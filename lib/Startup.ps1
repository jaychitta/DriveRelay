<#
    Startup.ps1  --  the "start with Windows" shortcut.

    The tray agent starts at logon from a shortcut in the user's Startup
    folder that targets the branded DriveRelay.exe launcher. The installer and
    the dashboard's "Start with Windows" setting both go through these
    functions, so the setting and the shortcut cannot disagree.
#>

$script:StartupShortcutName = 'DriveRelay.lnk'

function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) $script:StartupShortcutName)
}

function Test-StartupShortcut {
    # Whether the tray agent will actually start at the next logon.
    return (Test-Path -LiteralPath (Get-StartupShortcutPath))
}

function New-DriveRelayShortcut {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [string] $Arguments = '',
        [string] $Icon,
        [string] $Description
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath       = $Target
    $sc.Arguments        = $Arguments
    $sc.WorkingDirectory = $WorkingDirectory
    $sc.WindowStyle      = 7
    if ($Icon)        { $sc.IconLocation = "$Icon,0" }
    if ($Description) { $sc.Description  = $Description }
    $sc.Save()
}

function Set-StartupShortcut {
    <#
        Create or remove the Startup shortcut. $Root is the DriveRelay folder;
        the launcher (DriveRelay.exe) must already exist there, which the
        installer guarantees. Throws if the change could not be made, so the
        caller can leave the saved setting as it was.
    #>
    param(
        [Parameter(Mandatory)][bool] $Enabled,
        [Parameter(Mandatory)][string] $Root
    )

    $path = Get-StartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        return $path
    }

    $launcher = Join-Path $Root 'DriveRelay.exe'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw ("The DriveRelay launcher is missing ({0}). Run Setup.cmd once to create it, then turn this on again." -f $launcher)
    }
    $icon = Join-Path $Root 'assets\DriveRelay.ico'
    if (-not (Test-Path -LiteralPath $icon)) { $icon = Join-Path $Root 'DriveRelay.ico' }

    New-DriveRelayShortcut -Path $path -Target $launcher -WorkingDirectory $Root `
                           -Icon $icon -Description 'Start DriveRelay with Windows'
    return $path
}
