<#
    Actions.ps1  --  the part that writes.

    Everything here is reachable only through Invoke-LinkSync, and every step
    honours -WhatIf. The rules that keep this safe:

      * Copies land atomically. Content goes to a .tmp name that the snapshot
        excludes, then moves into place, so a half-copied file is never visible
        as a complete one.

      * Deletes are never permanent, but the recovery path differs by side and
        this was measured, not assumed:

          - An ordinary file with content on disk goes to the Recycle Bin.
          - A dehydrated placeholder cannot go to the Recycle Bin -- there is
            no local content to put there. Deleting it propagates to the
            service, where it lands in OneDrive's own online recycle bin.

        Set HydrateBeforeDelete on a link to pull content down first so the
        Recycle Bin holds a real copy. It costs a download per deleted file,
        which is why it is not the default.

      * A pass proposing more deletions than the link's MaxDelete aborts
        entirely rather than partially applying.

      * A folder the pass empties is removed with its files. The snapshot is
        files-only, so nothing else would ever clean it up. Scoped to folders
        this pass emptied -- an empty folder the user made by hand is left
        alone, and the link root is never removed.

      * Manifest entries are written only for paths whose action actually
        succeeded. A deferred or failed file keeps its previous entry, so the
        next pass re-evaluates it from the same baseline rather than mistaking
        the divergence for a fresh conflict.

      * Dehydration is requested, then confirmed by the Offline attribute
        appearing. A file is never assumed uploaded.
#>

Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
$script:DefaultStateRoot = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) 'state' } else { 'state' }

function Copy-FileAtomic {
    <#
        Copy preserving the last-write time, via a temp name so the destination
        never briefly exists as a truncated file. The temp suffix matches an
        excluded pattern, so a crash mid-copy leaves something the next
        snapshot ignores.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )

    if (-not $PSCmdlet.ShouldProcess($Destination, "copy from $Source")) { return $false }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = "$Destination.driverelay.tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force
        $src = Get-Item -LiteralPath $Source -Force
        Move-Item -LiteralPath $tmp -Destination $Destination -Force

        # Keep the timestamps equal so the next pass sees the pair as in sync.
        $dst = Get-Item -LiteralPath $Destination -Force
        $dst.LastWriteTimeUtc = $src.LastWriteTimeUtc

        if ($dst.Length -ne $src.Length) {
            throw ("size mismatch after copy: {0} vs {1}" -f $src.Length, $dst.Length)
        }
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Remove-FileSafely {
    <#
        Delete recoverably, and say which recovery path applies.

        Returns $true on success. The caller is told via the log whether the
        file went to the local Recycle Bin or is recoverable only from
        OneDrive's online recycle bin, because those are different promises and
        conflating them would mislead at exactly the wrong moment.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $HydrateFirst
    )

    $offline = $false
    try { $offline = (Get-CloudState -Path $Path).IsOffline } catch { }

    $target = if ($offline) { 'delete placeholder (recoverable from the cloud service online recycle bin)' }
              else          { 'delete (to Recycle Bin)' }

    if (-not $PSCmdlet.ShouldProcess($Path, $target)) { return $false }

    # Pulling the content down first means the Recycle Bin has something real
    # to keep, at the cost of a download.
    if ($offline -and $HydrateFirst) {
        if (Wait-Hydrated -Path $Path -TimeoutSeconds 1800 -Confirm:$false) {
            $offline = $false
        }
        else {
            Write-Log ("could not hydrate before delete, deferring: {0}" -f $Path) 'WARN'
            return $false
        }
    }

    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)

        if ($offline) {
            Write-Log ("deleted placeholder {0} -- recover from the cloud service's online recycle bin, not the local one" -f $Path) 'WARN'
        }
        else {
            Write-Log ("deleted {0} -- in the Recycle Bin" -f $Path)
        }
        return $true
    }
    catch {
        Write-Log ("delete failed for {0}: {1}" -f $Path, $_.Exception.Message) 'WARN'
        return $false
    }
}

function Remove-EmptiedDirectory {
    <#
        Remove directories that this pass emptied, walking upward.

        The engine tracks files, not folders -- the snapshot is -File only, and
        nothing in the manifest describes a directory. Left alone that means a
        deleted folder's files vanish and the folder itself stays behind as an
        empty shell on the other side.

        Scoped deliberately to the parents of files deleted in this pass rather
        than "every empty folder under the root". An empty folder the user made
        by hand is invisible to the sync model, and deleting it would be a
        change nobody asked for. Only folders this pass emptied are removed.

        Deepest-first, so a folder whose only child is a subfolder emptied by
        the same pass is itself removed on the same run. The walk stops at the
        link root, which is never removed even if it ends up empty.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $Paths,
        [Parameter(Mandatory)][string] $StopAt
    )

    $removed = 0
    if (-not $Paths -or $Paths.Count -eq 0) { return $removed }

    $root = try { [IO.Path]::GetFullPath($StopAt).TrimEnd('\') } catch { $StopAt.TrimEnd('\') }

    # Deepest first: an emptied child must go before its parent is judged.
    $ordered = $Paths |
        Where-Object { $_ } |
        Sort-Object -Unique |
        Sort-Object -Property { ($_ -split '\\').Count } -Descending

    foreach ($start in $ordered) {
        $dir = try { [IO.Path]::GetFullPath($start).TrimEnd('\') } catch { $start.TrimEnd('\') }

        while ($dir -and $dir.Length -gt $root.Length -and $dir.StartsWith($root, 'OrdinalIgnoreCase')) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                $dir = Split-Path -Parent $dir
                continue
            }

            # Any child at all -- file, placeholder, or subfolder -- means this
            # folder is still carrying something and must stay.
            $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
            if ($children.Count -gt 0) { break }

            $parent = Split-Path -Parent $dir
            if (-not $PSCmdlet.ShouldProcess($dir, 'remove emptied folder')) { break }

            try {
                Remove-Item -LiteralPath $dir -Force -ErrorAction Stop
                Write-Log ("removed emptied folder {0}" -f $dir)
                $removed++
            }
            catch {
                Write-Log ("could not remove emptied folder {0}: {1}" -f $dir, $_.Exception.Message) 'WARN'
                break
            }

            $dir = $parent
        }
    }

    return $removed
}

function Request-Dehydration {
    <#
        Ask for the OneDrive-side copy to be freed, then look for the receipt.

        A short wait on purpose: if the upload has not finished yet the file is
        simply left alone and housekeeping retries on a later pass. Blocking a
        whole pass on one large upload helps nobody.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $WaitSeconds = 45
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'dehydrate and confirm')) { return $false }

    $ok = Wait-UploadReceipt -Path $Path -TimeoutSeconds $WaitSeconds -PollSeconds 5 -Confirm:$false
    if ($ok) { Write-Log ("dehydrated (upload confirmed): {0}" -f $Path) }
    else     { Write-Log ("dehydration pending, will retry: {0}" -f $Path) }
    return $ok
}

function Get-ConflictName {
    param(
        [Parameter(Mandatory)][string] $RelPath,
        [string] $Tag = 'remote'
    )
    $dir  = Split-Path -Parent $RelPath
    $base = [IO.Path]::GetFileNameWithoutExtension($RelPath)
    $ext  = [IO.Path]::GetExtension($RelPath)
    $when = Get-Date -Format 'yyyy-MM-dd HHmmss'
    $name = "$base (conflict from $Tag $when)$ext"
    if ($dir) { return (Join-Path $dir $name) }
    return $name
}

function Invoke-CopyToRemote {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Link,
        [bool] $Dehydrate = $true
    )

    $src = $Item.Local.FullPath
    $dst = Join-Path (Get-RemotePath -Link $Link) $Item.RelPath

    if (-not (Copy-FileAtomic -Source $src -Destination $dst)) { return $false }
    Write-Log ("copied to remote side: {0}" -f $Item.RelPath)

    if ($Dehydrate) { $null = Request-Dehydration -Path $dst }
    return $true
}

function Invoke-CopyToLocal {
    <#
        The OneDrive-side file may be a placeholder. Pull the content down,
        copy it out, then put it back the way we found it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Link,
        [bool] $Dehydrate = $true
    )

    $src = $Item.Remote.FullPath
    $dst = Join-Path $Link.LocalPath $Item.RelPath

    $wasOffline = $Item.Remote.IsOffline

    if ($wasOffline) {
        if (-not $PSCmdlet.ShouldProcess($src, 'hydrate before copying out')) { return $false }
        if (-not (Wait-Hydrated -Path $src -TimeoutSeconds 1800 -Confirm:$false)) {
            Write-Log ("hydration timed out, deferring: {0}" -f $Item.RelPath) 'WARN'
            return $false
        }
    }

    if (-not (Copy-FileAtomic -Source $src -Destination $dst)) { return $false }
    Write-Log ("copied to local: {0}" -f $Item.RelPath)

    # Restore the placeholder state we found it in.
    if ($wasOffline -and $Dehydrate) { $null = Request-Dehydration -Path $src }
    return $true
}

function Invoke-ConflictFork {
    <#
        Both sides changed. Keep both, decide nothing.

        The OneDrive version is brought down beside the local one under a
        conflict name; the local file is then pushed up as the current version.
        The conflict copy has no manifest entry, so the next pass sees it as a
        new local file and carries it to the OneDrive side on its own.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Link,
        [bool] $Dehydrate = $true
    )

    $odPath   = $Item.Remote.FullPath
    $forkRel  = Get-ConflictName -RelPath $Item.RelPath -Tag (Get-ProviderLabel -Path $odPath)
    $forkPath = Join-Path $Link.LocalPath $forkRel

    $wasOffline = $Item.Remote.IsOffline
    if ($wasOffline) {
        if (-not (Wait-Hydrated -Path $odPath -TimeoutSeconds 1800 -Confirm:$false)) {
            Write-Log ("hydration timed out during conflict fork, deferring: {0}" -f $Item.RelPath) 'WARN'
            return $false
        }
    }

    if (-not (Copy-FileAtomic -Source $odPath -Destination $forkPath)) { return $false }
    Write-Log ("conflict: kept OneDrive version as {0}" -f $forkRel) 'WARN'

    if (-not (Copy-FileAtomic -Source $Item.Local.FullPath -Destination $odPath)) { return $false }
    Write-Log ("conflict: local version is now current for {0}" -f $Item.RelPath) 'WARN'

    if ($Dehydrate) { $null = Request-Dehydration -Path $odPath }
    return $true
}

function Invoke-LinkSeed {
    <#
        First run for a link. The authoritative side is copied over anything
        missing or different on the other; nothing is deleted. Seeding
        establishes the baseline, it does not reconcile.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Link,
        [string[]] $ExcludePatterns,
        [string] $StateRoot
    )

    $remote   = Get-RemotePath -Link $Link
    $seedLocal = ($Link.Seed -eq 'Local')
    $fromRoot = if ($seedLocal) { $Link.LocalPath } else { $remote }
    $toRoot   = if ($seedLocal) { $remote }         else { $Link.LocalPath }

    Write-Log ("seeding link {0} from {1}: {2} -> {3}" -f $Link.Id, $Link.Seed, $fromRoot, $toRoot)

    $from = Get-SideSnapshot -Root $fromRoot -ExcludePatterns $ExcludePatterns
    $to   = Get-SideSnapshot -Root $toRoot   -ExcludePatterns $ExcludePatterns

    $copied = 0; $skipped = 0
    foreach ($k in $from.Keys) {
        $s = $from[$k]
        $d = $to[$k]

        if ($d -and (Test-SameFileState $s.Length $s.WriteUtc $d.Length $d.WriteUtc)) { continue }

        if (-not (Test-FileSettled -Path $s.FullPath -SettleMinutes $Link.SettleMinutes) -or
                 (Test-FileLocked  -Path $s.FullPath)) {
            $skipped++
            continue
        }

        # Seeding out of OneDrive means the content may not be here yet.
        if ($s.IsOffline) {
            if (-not (Wait-Hydrated -Path $s.FullPath -TimeoutSeconds 1800 -Confirm:$false)) {
                $skipped++; continue
            }
        }

        $dest = Join-Path $toRoot $s.RelPath
        try {
            # No per-file dehydration during a seed: it can run to tens of
            # thousands of files. The whole tree is dehydrated once at the end
            # of the pass instead.
            if (Copy-FileAtomic -Source $s.FullPath -Destination $dest) { $copied++ }
        }
        catch {
            Write-Log ("seed copy failed for {0}: {1}" -f $s.RelPath, $_.Exception.Message) 'ERROR'
            $skipped++
        }
    }

    Write-Log ("seed complete for {0}: {1} copied, {2} deferred" -f $Link.Id, $copied, $skipped)
    return [pscustomobject]@{ Copied = $copied; Deferred = $skipped }
}

function Get-LinkOption {
    <#
        Read an optional link setting, tolerating links written before that
        setting existed.
    #>
    param(
        [Parameter(Mandatory)][object] $Link,
        [Parameter(Mandatory)][string] $Name,
        $Default
    )

    if ($null -eq $Link.PSObject.Properties[$Name]) { return $Default }
    if ($null -eq $Link.$Name) { return $Default }
    return $Link.$Name
}

function Get-LinkDehydrate {
    param([Parameter(Mandatory)][object] $Link)
    return [bool] (Get-LinkOption -Link $Link -Name 'Dehydrate' -Default $true)
}

function Invoke-LinkSync {
    <#
        One pass over one link.

        Order matters: the delete cap is checked before anything is applied, so
        a pass that looks like mass deletion never gets halfway through.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object] $Link,
        [string[]] $ExcludePatterns,
        [string] $StateRoot = $script:DefaultStateRoot
    )

    $result = [pscustomobject]@{
        LinkId           = $Link.Id
        Applied          = 0
        Deferred         = 0
        Failed           = 0
        Conflicts        = 0
        Deleted          = 0
        CloudOnlyDeletes = 0
        Aborted          = $false
        Message          = ''
        # Ready | DriveOffline | FolderMissing | ClientNotRunning | NoRemote
        State            = 'Ready'
        Detail           = ''
    }

    # Availability first, and specifically: an unmounted drive, a deleted folder
    # and a stopped cloud client all look like "path missing" to Test-Path but
    # need different things done about them.
    $avail = Get-LinkAvailability -Link $Link
    if ($avail.Blocking) {
        $result.Aborted = $true
        $result.State   = $avail.State
        $result.Message = $avail.Summary
        $result.Detail  = $avail.Detail
        Write-Log ("link {0} skipped [{1}]: {2}" -f $Link.Id, $avail.State, $avail.Detail) 'WARN'
        return $result
    }
    if ($avail.State -ne 'Ready') {
        # Not blocking, but the operator should know the pass is running degraded.
        $result.State  = $avail.State
        $result.Detail = $avail.Detail
        Write-Log ("link {0} degraded [{1}]: {2}" -f $Link.Id, $avail.State, $avail.Detail) 'WARN'
    }

    # Placeholder handling only applies where the remote side actually has
    # placeholders. On a plain folder -- Google Drive in Mirror mode, a network
    # share, another disk -- these steps are skipped entirely.
    $provider             = Resolve-LinkProvider -Link $Link
    $isCloud              = ($provider -eq 'CloudFiles')
    $dehydrate            = $isCloud -and (Get-LinkDehydrate -Link $Link)
    $hydrateBeforeDelete  = $isCloud -and (Get-LinkOption -Link $Link -Name 'HydrateBeforeDelete' -Default $false)
    $settleMinutes        = [int] (Get-LinkOption -Link $Link -Name 'SettleMinutes' -Default 3)
    $maxDelete            = [int] (Get-LinkOption -Link $Link -Name 'MaxDelete' -Default 50)
    $remotePath           = Get-RemotePath -Link $Link
    $manifestPath         = Get-ManifestPath -LinkId $Link.Id -StateRoot $StateRoot

    if (-not $Link.Seeded) {
        $seed = Invoke-LinkSeed -Link $Link -ExcludePatterns $ExcludePatterns -StateRoot $StateRoot
        $result.Applied  = $seed.Copied
        $result.Deferred = $seed.Deferred
        $result.Message  = 'seeded'
        # Fall through: the comparison below records the resulting baseline.
    }

    $items = Compare-LinkState -Link $Link -ExcludePatterns $ExcludePatterns -StateRoot $StateRoot

    # --- delete cap, checked before anything is applied ---
    $deleteItems = @($items | Where-Object { $_.Action -like 'Delete*' })
    if ($deleteItems.Count -gt $maxDelete) {
        $result.Aborted = $true
        $result.Message = ("{0} deletions exceeds MaxDelete of {1}; nothing applied" -f $deleteItems.Count, $maxDelete)
        Write-Log ("link {0} ABORTED: {1}" -f $Link.Id, $result.Message) 'ERROR'
        return $result
    }

    $manifest = Read-Manifest -Path $manifestPath
    $succeeded = @{}   # relpath key -> $true, for entries to refresh
    $forgotten = @{}   # relpath key -> $true, for entries to drop
    $emptiedLocal  = @()   # parents of deleted local files, pruned after the loop
    $emptiedRemote = @()   # same on the remote side

    foreach ($item in $items) {
        $key = $item.RelPath.ToLowerInvariant()

        # Plain conditionals, not a switch: `continue` inside a switch does not
        # reliably continue the enclosing loop in PowerShell.
        if ($item.Action -eq 'InSync') {
            $succeeded[$key] = $true
            # Space reclamation happens once for the whole tree after the loop,
            # not per file -- see the Set-TreeDehydrated call below.
            continue
        }

        if ($item.Action -eq 'Forget') {
            $forgotten[$key] = $true
            continue
        }

        $ready = Test-ActionReady -Item $item -SettleMinutes $settleMinutes
        if (-not $ready.Ready) {
            $result.Deferred++
            # DEBUG: a file held open by Tally or Excel is deferred again on
            # every pass for as long as it stays open, so at INFO one open
            # workbook writes a line every ten minutes all day. The deferred
            # count on the link summary and `DriveRelay status` both report the
            # backlog; naming each file every pass only crowds out the copies
            # and deletes the log exists to record.
            Write-Log ("deferred ({0}): {1}" -f $ready.Reason, $item.RelPath) 'DEBUG'
            continue
        }

        try {
            $ok = $false
            switch ($item.Action) {
                'CopyToRemote' { $ok = Invoke-CopyToRemote -Item $item -Link $Link -Dehydrate $dehydrate }
                'CopyToLocal'    { $ok = Invoke-CopyToLocal    -Item $item -Link $Link -Dehydrate $dehydrate }
                'Conflict'       {
                    $ok = Invoke-ConflictFork -Item $item -Link $Link -Dehydrate $dehydrate
                    if ($ok) { $result.Conflicts++ }
                }
                'DeleteLocal'    {
                    # Always a real file with content, so the Recycle Bin holds it.
                    $ok = Remove-FileSafely -Path $item.Local.FullPath
                    if ($ok) {
                        $result.Deleted++
                        $forgotten[$key] = $true
                        $emptiedLocal += (Split-Path -Parent $item.Local.FullPath)
                    }
                }
                'DeleteRemote' {
                    $ok = Remove-FileSafely -Path $item.Remote.FullPath -HydrateFirst:$hydrateBeforeDelete
                    if ($ok) {
                        $result.Deleted++
                        $forgotten[$key] = $true
                        $emptiedRemote += (Split-Path -Parent $item.Remote.FullPath)
                        if ($item.Remote.IsOffline -and -not $hydrateBeforeDelete) {
                            $result.CloudOnlyDeletes++
                        }
                    }
                }
            }

            if ($ok) {
                $result.Applied++
                if ($item.Action -notlike 'Delete*') { $succeeded[$key] = $true }
            }
            else {
                # WhatIf, or a step that chose to defer.
                $result.Deferred++
            }
        }
        catch {
            $result.Failed++
            Write-Log ("action {0} failed for {1}: {2}" -f $item.Action, $item.RelPath, $_.Exception.Message) 'ERROR'
        }
    }

    # --- remove folders this pass emptied ---
    # After the deletes, not during: a folder is only judged once every file
    # the pass was going to remove from it is gone. Deferred files still sit
    # on disk, so a folder that is not finished emptying is simply left for a
    # later pass to revisit.
    $prunedDirs = 0
    if ($emptiedLocal.Count -gt 0) {
        $prunedDirs += Remove-EmptiedDirectory -Paths $emptiedLocal -StopAt $Link.LocalPath
    }
    if ($emptiedRemote.Count -gt 0) {
        $prunedDirs += Remove-EmptiedDirectory -Paths $emptiedRemote -StopAt $remotePath
    }
    if ($prunedDirs -gt 0) {
        Write-Log ("link {0}: removed {1} emptied folder(s)" -f $Link.Id, $prunedDirs)
    }

    # --- reclaim space on the OneDrive side, once for the whole tree ---
    # One attrib call rather than one per file. Files OneDrive has not finished
    # uploading simply stay on disk and are picked up by a later pass.
    if ($dehydrate) {
        $null = Set-TreeDehydrated -Root $remotePath
    }

    # --- commit the manifest ---
    # Only paths whose action succeeded are refreshed. Anything deferred or
    # failed keeps its previous entry so the next pass compares against the
    # same baseline instead of seeing a phantom conflict.
    if ($PSCmdlet.ShouldProcess($Link.Id, 'commit manifest')) {
        $localNow = Get-SideSnapshot -Root $Link.LocalPath -ExcludePatterns $ExcludePatterns
        $odNow    = Get-SideSnapshot -Root $remotePath     -ExcludePatterns $ExcludePatterns

        foreach ($key in $succeeded.Keys) {
            $L = $localNow[$key]; $O = $odNow[$key]
            if ($L -and $O) {
                $manifest[$key] = [pscustomobject]@{
                    RelPath       = $L.RelPath
                    LocalLength   = $L.Length
                    LocalWriteUtc = $L.WriteUtc
                    OdLength      = $O.Length
                    OdWriteUtc    = $O.WriteUtc
                }
            }
        }
        foreach ($key in $forgotten.Keys) { $manifest.Remove($key) }

        Write-Manifest -Path $manifestPath -Entries @($manifest.Values)
    }

    if (-not $result.Message) {
        $result.Message = ("applied {0}, deferred {1}, conflicts {2}, deleted {3}, failed {4}" -f `
                            $result.Applied, $result.Deferred, $result.Conflicts, $result.Deleted, $result.Failed)
    }
    # A link that moved nothing is reported at DEBUG. With three links and a ten
    # minute interval these were three lines of zeroes every pass -- more than
    # half the log -- and the pass-level summary already covers a quiet run.
    $quiet = ($result.Applied -eq 0 -and $result.Conflicts -eq 0 -and
              $result.Deleted -eq 0 -and $result.Failed -eq 0 -and -not $result.Aborted)
    Write-Log ("link {0}: {1}" -f $Link.Id, $result.Message) $(if ($quiet) { 'DEBUG' } else { 'INFO' })
    return $result
}
