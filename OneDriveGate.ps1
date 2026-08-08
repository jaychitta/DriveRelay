<#
    OneDriveGate.ps1  --  DriveRelay, step 1

    Keeps OneDrive out of the way while you work.

      1. GRACE   -- for $GraceMinutes after this script starts, OneDrive runs untouched.
      2. BLOCKED -- after that, OneDrive is shut down, and shut down again if it relaunches.
      3. RESUMED -- at $ResumeTime, OneDrive is started and left alone for the rest of the run.

    Once resumed it stays resumed for the rest of that day. At midnight the gate
    re-arms: the new day gets its own blocked phase, ending at that day's $ResumeTime.
    The grace period applies only at startup and is not reapplied daily.

    Restarting the script begins the cycle again, grace period included.

    OneDrive exposes no real "pause" to scripts -- only /shutdown and /background --
    so this stops and starts the process rather than pausing it.

    Run:   powershell -ExecutionPolicy Bypass -File .\OneDriveGate.ps1
    Test:  add -WhatIf to log decisions without acting.
#>

[CmdletBinding()]
param(
    # Minutes OneDrive is left alone after this script starts.
    [int]    $GraceMinutes = 10,

    # Time of day OneDrive is switched back on for good. HH:mm.
    [string] $ResumeTime = '17:45',

    # Seconds between checks.
    [int]    $PollSeconds = 30,

    [string] $LogPath = '',

    # Log what would happen, change nothing.
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $LogPath = Join-Path $scriptRoot 'onedrivegate.log'
}

# ---------------------------------------------------------------- logging ---

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line

    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Keep the log from growing without bound: trim to the last 2000 lines at 1 MB.
        if (Test-Path $LogPath) {
            if ((Get-Item $LogPath).Length -gt 1MB) {
                $tail = Get-Content $LogPath -Tail 2000
                Set-Content -Path $LogPath -Value $tail -Encoding utf8
            }
        }

        Add-Content -Path $LogPath -Value $line -Encoding utf8
    }
    catch {
        # Logging must never take the loop down.
    }
}

# ------------------------------------------------------------ onedrive.exe ---

function Get-OneDrivePath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
        'C:\Program Files\Microsoft OneDrive\OneDrive.exe',
        'C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe'
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-OneDriveProcesses {
    try   { return @(Get-Process -Name 'OneDrive' -ErrorAction Stop) }
    catch { return @() }
}

function Stop-OneDrive {
    param([string] $ExePath)

    if ($WhatIf) { Write-Log 'WHATIF: would shut OneDrive down.' 'ACT'; return }

    Write-Log 'Shutting OneDrive down.' 'ACT'
    try {
        & $ExePath /shutdown
        Start-Sleep -Seconds 5
    }
    catch {
        Write-Log ('/shutdown failed: {0}' -f $_.Exception.Message) 'WARN'
    }

    # /shutdown is a request, not a guarantee. Verify, then force.
    $still = Get-OneDriveProcesses
    if ($still.Count -gt 0) {
        Write-Log ('{0} process(es) survived /shutdown; forcing.' -f $still.Count) 'WARN'
        foreach ($p in $still) {
            try { Stop-Process -Id $p.Id -Force -Confirm:$false } catch {}
        }
    }
}

function Start-OneDrive {
    param([string] $ExePath)

    if ($WhatIf) { Write-Log 'WHATIF: would start OneDrive.' 'ACT'; return }

    Write-Log 'Starting OneDrive.' 'ACT'
    try   { Start-Process -FilePath $ExePath -ArgumentList '/background' }
    catch { Write-Log ('Start failed: {0}' -f $_.Exception.Message) 'WARN' }
}

# -------------------------------------------------------------------- main ---

$exe = Get-OneDrivePath
if ($null -eq $exe) {
    Write-Log 'OneDrive.exe not found in any known location. Exiting.' 'ERROR'
    throw 'OneDrive.exe not found.'
}

$resumeSpan = [timespan]::Zero
if (-not [timespan]::TryParse($ResumeTime, [ref] $resumeSpan)) {
    throw ("ResumeTime '{0}' is not a valid time. Use HH:mm, e.g. 17:45." -f $ResumeTime)
}

$scriptStart = Get-Date
$graceEnds   = $scriptStart.AddMinutes($GraceMinutes)

# The resume moment is today's $ResumeTime -- unless we started after it, in which
# case resume is already due and the grace period is the only delay.
#
# Recomputed at each midnight in the loop below. Pinning it to the start date
# meant that on a machine left running for days, the gate resumed once on day one
# and then never blocked again: $resumed latched true permanently and every
# subsequent working day ran with OneDrive untouched. The failure was silent,
# which is the worst kind for something whose whole job is to be in the way.
$resumeAt   = $scriptStart.Date.Add($resumeSpan)
$currentDay = $scriptStart.Date

Write-Log '---------------------------------------------'
Write-Log ('Started. exe={0}' -f $exe)
Write-Log ('Grace {0} min (until {1:HH:mm:ss}), resume at {2:HH:mm}, poll {3}s, whatif={4}' -f `
            $GraceMinutes, $graceEnds, $resumeAt, $PollSeconds, [bool]$WhatIf)

if ($resumeAt -lt $graceEnds) {
    Write-Log 'Resume time already passed at startup; OneDrive will be left running.' 'INFO'
}

$phase   = 'grace'
$resumed = $false

while ($true) {
    try {
        $now     = Get-Date
        $procs   = Get-OneDriveProcesses
        $running = ($procs.Count -gt 0)

        # A new day re-arms the gate. The grace period belongs to startup only,
        # so it is not reapplied -- from midnight the day's blocked phase runs
        # until that day's resume time.
        if ($now.Date -ne $currentDay) {
            $currentDay = $now.Date
            $resumeAt   = $currentDay.Add($resumeSpan)
            $resumed    = $false
            $phase      = 'rollover'
            Write-Log ('New day. Gate re-armed; resume at {0:HH:mm}.' -f $resumeAt) 'INFO'
        }

        # Once resumed, stay resumed for the rest of the day.
        if (-not $resumed -and $now -ge $resumeAt -and $now -ge $graceEnds) {
            $resumed = $true
            Write-Log 'Resume time reached. OneDrive stays on from here.' 'INFO'
        }

        if ($resumed) {
            if ($phase -ne 'resumed') {
                Write-Log ('Phase: resumed (running={0})' -f $running) 'INFO'
                $phase = 'resumed'
            }
            if (-not $running) { Start-OneDrive -ExePath $exe }
        }
        elseif ($now -lt $graceEnds) {
            if ($phase -ne 'grace') {
                Write-Log ('Phase: grace until {0:HH:mm:ss} (running={1})' -f $graceEnds, $running) 'INFO'
                $phase = 'grace'
            }
            # Leave OneDrive alone.
        }
        else {
            if ($phase -ne 'blocked') {
                Write-Log ('Phase: blocked until {0:HH:mm} (running={1})' -f $resumeAt, $running) 'INFO'
                $phase = 'blocked'
            }
            if ($running) {
                Write-Log 'OneDrive is running during blocked phase.' 'INFO'
                Stop-OneDrive -ExePath $exe
            }
        }
    }
    catch {
        Write-Log ('Loop error: {0}' -f $_.Exception.Message) 'ERROR'
    }

    Start-Sleep -Seconds $PollSeconds
}
