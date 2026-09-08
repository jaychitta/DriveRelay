<#
    Pass.ps1  --  one run over every enabled link.

    This is the single place a sync pass is driven from. The CLI calls it, the
    scheduled task calls it, and the tray agent will call it too. Keeping one
    implementation means unattended runs behave exactly like the ones you watch.

    Passes must never stack. A run triggered while another is still working --
    a slow hydration, a large upload, a machine waking from sleep with several
    triggers queued -- would have two processes copying the same files in
    opposite directions. A named mutex makes the second one step aside.
#>

$script:PassMutexName = 'Global\DriveRelayPass'
$script:DefaultStateRoot = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) 'state' } else { 'state' }

# How long a run of idle passes may go unmentioned before one heartbeat line is
# written. Idle passes are the overwhelming majority -- at a ten minute interval
# they are six lines an hour that say nothing happened -- but writing none at all
# would make an unattended run that is working indistinguishable from one that
# stopped firing. One line an hour keeps the proof without the volume.
$script:IdleHeartbeatMinutes = 60

function Get-PassSummaryPath {
    param([string] $StateRoot = $script:DefaultStateRoot)
    return (Join-Path $StateRoot 'lastpass.json')
}

function Write-PassSummary {
    <#
        A small file the tray reads after each pass.

        The tray needs to know what happened without parsing the log, and
        without loading the whole engine into a long-running process.
    #>
    param(
        [Parameter(Mandatory)][object] $Outcome,
        [string] $StateRoot = $script:DefaultStateRoot,

        # Idle-run bookkeeping, carried here rather than in a file of its own so
        # the streak survives across the separate processes a pass can run in.
        [int]    $IdleCount = 0,
        [string] $IdleSince = '',
        [string] $LastHeartbeat = ''
    )

    try {
        $r = @($Outcome.Results)
        $summary = [pscustomobject]@{
            When       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Links      = $r.Count
            IdleCount     = $IdleCount
            IdleSince     = $IdleSince
            LastHeartbeat = $LastHeartbeat
            Applied    = [int](($r | Measure-Object -Property Applied   -Sum).Sum)
            Deferred   = [int](($r | Measure-Object -Property Deferred  -Sum).Sum)
            Conflicts  = [int](($r | Measure-Object -Property Conflicts -Sum).Sum)
            Deleted    = [int](($r | Measure-Object -Property Deleted   -Sum).Sum)
            Failed     = [int](($r | Measure-Object -Property Failed    -Sum).Sum)
            Aborted    = @($r | Where-Object { $_.Aborted } | ForEach-Object { "$($_.LinkId): $($_.Message)" })

            # Availability is reported separately from failure. A drive that is
            # not plugged in is not a sync error, and calling it one trains
            # people to ignore the warning that matters.
            Unavailable = @($r |
                Where-Object { $_.PSObject.Properties['State'] -and $_.State -and $_.State -ne 'Ready' } |
                ForEach-Object {
                    [pscustomobject]@{
                        LinkId = $_.LinkId; State = $_.State
                        Summary = $_.Message; Detail = $_.Detail
                    }
                })
        }

        if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }
        $path = Get-PassSummaryPath -StateRoot $StateRoot
        $tmp  = "$path.tmp"
        ConvertTo-Json -InputObject $summary -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    catch {
        # The tray losing a status update must never fail a sync.
        Write-Log ("could not write pass summary: {0}" -f $_.Exception.Message) 'WARN'
    }
}

function Read-PassSummary {
    param([string] $StateRoot = $script:DefaultStateRoot)

    $path = Get-PassSummaryPath -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try   { return (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw -Encoding UTF8)) }
    catch { return $null }
}

function Invoke-SyncPass {
    <#
        Returns a result object per link, plus whether the pass actually ran.
        Skipped is not a failure: it means another pass still holds the lock.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]   $LinkId,
        [string[]] $ExcludePatterns,
        [string]   $StateRoot = $script:DefaultStateRoot,
        [switch]   $Quiet
    )

    $outcome = [pscustomobject]@{
        Ran     = $false
        Skipped = $false
        Reason  = ''
        Results = @()
    }

    $mutex   = $null
    $held    = $false

    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:PassMutexName)
    }
    catch {
        # Without a mutex we cannot guarantee exclusivity, so do not proceed.
        $outcome.Skipped = $true
        $outcome.Reason  = "could not create pass lock: $($_.Exception.Message)"
        Write-Log $outcome.Reason 'ERROR'
        return $outcome
    }

    try {
        try   { $held = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] {
            # A previous pass died without releasing. We now hold it.
            $held = $true
            Write-Log 'previous pass ended without releasing the lock; continuing' 'WARN'
        }

        if (-not $held) {
            $outcome.Skipped = $true
            $outcome.Reason  = 'another pass is already running'
            if (-not $Quiet) { Write-Log $outcome.Reason }
            return $outcome
        }

        $links = @(Get-LinkRegistry | Where-Object { $_.Enabled })
        if ($LinkId) { $links = @($links | Where-Object { $_.Id -eq $LinkId }) }

        if ($links.Count -eq 0) {
            $outcome.Ran    = $true
            $outcome.Reason = 'no enabled links'
            # Logged deliberately: an unattended run that writes nothing is
            # indistinguishable from one that never fired.
            Write-Log 'pass ran with no enabled links'
            return $outcome
        }

        # DEBUG: on a healthy system this line is followed within seconds by a
        # "pass finished: applied 0 ..." that says nothing happened. The pair is
        # only worth keeping when a pass hangs, which is when DEBUG is on.
        Write-Log ("pass starting over {0} link(s)" -f $links.Count) 'DEBUG'
        $results = New-Object System.Collections.ArrayList

        foreach ($link in $links) {
            $wasSeeded = $link.Seeded
            try {
                $r = Invoke-LinkSync -Link $link -ExcludePatterns $ExcludePatterns -StateRoot $StateRoot

                if ($PSCmdlet.ShouldProcess($link.Id, 'record link state')) {
                    $msg = if ($r.Aborted) { "aborted: $($r.Message)" } else { $r.Message }
                    if (-not $wasSeeded -and -not $r.Aborted) {
                        Update-LinkState -Id $link.Id -Result $msg -MarkSeeded
                    }
                    else {
                        Update-LinkState -Id $link.Id -Result $msg
                    }
                }

                $null = $results.Add($r)
            }
            catch {
                # One bad link must not take the rest of the pass down.
                Write-Log ("link {0} threw: {1}" -f $link.Id, $_.Exception.Message) 'ERROR'
                $null = $results.Add([pscustomobject]@{
                    LinkId = $link.Id; Applied = 0; Deferred = 0; Failed = 1
                    Conflicts = 0; Deleted = 0; CloudOnlyDeletes = 0
                    Aborted = $true; Message = $_.Exception.Message
                    State = 'Ready'; Detail = ''
                })
            }
        }

        $outcome.Ran     = $true
        $outcome.Results = @($results)

        $applied   = [int](($results | Measure-Object -Property Applied   -Sum).Sum)
        $conflicts = [int](($results | Measure-Object -Property Conflicts -Sum).Sum)
        $deleted   = [int](($results | Measure-Object -Property Deleted   -Sum).Sum)
        $failed    = [int](($results | Measure-Object -Property Failed    -Sum).Sum)

        # A pass is idle when it changed nothing and nothing went wrong.
        # Deferrals do not count as news: a file held open by Tally or Excel is
        # deferred on every pass for as long as it stays open, and reporting
        # that hourly is the same information as reporting it six times an hour.
        $degraded = @($results | Where-Object {
            $_.Aborted -or
            ($_.PSObject.Properties['State'] -and $_.State -and $_.State -ne 'Ready')
        }).Count
        $idle = ($applied -eq 0 -and $conflicts -eq 0 -and $deleted -eq 0 -and
                 $failed -eq 0 -and $degraded -eq 0)

        $now       = Get-Date
        $prev      = Read-PassSummary -StateRoot $StateRoot
        $idleCount = 0
        $idleSince = ''
        $heartbeat = ''
        if ($prev) {
            if ($prev.PSObject.Properties['IdleCount'])     { $idleCount = [int]$prev.IdleCount }
            if ($prev.PSObject.Properties['IdleSince'])     { $idleSince = [string]$prev.IdleSince }
            if ($prev.PSObject.Properties['LastHeartbeat']) { $heartbeat = [string]$prev.LastHeartbeat }
        }

        $line = "pass finished: applied {0}, conflicts {1}, deleted {2}" -f $applied, $conflicts, $deleted

        if (-not $idle) {
            # Something happened. Report it, and close out any idle run that
            # preceded it so the quiet stretch is still accounted for.
            if ($idleCount -gt 0) {
                $line += " (after {0} idle pass(es) since {1})" -f $idleCount, $idleSince
            }
            Write-Log $line
            $idleCount = 0
            $idleSince = ''
            $heartbeat = $now.ToString('yyyy-MM-dd HH:mm:ss')
        }
        else {
            $idleCount++
            if (-not $idleSince) { $idleSince = $now.ToString('yyyy-MM-dd HH:mm:ss') }

            $due = $true
            if ($heartbeat) {
                try   { $due = ($now - [datetime]::Parse($heartbeat)).TotalMinutes -ge $script:IdleHeartbeatMinutes }
                catch { $due = $true }
            }

            if ($due) {
                Write-Log ("idle: {0} pass(es) since {1}, nothing to relay" -f $idleCount, $idleSince)
                $heartbeat = $now.ToString('yyyy-MM-dd HH:mm:ss')
            }
            else {
                Write-Log $line 'DEBUG'
            }
        }

        Write-PassSummary -Outcome $outcome -StateRoot $StateRoot `
                          -IdleCount $idleCount -IdleSince $idleSince -LastHeartbeat $heartbeat
        return $outcome
    }
    finally {
        if ($held -and $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}
