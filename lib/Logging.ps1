<#
    Logging.ps1  --  shared logging for DriveRelay.

    Extracted from OneDriveGate.ps1 so both it and DriveRelay.ps1 write the same
    line format and share the same rotation behaviour.

    Three things keep the log readable over months of unattended running:

      * A severity threshold. Per-file and per-pass bookkeeping is written at
        DEBUG and suppressed by default, so the log records what changed rather
        than what was checked.
      * Generational rotation. The active log is renamed aside at a size cap and
        a fixed number of older generations is kept, so history survives instead
        of being truncated away, and rotation is a rename rather than a rewrite
        of the whole file on every subsequent write.
      * An age cap on top of that. A quiet link can go a long time without
        hitting the size cap, so a rotated generation is also deleted once it
        is older than LogMaxAgeDays, regardless of how few generations that is.
        Only rotated generations are ever aged out this way -- the active log
        itself is never deleted out from under a running process.

    Logging must never take a caller down: every failure here is swallowed.
#>

# Set by the caller before first use; each component keeps its own log.
$script:DefaultRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:LogPath     = Join-Path $script:DefaultRoot 'driverelay.log'

# Ordered by severity. Anything below the active threshold is dropped before it
# reaches the file.
#
# Named LogThreshold rather than LogLevel, and LogAgeCapDays rather than
# LogMaxAgeDays, on purpose. This file is dot-sourced into DriveRelay.ps1, so
# "$script:" here is that script's own scope -- a state variable sharing a name
# with one of the CLI's parameters would quietly overwrite the value the caller
# typed the moment Initialize-LoggingFromSettings ran, before the command even
# looked at what was typed.
$script:LogLevelRanks = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
$script:LogThreshold  = 'INFO'

$script:LogMaxBytes   = 1MB
$script:LogKeep       = 3
$script:LogAgeCapDays = 60

function Set-LogPath {
    param([Parameter(Mandatory)][string] $Path)
    $script:LogPath = $Path
    $script:LogLastPurge = [datetime]::MinValue
}

function Get-LogPath { return $script:LogPath }

function Set-LogLevel {
    <#
        Accepts DEBUG, INFO, WARN or ERROR. An unrecognised value leaves the
        current threshold alone: a typo in settings.json must not silently
        switch the log off.
    #>
    param([Parameter(Mandatory)][string] $Level)

    $candidate = $Level.Trim().ToUpperInvariant()
    if ($script:LogLevelRanks.ContainsKey($candidate)) { $script:LogThreshold = $candidate }
}

function Get-LogLevel { return $script:LogThreshold }

function Set-LogRotation {
    <#
        MaxSizeMB is the size at which the active log is rotated aside.
        Keep is how many older generations are retained (driverelay.1.log ..
        driverelay.<Keep>.log). Keep = 0 discards on rotation.
        MaxAgeDays is how long a rotated generation is kept before it is
        deleted outright, independent of Keep. MaxAgeDays = 0 disables the
        age cap -- Keep is then the only limit, as before this existed.
    #>
    param(
        [double] $MaxSizeMB,
        [int]    $Keep = -1,
        [int]    $MaxAgeDays = -1
    )

    if ($MaxSizeMB -gt 0)  { $script:LogMaxBytes   = [long]($MaxSizeMB * 1MB) }
    if ($Keep -ge 0)       { $script:LogKeep       = $Keep }
    if ($MaxAgeDays -ge 0) { $script:LogAgeCapDays = $MaxAgeDays }
    # A changed policy applies at the next write, not up to an hour later.
    $script:LogLastPurge = [datetime]::MinValue
}

# Rotation renames files several processes share (the tray, the dashboard, the
# child CLI). Two of them rotating at once used to shift the generations twice
# and delete one. A named lock serialises rotation; whoever gets it second
# re-checks the size and finds nothing to do.
$script:LogRotationMutexName = 'Global\DriveRelayLogRotation'
$script:LogLastPurge = [datetime]::MinValue

function Get-LogGenerations {
    # Every rotated generation on disk (driverelay.<n>.log), whatever Keep is
    # now -- lowering LogKeepFiles must not strand the higher-numbered ones.
    $dir  = Split-Path -Parent $script:LogPath
    $base = [IO.Path]::GetFileNameWithoutExtension($script:LogPath)
    $ext  = [IO.Path]::GetExtension($script:LogPath)
    if (-not $dir) { $dir = '.' }
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $pattern = '^' + [regex]::Escape($base) + '\.(\d+)' + [regex]::Escape($ext) + '$'
    $found = foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($f.Name, $pattern, 'IgnoreCase')
        if ($m.Success) { [pscustomobject]@{ N = [int]$m.Groups[1].Value; Path = $f.FullName; Item = $f } }
    }
    return @($found | Sort-Object N)
}

function Invoke-LogAgePurge {
    <#
        Deletes rotated generations older than LogMaxAgeDays, and any numbered
        above LogKeepFiles. Only ever touches rotated generations -- the active
        log is not a candidate.

        A quiet link can sit under the size cap for months, so this cannot run
        only when a rotation happens. It runs at most once an hour per process
        (and always as part of a rotation): a directory listing on every log
        line is not worth it.
    #>
    param([switch] $Force)
    if (-not $Force -and ((Get-Date) - $script:LogLastPurge).TotalMinutes -lt 60) { return }
    $script:LogLastPurge = Get-Date

    try {
        $cutoff = (Get-Date).AddDays(-$script:LogAgeCapDays)
        foreach ($g in (Get-LogGenerations)) {
            $tooOld  = ($script:LogAgeCapDays -gt 0 -and $g.Item.LastWriteTime -lt $cutoff)
            $surplus = ($g.N -gt $script:LogKeep)
            if ($tooOld -or $surplus) {
                Remove-Item -LiteralPath $g.Path -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

function Invoke-LogRotation {
    <#
        Rename the active log aside and shift the older generations down one.
        Best-effort throughout: failing a sync over a log rotation is worse
        than an oversized log.
    #>
    Invoke-LogAgePurge

    try {
        if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
        if ((Get-Item -LiteralPath $script:LogPath).Length -le $script:LogMaxBytes) { return }
    }
    catch { return }

    $mutex = $null
    $held  = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:LogRotationMutexName)
        try   { $held = $mutex.WaitOne(2000) }
        catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return }   # someone else is rotating; the next write re-checks

        # Re-check under the lock: another process may have just rotated.
        if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
        if ((Get-Item -LiteralPath $script:LogPath).Length -le $script:LogMaxBytes) { return }

        $dir  = Split-Path -Parent $script:LogPath
        $base = [IO.Path]::GetFileNameWithoutExtension($script:LogPath)
        $ext  = [IO.Path]::GetExtension($script:LogPath)
        $gen  = { param($n) Join-Path $dir ("{0}.{1}{2}" -f $base, $n, $ext) }

        if ($script:LogKeep -lt 1) {
            Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction Stop
        }
        else {
            # Oldest first, so nothing is overwritten before it has been shifted.
            $oldest = & $gen $script:LogKeep
            if (Test-Path -LiteralPath $oldest) {
                Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue
            }
            for ($n = $script:LogKeep - 1; $n -ge 1; $n--) {
                $from = & $gen $n
                if (Test-Path -LiteralPath $from) {
                    Move-Item -LiteralPath $from -Destination (& $gen ($n + 1)) -Force -ErrorAction SilentlyContinue
                }
            }
            Move-Item -LiteralPath $script:LogPath -Destination (& $gen 1) -Force -ErrorAction Stop
        }
        Invoke-LogAgePurge -Force
    }
    catch { }
    finally {
        if ($held -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # -Verbose still shows everything regardless of the file threshold: when
    # somebody is watching a run by hand they asked for the detail.
    Write-Verbose $line

    if ($script:LogLevelRanks[$Level] -lt $script:LogLevelRanks[$script:LogThreshold]) { return }

    try {
        $dir = Split-Path -Parent $script:LogPath
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        Invoke-LogRotation

        # The tray, the dashboard and the child CLI all write this one file, and
        # Add-Content takes an exclusive write lock. A collision used to be
        # swallowed silently, which quietly lost log lines at exactly the moments
        # the log matters most -- several processes active at once.
        #
        # Retry briefly. Still never throw: logging must not take the caller down.
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try {
                Add-Content -Path $script:LogPath -Value $line -Encoding utf8 -ErrorAction Stop
                return
            }
            catch {
                if ($attempt -lt 3) { Start-Sleep -Milliseconds (30 * ($attempt + 1)) }
            }
        }
    }
    catch {
        # Logging must never take the caller down.
    }
}
