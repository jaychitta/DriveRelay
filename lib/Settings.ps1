<#
    Settings.ps1  --  central configuration management for DriveRelay.

    Provides persistent global settings for sync timing, settle time,
    safety limits, and system integration.
#>

$script:DefaultRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:SettingsPath = Join-Path $script:DefaultRoot 'config\settings.json'

function Set-SettingsPath {
    param([Parameter(Mandatory)][string] $Path)
    $script:SettingsPath = $Path
}

function Get-SettingsPath {
    return $script:SettingsPath
}

function Get-DefaultSettings {
    return [pscustomobject]@{
        IntervalMinutes     = 10
        SettleMinutes       = 3
        MaxDelete           = 50
        HydrateBeforeDelete = $true
        StartWithWindows    = $true
        StartDelaySeconds   = 90

        # What reaches driverelay.log, and how much of it is kept.
        #
        # A pass every ten minutes over three links wrote five lines whether or
        # not anything moved, which buried the lines that mattered. At INFO the
        # log records changes; DEBUG restores the per-file and per-pass detail
        # when something needs diagnosing.
        LogLevel            = 'INFO'
        LogMaxSizeMB        = 1
        LogKeepFiles        = 3

        # Global "stop touching my files for a bit", set from the tray menu.
        # Persisted rather than held in the tray process, so a reboot or a tray
        # restart does not silently resume syncing behind the user's back.
        Paused              = $false
    }
}

function Get-AppSettings {
    $defaults = Get-DefaultSettings

    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        Save-AppSettings -Settings $defaults
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Save-AppSettings -Settings $defaults
            return $defaults
        }

        $parsed = ConvertFrom-Json -InputObject $raw

        # Ensure all required properties are present with fallbacks.
        $intervalMinutes = if ($parsed.PSObject.Properties['IntervalMinutes'] -and $parsed.IntervalMinutes -gt 0) {
            [int]$parsed.IntervalMinutes
        } else { $defaults.IntervalMinutes }

        $settleMinutes = if ($parsed.PSObject.Properties['SettleMinutes'] -and $parsed.SettleMinutes -ge 0) {
            [int]$parsed.SettleMinutes
        } else { $defaults.SettleMinutes }

        $maxDelete = if ($parsed.PSObject.Properties['MaxDelete'] -and $parsed.MaxDelete -ge 0) {
            [int]$parsed.MaxDelete
        } else { $defaults.MaxDelete }

        $hydrateBeforeDelete = if ($parsed.PSObject.Properties['HydrateBeforeDelete'] -ne $null) {
            [bool]$parsed.HydrateBeforeDelete
        } else { $defaults.HydrateBeforeDelete }

        $startWithWindows = if ($parsed.PSObject.Properties['StartWithWindows'] -ne $null) {
            [bool]$parsed.StartWithWindows
        } else { $defaults.StartWithWindows }

        $startDelaySeconds = if ($parsed.PSObject.Properties['StartDelaySeconds'] -and $parsed.StartDelaySeconds -ge 0) {
            [int]$parsed.StartDelaySeconds
        } else { $defaults.StartDelaySeconds }

        # An unrecognised level falls back to the default rather than being
        # passed through: a typo must not silently switch the log off.
        $logLevel = if ($parsed.PSObject.Properties['LogLevel'] -and
                        @('DEBUG', 'INFO', 'WARN', 'ERROR') -contains ([string]$parsed.LogLevel).Trim().ToUpperInvariant()) {
            ([string]$parsed.LogLevel).Trim().ToUpperInvariant()
        } else { $defaults.LogLevel }

        $logMaxSizeMB = if ($parsed.PSObject.Properties['LogMaxSizeMB'] -and $parsed.LogMaxSizeMB -gt 0) {
            [double]$parsed.LogMaxSizeMB
        } else { $defaults.LogMaxSizeMB }

        $logKeepFiles = if ($parsed.PSObject.Properties['LogKeepFiles'] -and $parsed.LogKeepFiles -ge 0) {
            [int]$parsed.LogKeepFiles
        } else { $defaults.LogKeepFiles }

        # Absent in settings files written before pausing was persisted, which
        # must read as "not paused" rather than as missing.
        $paused = if ($null -ne $parsed.PSObject.Properties['Paused']) {
            [bool]$parsed.Paused
        } else { $defaults.Paused }

        return [pscustomobject]@{
            IntervalMinutes     = $intervalMinutes
            SettleMinutes       = $settleMinutes
            MaxDelete           = $maxDelete
            HydrateBeforeDelete = $hydrateBeforeDelete
            StartWithWindows    = $startWithWindows
            StartDelaySeconds   = $startDelaySeconds
            LogLevel            = $logLevel
            LogMaxSizeMB        = $logMaxSizeMB
            LogKeepFiles        = $logKeepFiles
            Paused              = $paused
        }
    }
    catch {
        return $defaults
    }
}

function Initialize-LoggingFromSettings {
    <#
        Apply the persisted log level and rotation policy to Logging.ps1.

        Called by every entry point after Set-SettingsPath, so the CLI, the tray
        and the dashboard -- which all append to the same file -- agree on what
        goes into it. Best-effort: a settings file that cannot be read must not
        stop the process from starting.
    #>
    try {
        $s = Get-AppSettings
        Set-LogLevel    $s.LogLevel
        Set-LogRotation -MaxSizeMB $s.LogMaxSizeMB -Keep $s.LogKeepFiles
    }
    catch { }
}

function Save-AppSettings {
    param([Parameter(Mandatory)][object] $Settings)

    $dir = Split-Path -Parent $script:SettingsPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject $Settings -Depth 4
    $tmp = "$script:SettingsPath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:SettingsPath -Force
}

function Set-AppSetting {
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)]$Value
    )

    $current = Get-AppSettings
    if ($current.PSObject.Properties[$Key]) {
        $current.$Key = $Value
    }
    else {
        $current | Add-Member -NotePropertyName $Key -NotePropertyValue $Value
    }
    Save-AppSettings -Settings $current
    return $current
}
