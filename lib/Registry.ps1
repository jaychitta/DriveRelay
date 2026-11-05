<#
    Registry.ps1  --  the set of co-linked folder pairs.

    A link pairs any local folder with any folder inside the OneDrive sync root.
    There is no predetermined list: links are added and removed freely, and only
    registered pairs are ever touched. Everything else inside the sync root is
    outside this tool's concern.

    Both sides are ordinary filesystem paths. Nothing here talks to a network.
#>

$script:DefaultRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:ConfigPath  = Join-Path $script:DefaultRoot 'config\links.json'

# Every change to the registry is read-modify-write, and three processes make them:
# the CLI, the tray's child pass, and the dashboard. The individual writes are
# atomic, so the file is never left corrupt -- but without a lock a dashboard
# Pause landing between a pass's read and its write is simply lost. This mutex
# makes each read-modify-write cycle exclusive.
$script:RegistryMutexName = 'Global\DriveRelayRegistry'

# The pass lock's name, as Pass.ps1 defines it ($script:PassMutexName). Add-Link
# takes it when it must set aside an earlier registration's history.
$script:PassLockName = 'Global\DriveRelayPass'

function Set-RegistryPath {
    param([Parameter(Mandatory)][string] $Path)
    $script:ConfigPath = $Path
}

function Invoke-RegistryTransaction {
    <#
        Run $Body holding the registry lock.

        Windows mutexes are re-entrant for the owning thread, so a transaction
        nested inside another (Add-Link calling Get-LinkRegistry, say) does not
        deadlock.

        A timeout throws rather than proceeding unlocked: losing a link's
        identity is worse than failing an edit the user can retry.
    #>
    param(
        [Parameter(Mandatory)][scriptblock] $Body,
        [int] $TimeoutMs = 5000
    )

    $mutex = $null
    $held  = $false
    try {
        # Fail closed, as the pass lock does. Proceeding unlocked brings back
        # the lost-update race the lock exists for; the usual cause is a
        # process at a different elevation level owning the name, and the
        # change can be retried from a normal (non-elevated) window.
        try   { $mutex = New-Object System.Threading.Mutex($false, $script:RegistryMutexName) }
        catch {
            throw ("Could not open the link registry lock ({0}); nothing was changed. If DriveRelay is also running elevated, close that window and try again." -f $_.Exception.Message)
        }

        try   { $held = $mutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] {
            # A holder died without releasing. We own it now.
            $held = $true
        }

        if (-not $held) { throw 'Timed out waiting for the link registry lock; nothing was changed.' }
        return (& $Body)
    }
    finally {
        if ($held -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Get-LinkRegistry {
    if (-not (Test-Path $script:ConfigPath)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        # -InputObject, not the pipeline: see the note in Manifest.ps1.
        $parsed = ConvertFrom-Json -InputObject $raw
        if ($parsed -isnot [System.Array]) { $parsed = @($parsed) }

        # Links written before multi-provider support carry OneDrivePath and no
        # Provider. Fill those in on read so old and new links behave alike;
        # the file itself is only rewritten when something else changes it.
        foreach ($l in $parsed) {
            if (-not $l.PSObject.Properties['RemotePath']) {
                $legacy = if ($l.PSObject.Properties['OneDrivePath']) { $l.OneDrivePath } else { $null }
                $l | Add-Member -NotePropertyName 'RemotePath' -NotePropertyValue $legacy
            }
            if (-not $l.PSObject.Properties['Provider']) {
                $l | Add-Member -NotePropertyName 'Provider' -NotePropertyValue 'Auto'
            }
        }
        return $parsed
    }
    catch {
        throw ("links.json is not readable as JSON: {0}" -f $_.Exception.Message)
    }
}

function Save-LinkRegistry {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Links)

    $dir = Split-Path -Parent $script:ConfigPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Write via a temp file so an interrupted save cannot leave the registry
    # truncated -- losing this file means losing every link's identity.
    #
    # -InputObject, not the pipeline: piping unrolls the array and a leading
    # comma double-wraps it. Both produce a file that reloads as nested arrays
    # whose properties are all empty.
    if ($Links.Count -eq 0) {
        $json = '[]'
    }
    else {
        $json = ConvertTo-Json -InputObject ([object[]] $Links) -Depth 6
        # A single-element array still serialises as a bare object here.
        # StartsWith, not -like: '[' is a wildcard metacharacter.
        if (-not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
    }

    $tmp = "$script:ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
}

function New-LinkId {
    param([Parameter(Mandatory)][string] $LocalPath)

    $leaf = (Split-Path -Leaf $LocalPath) -replace '[^A-Za-z0-9\-_]', '-'
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'link' }

    $existing = @(Get-LinkRegistry | ForEach-Object { $_.Id })
    if ($existing -notcontains $leaf) { return $leaf }

    $n = 2
    while ($existing -contains ("$leaf-$n")) { $n++ }
    return "$leaf-$n"
}

function Test-PathOverlap {
    <#
        True when one path sits inside the other. Two links whose trees overlap
        would fight over the same files, so registration refuses it.
    #>
    param(
        [Parameter(Mandatory)][string] $A,
        [Parameter(Mandatory)][string] $B
    )

    $a = [IO.Path]::GetFullPath($A).TrimEnd('\') + '\'
    $b = [IO.Path]::GetFullPath($B).TrimEnd('\') + '\'
    return ($a.StartsWith($b, 'OrdinalIgnoreCase') -or $b.StartsWith($a, 'OrdinalIgnoreCase'))
}

function Add-Link {
    <#
        Register a pair. -Seed says which side is authoritative on the first
        run: that is the "replicate this folder to the other side" step, and it
        works in either direction. After seeding the pair is two-way.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Local,
        # The far side: any folder at all -- OneDrive, Google Drive, Dropbox,
        # a network share, another disk.
        [Parameter(Mandatory)][string] $Remote,
        [ValidateSet('Local','Remote')][string] $Seed = 'Local',
        [ValidateSet('Auto','CloudFiles','Plain')][string] $Provider = 'Auto',
        # Range-checked here, not only when read: a negative settle window would
        # disable settling, and a negative cap would abort every pass.
        [ValidateRange(0, 2147483647)][int] $SettleMinutes = 3,
        [ValidateRange(0, 2147483647)][int] $MaxDelete = 50,
        [bool] $Dehydrate = $true,
        [bool] $HydrateBeforeDelete = $false,

        # The engine's state folder. When given, sync history left under the
        # new link's id by an earlier registration is set aside before the
        # link is saved -- see Move-LinkStateAside. Callers that register real
        # links (the CLI and the dashboard) must pass it.
        [string] $StateRoot
    )

    if (Test-PathOverlap -A $Local -B $Remote) {
        throw 'The two sides of a link must not contain one another.'
    }

    # Ids come from the folder name, so removing a pair and adding it again
    # reuses the id -- and state\<id>\ still holds the old pair's manifest. If a
    # sync of the removed link is still finishing, it can write that manifest
    # back after we move it aside. Hold the pass lock for the whole add when
    # there is old history; take it before the registry lock, the same order a
    # pass takes them, so the two can never wait on each other.
    $passLock = $null
    $passHeld = $false
    $prospective = if ($StateRoot) { New-LinkId -LocalPath $Local } else { $null }
    if ($prospective -and (Test-Path -LiteralPath (Join-Path $StateRoot $prospective))) {
        $passLock = New-Object System.Threading.Mutex($false, $script:PassLockName)
        try   { $passHeld = $passLock.WaitOne(3000) }
        catch [System.Threading.AbandonedMutexException] { $passHeld = $true }
        if (-not $passHeld) {
            $passLock.Dispose()
            throw ("A sync is running and '{0}' has history from an earlier registration that must be set aside first. Nothing was changed; add the folder again when the sync finishes." -f $prospective)
        }
    }

    try {
    return Invoke-RegistryTransaction {

    $links = @(Get-LinkRegistry)

    # Both sides of the new link are checked against *both* sides of every
    # existing link -- all four combinations.
    #
    # Checking local-against-local and remote-against-remote only, as this
    # used to, lets a chain through: register A <-> B, then B <-> C, and folder
    # B is now the remote side of one link and the local side of another. Two
    # links then drive the same tree from two separate manifests, each seeing
    # the other's writes as changes it did not make.
    $newSides = @(
        [pscustomobject]@{ Name = 'local';  Path = $Local }
        [pscustomobject]@{ Name = 'remote'; Path = $Remote }
    )

    foreach ($l in $links) {
        $existingSides = @(
            [pscustomobject]@{ Name = 'local';  Path = $l.LocalPath }
            [pscustomobject]@{ Name = 'remote'; Path = (Get-RemotePath -Link $l) }
        )

        foreach ($new in $newSides) {
            foreach ($old in $existingSides) {
                if (-not $old.Path -or -not $new.Path) { continue }
                if (Test-PathOverlap -A $new.Path -B $old.Path) {
                    throw ("The {0} side ({1}) overlaps the {2} side of existing link '{3}' ({4}). Two links sharing a folder would each drive it from a different manifest." -f
                           $new.Name, $new.Path, $old.Name, $l.Id, $old.Path)
                }
            }
        }
    }

    $link = [pscustomobject]@{
        Id                  = New-LinkId -LocalPath $Local
        LocalPath           = [IO.Path]::GetFullPath($Local).TrimEnd('\')
        RemotePath          = [IO.Path]::GetFullPath($Remote).TrimEnd('\')
        Provider            = $Provider
        Seed                = $Seed
        SettleMinutes       = $SettleMinutes
        MaxDelete           = $MaxDelete
        Dehydrate           = $Dehydrate
        HydrateBeforeDelete = $HydrateBeforeDelete
        Enabled             = $true
        Seeded              = $false
        LastRun             = $null
        LastResult          = $null
    }

    if ($PSCmdlet.ShouldProcess($link.Id, 'register link')) {
        if ($StateRoot -and (Test-Path -LiteralPath (Join-Path $StateRoot $link.Id))) {
            # The id can differ from the one checked above if another add won
            # a race; never set aside history without the pass lock.
            if (-not $passHeld) {
                throw ("'{0}' has history from an earlier registration and another change raced this one. Nothing was changed; add the folder again." -f $link.Id)
            }
            # Before the save, inside the lock: the link never exists while
            # its folder still holds another registration's history, and if
            # this fails, nothing is registered.
            $null = Move-LinkStateAside -StateRoot $StateRoot -LinkId $link.Id
        }
        Save-LinkRegistry -Links (@($links) + $link)
    }

    return $link

    }   # end Invoke-RegistryTransaction
    }
    finally {
        if ($passLock) {
            if ($passHeld) { try { $passLock.ReleaseMutex() } catch { } }
            $passLock.Dispose()
        }
    }
}

function Move-LinkStateAside {
    <#
        Rename state\<id>\ to state\<id>.superseded-<timestamp>\, taking the
        manifest and its .bak/.tmp recovery copies with it, so a new link with
        a reused id starts with no history -- which seeds -- rather than with a
        different pair's history, which would read as deletions. Nothing is
        deleted. Throws if the folder cannot be renamed (for example, a file in
        it is open). Returns the new path.
    #>
    param([Parameter(Mandatory)][string] $StateRoot,
          [Parameter(Mandatory)][string] $LinkId)
    $dir = Join-Path $StateRoot $LinkId
    $aside = "{0}.superseded-{1}" -f $dir, (Get-Date -Format 'yyyyMMdd-HHmmss')
    try { Move-Item -LiteralPath $dir -Destination $aside -ErrorAction Stop }
    catch {
        throw ("Could not set aside the earlier sync history in {0} ({1}). Nothing was changed; close anything using that folder and add the pair again." -f $dir, $_.Exception.Message)
    }
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log ("set aside earlier sync history for {0}: {1}" -f $LinkId, $aside) 'WARN'
    }
    return $aside
}

function Send-StateFolderToRecycleBin {
    <#
        Send one state folder to the Windows Recycle Bin. Never deletes
        permanently: where the volume has no Recycle Bin (network, removable),
        the folder is left in place and the caller is told so.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $fixed = $false
    if ($full -notmatch '^\\\\') {
        try { $fixed = ((New-Object IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot($full))).DriveType -eq [IO.DriveType]::Fixed) }
        catch { $fixed = $false }
    }
    if (-not $fixed) { return $false }
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($full,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    return $true
}

# What "send to the Recycle Bin" does for state folders. Tests replace it so a
# test run does not fill the real Recycle Bin.
$script:StateBinAction = { param($Path) Send-StateFolderToRecycleBin -Path $Path }

function Clear-StaleLinkState {
    <#
        Retention for sync history, agreed with Jay on 2026-11-05: history
        that no link can use goes to the Recycle Bin.

          * state\<id>\ of a link no longer registered. Removing a link used
            to leave it for good.
          * state\<id>.superseded-<yyyyMMdd-HHmmss>\, set aside when a pair is
            added again, once it is older than SupersededDays (30).

        A folder counts as a removed link's history only if its name is a
        possible link id and it holds nothing but manifest.json, .bak or .tmp;
        anything else in state\ is left alone. Nothing is touched when the
        links file is missing or lists no links, so a lost links.json can never
        empty the history. The caller must hold the pass lock, so no sync is
        writing a manifest meanwhile. Returns the folders sent to the bin.
    #>
    param(
        [Parameter(Mandatory)][string] $StateRoot,
        [object[]] $Links,
        [int] $SupersededDays = 30,
        [datetime] $Now = (Get-Date)
    )
    $cleared = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $StateRoot)) { return @() }
    $ids = @($Links | Where-Object { $_ } | ForEach-Object { ([string]$_.Id).ToLowerInvariant() })
    $historyFiles = @('manifest.json', 'manifest.json.bak', 'manifest.json.tmp')

    foreach ($dir in @(Get-ChildItem -LiteralPath $StateRoot -Directory -Force -ErrorAction Stop)) {
        $reason = $null
        if ($dir.Name -match '^(?<id>[A-Za-z0-9_-]+)\.superseded-(?<stamp>\d{8}-\d{6})$') {
            $stamp = [datetime]::MinValue
            if ([datetime]::TryParseExact($Matches['stamp'], 'yyyyMMdd-HHmmss',
                    [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$stamp) -and
                ($Now - $stamp).TotalDays -gt $SupersededDays) {
                $reason = "set aside on {0:yyyy-MM-dd}, older than {1} days" -f $stamp, $SupersededDays
            }
        }
        elseif ($ids.Count -gt 0 -and $dir.Name -match '^[A-Za-z0-9_-]+$' -and
                $ids -notcontains $dir.Name.ToLowerInvariant()) {
            $entries = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)
            $onlyHistory = $entries.Count -gt 0 -and
                @($entries | Where-Object { $_.PSIsContainer -or $historyFiles -notcontains $_.Name.ToLowerInvariant() }).Count -eq 0
            if ($onlyHistory) { $reason = 'link no longer registered' }
        }
        if (-not $reason) { continue }
        try {
            if (& $script:StateBinAction $dir.FullName) {
                [void]$cleared.Add($dir.FullName)
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log ("sync history sent to the Recycle Bin ({0}): {1}" -f $reason, $dir.FullName)
                }
            }
            elseif (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("sync history kept, no Recycle Bin on this drive ({0}): {1}" -f $reason, $dir.FullName) 'WARN'
            }
        }
        catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("could not send sync history to the Recycle Bin: {0}: {1}" -f $dir.FullName, $_.Exception.Message) 'WARN'
            }
        }
    }
    return @($cleared)
}

function Remove-Link {
    <#
        Unregisters a pair. Files on both sides are left exactly as they are --
        this forgets the link, it does not delete anything.

        With -StateRoot, the link's sync history (state\<id>\) is sent to the
        Recycle Bin straight away when no sync is running. If one is, the
        history is left and the next pass clears it (Clear-StaleLinkState).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Id, [string] $StateRoot)

    # Pass lock before registry lock, the same order a pass and Add-Link use.
    $passLock = $null
    $passHeld = $false
    if ($StateRoot -and (Test-Path -LiteralPath (Join-Path $StateRoot $Id))) {
        $passLock = New-Object System.Threading.Mutex($false, $script:PassLockName)
        try   { $passHeld = $passLock.WaitOne(3000) }
        catch [System.Threading.AbandonedMutexException] { $passHeld = $true }
    }

    try {
        $remaining = Invoke-RegistryTransaction {
            $links = @(Get-LinkRegistry)
            if (@($links | Where-Object { $_.Id -eq $Id }).Count -eq 0) {
                throw ("No link with id '{0}'." -f $Id)
            }

            if ($PSCmdlet.ShouldProcess($Id, 'unregister link (files untouched)')) {
                Save-LinkRegistry -Links @($links | Where-Object { $_.Id -ne $Id })
                return $true
            }
            return $false
        }
        if ($passHeld -and $remaining -eq $true) {
            $dir = Join-Path $StateRoot $Id
            try {
                if (& $script:StateBinAction $dir) {
                    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                        Write-Log ("sync history sent to the Recycle Bin (link removed): {0}" -f $dir)
                    }
                }
            }
            catch {
                if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log ("could not send sync history to the Recycle Bin: {0}: {1}" -f $dir, $_.Exception.Message) 'WARN'
                }
            }
        }
    }
    finally {
        if ($passLock) {
            if ($passHeld) { try { $passLock.ReleaseMutex() } catch { } }
            $passLock.Dispose()
        }
    }
}

function Set-LinkEnabled {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][bool] $Enabled
    )

    Invoke-RegistryTransaction {
        $links = @(Get-LinkRegistry)
        $target = $links | Where-Object { $_.Id -eq $Id }
        if (-not $target) { throw ("No link with id '{0}'." -f $Id) }

        if ($PSCmdlet.ShouldProcess($Id, "set enabled=$Enabled")) {
            $target.Enabled = $Enabled
            Save-LinkRegistry -Links $links
        }
    }
}

function Set-LinkSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Id,
        [int] $SettleMinutes = -1,
        [int] $MaxDelete = -1,
        [object] $Dehydrate = $null,
        [object] $HydrateBeforeDelete = $null
    )

    return Invoke-RegistryTransaction {
        $links = @(Get-LinkRegistry)
        $target = $links | Where-Object { $_.Id -eq $Id }
        if (-not $target) { throw ("No link with id '{0}'." -f $Id) }

        if ($SettleMinutes -ge 0) { $target.SettleMinutes = $SettleMinutes }
        if ($MaxDelete -ge 0) { $target.MaxDelete = $MaxDelete }
        if ($null -ne $Dehydrate) { $target.Dehydrate = [bool]$Dehydrate }
        if ($null -ne $HydrateBeforeDelete) { $target.HydrateBeforeDelete = [bool]$HydrateBeforeDelete }

        if ($PSCmdlet.ShouldProcess($Id, "update link settings")) {
            Save-LinkRegistry -Links $links
        }
        return $target
    }
}

function Update-LinkState {
    <#
        Records the outcome of a pass. Kept separate from Add/Remove so a sync
        run never rewrites a link's definition.
    #>
    param(
        [Parameter(Mandatory)][string] $Id,
        [string] $Result,
        [switch] $MarkSeeded
    )

    Invoke-RegistryTransaction {
        $links  = @(Get-LinkRegistry)
        $target = $links | Where-Object { $_.Id -eq $Id }
        if (-not $target) { return }

        $target.LastRun    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $target.LastResult = $Result
        if ($MarkSeeded) { $target.Seeded = $true }

        Save-LinkRegistry -Links $links
    }
}

function Test-LinkPaths {
    <#
        Both sides must exist before a pass runs. A missing folder is reported,
        never created silently -- a vanished drive or unmounted path must not
        look like "everything was deleted".
    #>
    param([Parameter(Mandatory)][object] $Link)

    $remote   = Get-RemotePath -Link $Link
    $problems = @()
    if (-not (Test-Path -LiteralPath $Link.LocalPath)) { $problems += "local path missing: $($Link.LocalPath)" }
    if (-not $remote)                                  { $problems += 'no remote path configured' }
    elseif (-not (Test-Path -LiteralPath $remote))     { $problems += "remote path missing: $remote" }

    return [pscustomobject]@{
        Ok       = ($problems.Count -eq 0)
        Problems = $problems
    }
}
