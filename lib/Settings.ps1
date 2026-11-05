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
        LogMaxAgeDays       = 60

        # Global "stop touching my files for a bit", set from the tray menu.
        # Persisted rather than held in the tray process, so a reboot or a tray
        # restart does not silently resume syncing behind the user's back.
        Paused              = $false
    }
}

# Every settings change is read-modify-write, made by the CLI, the tray (pause)
# and the dashboard. Without a lock one process's change is lost when another
# writes the copy it read earlier.
$script:SettingsMutexName = 'Global\DriveRelaySettings'

function ConvertTo-SettingInt {
    # Accept a whole number at or above $Min; anything else -- a string such as
    # "ten", a fraction, a negative -- falls back to that one field's default.
    param($Value, [int] $Default, [int] $Min = 0)
    $n = 0
    if ($null -ne $Value -and
        [int]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
        $n -ge $Min) { return $n }
    return $Default
}

function ConvertTo-SettingDouble {
    param($Value, [double] $Default, [double] $MinExclusive = 0)
    $n = 0.0
    if ($null -ne $Value -and
        [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
        $n -gt $MinExclusive) { return $n }
    return $Default
}

function ConvertTo-SettingBool {
    # [bool]"false" is $true in PowerShell; a hand-edited "false" must not
    # switch a safety option on, or "Paused": "false" pause syncing.
    param($Value, [bool] $Default)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        if ($Value.Trim() -ieq 'true')  { return $true }
        if ($Value.Trim() -ieq 'false') { return $false }
    }
    return $Default
}

function Read-SharedTextFile {
    <#
        Read a whole UTF-8 file while letting its writer replace it.

        Writers swap state files in with File.Replace, which renames the old
        file away; Windows refuses that while any reader holds the file
        without FILE_SHARE_DELETE -- which Get-Content and File.ReadAllText do
        not grant. The dashboard reads every manifest every few seconds, so a
        pass could fail to save its manifest after it had already copied files.
        Opening with ReadWrite and Delete sharing lets the replace go ahead;
        this reader simply finishes reading the old version.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream -ArgumentList $full, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), $share
    try {
        $reader = New-Object System.IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::UTF8), $true
        return $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
}

function Read-AppSettingsFile {
    <#
        Read without writing. Returns the validated settings and whether the
        file existed but could not be parsed (so a writer can keep a copy of it
        rather than silently replacing it). Each field is validated on its
        own: one bad value costs that value, not the whole file.
    #>
    $defaults = Get-DefaultSettings
    $result = [pscustomobject]@{ Settings = $defaults; Exists = $false; Corrupt = $false }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $result }
    $result.Exists = $true

    # Another process's atomic replace can briefly hold the file. Retry rather
    # than read "not there" -- which would mean "not paused".
    $raw = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try { $raw = Read-SharedTextFile -Path $script:SettingsPath; break }
        catch {
            if ($attempt -eq 10) { throw ("Could not read settings file {0}: {1}" -f $script:SettingsPath, $_.Exception.Message) }
            Start-Sleep -Milliseconds 200
        }
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { $result.Corrupt = $true; return $result }

    try { $parsed = ConvertFrom-Json -InputObject $raw }
    catch { $result.Corrupt = $true; return $result }
    if ($null -eq $parsed -or $parsed -is [System.Array]) { $result.Corrupt = $true; return $result }

    $get = { param($name) if ($parsed.PSObject.Properties[$name]) { $parsed.$name } else { $null } }

    # An unrecognised level falls back to the default rather than being
    # passed through: a typo must not silently switch the log off.
    $level = ([string](& $get 'LogLevel')).Trim().ToUpperInvariant()
    if (@('DEBUG', 'INFO', 'WARN', 'ERROR') -notcontains $level) { $level = $defaults.LogLevel }

    $result.Settings = [pscustomobject]@{
        IntervalMinutes     = ConvertTo-SettingInt    (& $get 'IntervalMinutes')     $defaults.IntervalMinutes 1
        SettleMinutes       = ConvertTo-SettingInt    (& $get 'SettleMinutes')       $defaults.SettleMinutes 0
        MaxDelete           = ConvertTo-SettingInt    (& $get 'MaxDelete')           $defaults.MaxDelete 0
        HydrateBeforeDelete = ConvertTo-SettingBool   (& $get 'HydrateBeforeDelete') $defaults.HydrateBeforeDelete
        StartWithWindows    = ConvertTo-SettingBool   (& $get 'StartWithWindows')    $defaults.StartWithWindows
        StartDelaySeconds   = ConvertTo-SettingInt    (& $get 'StartDelaySeconds')   $defaults.StartDelaySeconds 0
        LogLevel            = $level
        LogMaxSizeMB        = ConvertTo-SettingDouble (& $get 'LogMaxSizeMB')        $defaults.LogMaxSizeMB 0
        LogKeepFiles        = ConvertTo-SettingInt    (& $get 'LogKeepFiles')        $defaults.LogKeepFiles 0
        # 0 disables the age cap (Keep is then the only limit).
        LogMaxAgeDays       = ConvertTo-SettingInt    (& $get 'LogMaxAgeDays')       $defaults.LogMaxAgeDays 0
        # Absent in files written before pausing was persisted: "not paused".
        Paused              = ConvertTo-SettingBool   (& $get 'Paused')              $defaults.Paused
    }
    return $result
}

function Get-AppSettings {
    <#
        The current settings, validated field by field. Never writes: a missing
        or unreadable file reads as defaults and is left as it is.
    #>
    return (Read-AppSettingsFile).Settings
}

function Invoke-SettingsTransaction {
    # Run $Body holding the settings lock. Re-entrant for the owning thread.
    param([Parameter(Mandatory)][scriptblock] $Body, [int] $TimeoutMs = 5000)
    $mutex = New-Object System.Threading.Mutex($false, $script:SettingsMutexName)
    $held = $false
    try {
        try   { $held = $mutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for the settings lock; nothing was changed.' }
        return (& $Body)
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Update-AppSettings {
    <#
        The way to change settings: read the current file, apply $Change to it,
        and save, all under the settings lock. $Change receives the settings
        object and edits it in place. Returns the saved settings.
    #>
    param([Parameter(Mandatory)][scriptblock] $Change)
    return Invoke-SettingsTransaction {
        $current = Read-AppSettingsFile
        $settings = $current.Settings
        $null = & $Change $settings
        Save-AppSettings -Settings $settings -Replacing:$current.Corrupt
        $settings
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
        Set-LogRotation -MaxSizeMB $s.LogMaxSizeMB -Keep $s.LogKeepFiles -MaxAgeDays $s.LogMaxAgeDays
    }
    catch { }
}

function Save-AppSettings {
    <#
        Write the whole settings object, atomically, under the settings lock.
        Prefer Update-AppSettings for changes: this replaces every field.
        -Replacing keeps a copy of an unparseable file before overwriting it.
    #>
    param([Parameter(Mandatory)][object] $Settings,
          [switch] $Replacing)

    $null = Invoke-SettingsTransaction {
        $dir = Split-Path -Parent $script:SettingsPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:SettingsPath)

        if ($Replacing -and [IO.File]::Exists($full)) {
            $kept = "{0}.unreadable-{1}" -f $full, (Get-Date -Format 'yyyyMMdd-HHmmss')
            [IO.File]::Copy($full, $kept, $true)
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("settings file could not be parsed; kept a copy as {0}" -f $kept) 'WARN'
            }
        }

        $json = ConvertTo-Json -InputObject $Settings -Depth 4
        # A per-writer temp name: two writers never share one half-written file.
        $tmp = "{0}.{1}.tmp" -f $full, [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding -ArgumentList $true))
        # Replace is atomic: a reader never sees the file missing, which would
        # read as defaults -- including "not paused".
        if ([IO.File]::Exists($full)) { [IO.File]::Replace($tmp, $full, $null) }
        else                          { [IO.File]::Move($tmp, $full) }
    }
}

function Set-AppSetting {
    param(
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)]$Value
    )

    return Update-AppSettings -Change {
        param($s)
        if ($s.PSObject.Properties[$Key]) { $s.$Key = $Value }
        else { $s | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
    }.GetNewClosure()
}
