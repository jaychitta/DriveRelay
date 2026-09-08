<#
    Logging.ps1  --  shared logging for DriveRelay.

    Extracted from OneDriveGate.ps1 so both it and DriveRelay.ps1 write the same
    line format and share the same rotation behaviour.

    Two things keep the log readable over months of unattended running:

      * A severity threshold. Per-file and per-pass bookkeeping is written at
        DEBUG and suppressed by default, so the log records what changed rather
        than what was checked.
      * Generational rotation. The active log is renamed aside at a size cap and
        a fixed number of older generations is kept, so history survives instead
        of being truncated away, and rotation is a rename rather than a rewrite
        of the whole file on every subsequent write.

    Logging must never take a caller down: every failure here is swallowed.
#>

# Set by the caller before first use; each component keeps its own log.
$script:DefaultRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:LogPath     = Join-Path $script:DefaultRoot 'driverelay.log'

# Ordered by severity. Anything below the active threshold is dropped before it
# reaches the file.
#
# Named LogThreshold rather than LogLevel on purpose. This file is dot-sourced
# into DriveRelay.ps1, so "$script:" here is that script's own scope -- a state
# variable sharing a name with one of its parameters would quietly overwrite the
# value the caller typed.
$script:LogLevelRanks = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
$script:LogThreshold  = 'INFO'

$script:LogMaxBytes = 1MB
$script:LogKeep     = 3

function Set-LogPath {
    param([Parameter(Mandatory)][string] $Path)
    $script:LogPath = $Path
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
    #>
    param(
        [double] $MaxSizeMB,
        [int]    $Keep = -1
    )

    if ($MaxSizeMB -gt 0)  { $script:LogMaxBytes = [long]($MaxSizeMB * 1MB) }
    if ($Keep -ge 0)       { $script:LogKeep     = $Keep }
}

function Invoke-LogRotation {
    <#
        Rename the active log aside and shift the older generations down one.

        Best-effort throughout: if another DriveRelay process is rotating at the
        same moment one of the two loses a rename and the next call retries.
        Losing a rotation is harmless; failing a sync over one is not.
    #>
    try {
        if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
        if ((Get-Item -LiteralPath $script:LogPath).Length -le $script:LogMaxBytes) { return }

        $dir  = Split-Path -Parent $script:LogPath
        $base = [IO.Path]::GetFileNameWithoutExtension($script:LogPath)
        $ext  = [IO.Path]::GetExtension($script:LogPath)
        $gen  = { param($n) Join-Path $dir ("{0}.{1}{2}" -f $base, $n, $ext) }

        if ($script:LogKeep -lt 1) {
            Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction Stop
            return
        }

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
    catch { }
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
