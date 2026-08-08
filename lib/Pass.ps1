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
        [string] $StateRoot = $script:DefaultStateRoot
    )

    try {
        $r = @($Outcome.Results)
        $summary = [pscustomobject]@{
            When       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Links      = $r.Count
            Applied    = [int](($r | Measure-Object -Property Applied   -Sum).Sum)
            Deferred   = [int](($r | Measure-Object -Property Deferred  -Sum).Sum)
            Conflicts  = [int](($r | Measure-Object -Property Conflicts -Sum).Sum)
            Deleted    = [int](($r | Measure-Object -Property Deleted   -Sum).Sum)
            Failed     = [int](($r | Measure-Object -Property Failed    -Sum).Sum)
            Aborted    = @($r | Where-Object { $_.Aborted } | ForEach-Object { "$($_.LinkId): $($_.Message)" })
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

        Write-Log ("pass starting over {0} link(s)" -f $links.Count)
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
                })
            }
        }

        $outcome.Ran     = $true
        $outcome.Results = @($results)

        $applied   = ($results | Measure-Object -Property Applied   -Sum).Sum
        $conflicts = ($results | Measure-Object -Property Conflicts -Sum).Sum
        $deleted   = ($results | Measure-Object -Property Deleted   -Sum).Sum
        Write-Log ("pass finished: applied {0}, conflicts {1}, deleted {2}" -f $applied, $conflicts, $deleted)

        Write-PassSummary -Outcome $outcome -StateRoot $StateRoot
        return $outcome
    }
    finally {
        if ($held -and $mutex) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        if ($mutex) { $mutex.Dispose() }
    }
}
