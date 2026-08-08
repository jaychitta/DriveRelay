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

        return [pscustomobject]@{
            IntervalMinutes     = $intervalMinutes
            SettleMinutes       = $settleMinutes
            MaxDelete           = $maxDelete
            HydrateBeforeDelete = $hydrateBeforeDelete
            StartWithWindows    = $startWithWindows
            StartDelaySeconds   = $startDelaySeconds
        }
    }
    catch {
        return $defaults
    }
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
