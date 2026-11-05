<#
    Manifest.ps1  --  what changed, and on which side.

    The manifest records the state of both sides at the end of the last
    successful pass. Without it, presence and absence are ambiguous: a file
    present locally and missing on the remote side is either something you
    just created here, or something you deleted there. Comparing the two sides
    alone cannot tell those apart, and guessing wrong either resurrects deleted
    files or destroys new ones.

    With the manifest the question becomes answerable: was it here last time?

    Comparison uses size and last-write-time only. A cloud-backed remote side
    must never be hashed -- reading a placeholder's content downloads it
    (measured; see Hydration.ps1). Enumeration is metadata only and is safe.

    "Od" in the field names below is historical and simply means the remote
    side. The names are kept so manifests written by earlier versions still
    load rather than being read as a folder full of new files.
#>

# Filesystem timestamps are not exact across copies; treat writes within this
# many seconds of each other as the same moment.
$script:TimeToleranceSeconds = 2

# Where a delete goes on a volume with no Recycle Bin (see Remove-FileSafely).
# It sits at each link root and is never part of a snapshot.
$script:DeletedFolderName = '.driverelay-deleted'
. (Join-Path $PSScriptRoot 'FileIdentity.ps1')

function Test-LinkDirectory {
    # A junction, mount point or directory symbolic link. LinkType is $null
    # for other reparse points such as cloud placeholder folders. If it cannot
    # be read, the folder is walked as before.
    param([Parameter(Mandatory)][object] $Item)
    try { return (@('Junction', 'SymbolicLink') -contains [string] $Item.LinkType) }
    catch { return $false }
}

function Test-UnderSkippedLink {
    param([Parameter(Mandatory)][string] $Key,
          [System.Collections.Generic.List[string]] $Prefixes)
    if ($null -eq $Prefixes) { return $false }
    foreach ($p in $Prefixes) { if ($Key.StartsWith($p, [StringComparison]::Ordinal)) { return $true } }
    return $false
}
$script:DefaultStateRoot = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) 'state' } else { 'state' }

function Get-SideSnapshot {
    <#
        Enumerate one side. Metadata only -- never opens a file.
        Returns a hashtable keyed by lower-cased relative path.

        A listing that hit an error is incomplete, and an incomplete listing is
        dangerous: a tracked file missing from it reads as "deleted on this
        side" and its counterpart is deleted. So any enumeration error (access
        denied, path too long, a cloud provider that cannot list a folder)
        throws by default and the link is skipped for this pass. -AllowPartial
        is only for callers where a missing entry is harmless -- the post-pass
        manifest refresh, which then keeps that path's previous baseline.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $ExcludePatterns,
        [switch] $AllowPartial,

        # Receives the relative path (lower-cased, trailing '\') of every
        # junction or directory symbolic link that was not followed.
        [System.Collections.Generic.List[string]] $SkippedLinks
    )

    $map  = @{}
    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root)) { return $map }

    $prefix = $root.Length + 1
    $listErrors = New-Object System.Collections.ArrayList
    $deletedFolder = Join-Path $root $script:DeletedFolderName

    # Walked one folder at a time rather than with -Recurse: Windows
    # PowerShell 5.1 follows junctions and directory symbolic links when
    # recursing, which would sync -- and delete through -- folders that live
    # outside the link root, or loop on a link back into it. Cloud placeholder
    # folders are reparse points too, but not links, and are walked normally.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        $dirErrors = $null
        $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable dirErrors)
        foreach ($e in @($dirErrors)) { if ($e) { $null = $listErrors.Add($e) } }

        foreach ($c in $children) {
            if ($c.PSIsContainer) {
                if ($c.FullName -eq $deletedFolder) { continue }
                if ((([int] $c.Attributes) -band 0x400) -and (Test-LinkDirectory -Item $c)) {
                    if ($null -ne $SkippedLinks) {
                        $SkippedLinks.Add($c.FullName.Substring($prefix).ToLowerInvariant() + '\')
                    }
                    continue
                }
                $pending.Push($c.FullName)
                continue
            }

            if (Test-FileExcluded -Name $c.Name -Patterns $ExcludePatterns) { continue }

            $rel = $c.FullName.Substring($prefix)
            $map[$rel.ToLowerInvariant()] = [pscustomobject]@{
                RelPath   = $rel
                FullPath  = $c.FullName
                Length    = $c.Length
                WriteUtc  = $c.LastWriteTimeUtc
                IsOffline = [bool](([int] $c.Attributes) -band 0x1000)
                FileId    = Get-FileIdentity -Path $c.FullName
            }
        }
    }

    if (-not $AllowPartial -and $listErrors.Count -gt 0) {
        $first = $listErrors[0]
        $where = if ($first.TargetObject) { [string] $first.TargetObject } else { $root }
        throw (("could not list every file under {0} ({1} error(s); first at {2}: {3}). " +
                "Nothing was copied or deleted -- an incomplete listing is never read as deletions.") -f
               $root, $listErrors.Count, $where, $first.Exception.Message)
    }

    return $map
}

function Get-ManifestPath {
    param([Parameter(Mandatory)][string] $LinkId,
          [string] $StateRoot = $script:DefaultStateRoot)
    return (Join-Path (Join-Path $StateRoot $LinkId) 'manifest.json')
}

function Get-ExistingCopyParent {
    # Remember the closest existing destination directory at planning time.
    # Its disappearance during a long pass is a deletion, not permission to
    # recreate it for a previously planned copy.
    param([Parameter(Mandatory)][string] $Path)
    $parent = Split-Path -Parent $Path
    while ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $parent = Split-Path -Parent $parent
    }
    return $parent
}

function Read-Manifest {
    <#
        Returns a hashtable keyed by lower-cased relative path. An absent
        manifest is an empty hashtable, which makes every path look new -- the
        correct reading for a link that has never run.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }

    # -InputObject, not the pipeline: piping a JSON array through @() can leave
    # the whole array as a single element, so each "entry" comes back as an
    # array and every property reads as a collection.
    $parsed = ConvertFrom-Json -InputObject $raw
    if ($parsed -isnot [System.Array]) { $parsed = @($parsed) }

    foreach ($e in $parsed) {
        if (-not $e.RelPath) { continue }
        $map[$e.RelPath.ToLowerInvariant()] = [pscustomobject]@{
            RelPath      = $e.RelPath
            LocalLength  = [int64] $e.LocalLength
            LocalWriteUtc = ConvertFrom-IsoUtc $e.LocalWriteUtc
            OdLength     = [int64] $e.OdLength
            OdWriteUtc   = ConvertFrom-IsoUtc $e.OdWriteUtc
            LocalFileId  = $e.LocalFileId
            OdFileId     = $e.OdFileId
        }
    }
    return $map
}

function ConvertFrom-IsoUtc {
    param([object] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [datetime]::MinValue }
    try {
        # Windows PowerShell's ConvertFrom-Json turns ISO timestamps into
        # local DateTime objects. Keep that Kind long enough to convert back;
        # declaring this parameter as [string] first silently discarded it.
        if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
        return [datetime]::Parse([string]$Value,
                                 [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    catch { return [datetime]::MinValue }
}

function ConvertTo-IsoUtc {
    param([datetime] $Value)
    return $Value.ToUniversalTime().ToString('o')
}

function Write-Manifest {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Entries
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $rows = foreach ($e in $Entries) {
        [pscustomobject]@{
            RelPath       = $e.RelPath
            LocalLength   = $e.LocalLength
            LocalWriteUtc = ConvertTo-IsoUtc $e.LocalWriteUtc
            OdLength      = $e.OdLength
            OdWriteUtc    = ConvertTo-IsoUtc $e.OdWriteUtc
            LocalFileId   = $e.LocalFileId
            OdFileId      = $e.OdFileId
        }
    }

    if (@($rows).Count -eq 0) {
        $json = '[]'
    }
    else {
        $json = ConvertTo-Json -InputObject ([object[]] $rows) -Depth 4
        if (-not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
    }

    # Temp, flushed to disk, then an atomic replace that keeps the previous
    # version as .bak. Move-Item -Force deletes the destination before it
    # renames, so a crash in between left no manifest at all, and an
    # unflushed write could leave an empty one after a power cut -- both of
    # which read as "no history". See Repair-LinkManifest for the recovery.
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $tmp  = "$full.tmp"
    $bytes = (New-Object System.Text.UTF8Encoding -ArgumentList $true).GetBytes($json)
    $stream = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $preamble = (New-Object System.Text.UTF8Encoding -ArgumentList $true).GetPreamble()
        $stream.Write($preamble, 0, $preamble.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }

    # A reader (the dashboard's background scan) can briefly hold the file;
    # retry a short while rather than failing a pass that has already acted.
    $attempt = 0
    while ($true) {
        try {
            if ([IO.File]::Exists($full)) { [IO.File]::Replace($tmp, $full, "$full.bak") }
            else                          { [IO.File]::Move($tmp, $full) }
            break
        }
        catch {
            $attempt++
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Move-ManifestAside {
    <#
        A re-added link reuses its old id and so its old state folder. Its
        history -- the manifest and the .bak/.tmp copies that Repair-LinkManifest
        would restore from -- belongs to the previous registration and must
        not be read as this one's. Returns the set-aside manifest path, or $null.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $aside = $null
    foreach ($suffix in @('', '.bak', '.tmp')) {
        $p = "$Path$suffix"
        if (Test-Path -LiteralPath $p) {
            $dest = "$Path.superseded-$stamp$suffix"
            Move-Item -LiteralPath $p -Destination $dest -Force
            if (-not $suffix) { $aside = $dest }
        }
    }
    return $aside
}

function Test-ManifestFile {
    # True when the file exists, is not empty, and parses as JSON.
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $null = ConvertFrom-Json -InputObject $raw
        return $true
    }
    catch { return $false }
}

function Get-ManifestProblem {
    <#
        For a link that has already been seeded, the manifest is the only proof
        of what existed at the last pass. Missing, empty or unreadable, every
        file would look new: deletions would be undone and every difference
        would become a conflict. Returns a description, or $null when fine.
        An unseeded link has no manifest yet, which is correct.
    #>
    param([Parameter(Mandatory)][object] $Link,
          [string] $StateRoot = $script:DefaultStateRoot)
    if (-not $Link.Seeded) { return $null }
    $path = Get-ManifestPath -LinkId $Link.Id -StateRoot $StateRoot
    if (Test-ManifestFile -Path $path) { return $null }
    $state = if (Test-Path -LiteralPath $path) { 'empty or unreadable' } else { 'missing' }
    return ("the sync history for '{0}' is {1} ({2})" -f $Link.Id, $state, $path)
}

function Repair-LinkManifest {
    <#
        Before a pass: if a seeded link's manifest is unusable, restore it from
        the newest intact copy -- the .tmp a crashed write completed, else the
        .bak of the previous pass. An older baseline is safe: anything it does
        not know about reads as new (copied or kept as a conflict), never as
        deleted. With no intact copy the link stops rather than guessing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object] $Link,
          [string] $StateRoot = $script:DefaultStateRoot)

    $problem = Get-ManifestProblem -Link $Link -StateRoot $StateRoot
    if (-not $problem) { return [pscustomobject]@{ Ok = $true; Message = '' } }

    $path = Get-ManifestPath -LinkId $Link.Id -StateRoot $StateRoot
    foreach ($candidate in @("$path.tmp", "$path.bak")) {
        if (-not (Test-ManifestFile -Path $candidate)) { continue }
        if (-not $PSCmdlet.ShouldProcess($path, "restore sync history from $candidate")) { break }
        if (Test-Path -LiteralPath $path) {
            Move-Item -LiteralPath $path -Destination ("{0}.unreadable-{1}" -f $path, (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        }
        Copy-Item -LiteralPath $candidate -Destination $path -Force
        return [pscustomobject]@{
            Ok = $true
            Message = ("{0}; restored from {1}" -f $problem, (Split-Path -Leaf $candidate))
        }
    }

    return [pscustomobject]@{
        Ok = $false
        Message = (("{0}, and no intact copy was found. Nothing was copied or deleted: without it, " +
                    "deleted files would come back. Restore the file from a backup, or remove and " +
                    "re-add the link to rebuild it (files deleted since the last sync may reappear).") -f $problem)
    }
}

function Test-SameFileState {
    <#
        Same size and same write time within tolerance. This is as close to
        "unchanged" as we can get without reading content, which is a line we
        do not cross on the remote side.
    #>
    param([int64] $LengthA, [datetime] $WriteA,
          [int64] $LengthB, [datetime] $WriteB)

    if ($LengthA -ne $LengthB) { return $false }
    $delta = [math]::Abs(($WriteA - $WriteB).TotalSeconds)
    return ($delta -le $script:TimeToleranceSeconds)
}

function Compare-LinkState {
    <#
        Classify every path across both sides and the manifest.

        Actions produced:
          InSync         nothing to do
          CopyToRemote local is newer or new
          CopyToLocal    remote side is newer or new
          MoveRemote     unchanged tracked file moved locally
          MoveLocal      unchanged tracked file moved remotely
          DeleteLocal    removed on the remote side, local unchanged since
          DeleteRemote removed locally, remote side unchanged since
          Conflict       both sides changed since the last pass -- keep both
          DeletionConflict one side deleted, survivor metadata changed -- review

        Deletion is only ever proposed when the manifest proves the file
        existed at the last pass. Absence alone never causes a delete.
    #>
    param(
        [Parameter(Mandatory)][object] $Link,
        [string[]] $ExcludePatterns,
        [string] $StateRoot = $script:DefaultStateRoot,

        # Optional: receives the junctions/symbolic links that were not
        # followed on either side, so callers can report them.
        [System.Collections.Generic.List[string]] $SkippedLinks
    )

    if ($null -eq $SkippedLinks) { $SkippedLinks = New-Object 'System.Collections.Generic.List[string]' }
    $local    = Get-SideSnapshot -Root $Link.LocalPath              -ExcludePatterns $ExcludePatterns -SkippedLinks $SkippedLinks
    $od       = Get-SideSnapshot -Root (Get-RemotePath -Link $Link) -ExcludePatterns $ExcludePatterns -SkippedLinks $SkippedLinks
    $manifest = Read-Manifest -Path (Get-ManifestPath -LinkId $Link.Id -StateRoot $StateRoot)

    # Anything under a link that was not followed -- on either side -- is left
    # out entirely: no copy, no delete, and its manifest entry is kept. Files
    # synced through a junction by earlier versions must not now read as
    # deleted just because the junction is no longer walked.
    $keys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $local.Keys)    { if (-not (Test-UnderSkippedLink -Key $k -Prefixes $SkippedLinks)) { $null = $keys.Add($k) } }
    foreach ($k in $od.Keys)       { if (-not (Test-UnderSkippedLink -Key $k -Prefixes $SkippedLinks)) { $null = $keys.Add($k) } }
    foreach ($k in $manifest.Keys) { if (-not (Test-UnderSkippedLink -Key $k -Prefixes $SkippedLinks)) { $null = $keys.Add($k) } }

    $results = New-Object System.Collections.ArrayList

    foreach ($k in $keys) {
        $L = $local[$k]
        $O = $od[$k]
        $M = $manifest[$k]

        $rel = if ($L) { $L.RelPath } elseif ($O) { $O.RelPath } else { $M.RelPath }

        $action = $null
        $reason = ''

        if ($L -and $O) {
            $lChanged = -not ($M -and (Test-SameFileState $L.Length $L.WriteUtc $M.LocalLength $M.LocalWriteUtc))
            $oChanged = -not ($M -and (Test-SameFileState $O.Length $O.WriteUtc $M.OdLength  $M.OdWriteUtc))

            if (-not $M) {
                # Never seen before but present on both sides: adopt if they
                # already match, otherwise it is a genuine disagreement.
                if (Test-SameFileState $L.Length $L.WriteUtc $O.Length $O.WriteUtc) {
                    $action = 'InSync'; $reason = 'identical, adopting into manifest'
                }
                else {
                    $action = 'Conflict'; $reason = 'both sides present and differ, no history'
                }
            }
            elseif ($lChanged -and $oChanged) { $action = 'Conflict';       $reason = 'changed on both sides' }
            elseif ($lChanged)                { $action = 'CopyToRemote'; $reason = 'changed locally' }
            elseif ($oChanged)                { $action = 'CopyToLocal';    $reason = 'changed on remote side' }
            else                              { $action = 'InSync';         $reason = 'unchanged' }
        }
        elseif ($L -and -not $O) {
            if (-not $M) {
                $action = 'CopyToRemote'; $reason = 'new locally'
            }
            elseif (Test-SameFileState $L.Length $L.WriteUtc $M.LocalLength $M.LocalWriteUtc) {
                $action = 'DeleteLocal'; $reason = 'deleted on remote side, local unchanged'
            }
            else {
                # Preserve the possible edit without undoing the deletion.
                $action = 'DeletionConflict'; $reason = 'deleted on remote side but local metadata changed; review required'
            }
        }
        elseif ($O -and -not $L) {
            if (-not $M) {
                $action = 'CopyToLocal'; $reason = 'new on remote side'
            }
            elseif (Test-SameFileState $O.Length $O.WriteUtc $M.OdLength $M.OdWriteUtc) {
                $action = 'DeleteRemote'; $reason = 'deleted locally, remote side unchanged'
            }
            else {
                $action = 'DeletionConflict'; $reason = 'deleted locally but remote metadata changed; review required'
            }
        }
        else {
            # In the manifest but gone from both sides: already reconciled.
            $action = 'Forget'; $reason = 'absent from both sides'
        }

        $null = $results.Add([pscustomobject]@{
            RelPath   = $rel
            Action    = $action
            Reason    = $reason
            Local     = $L
            Remote    = $O
            Manifest  = $M
            LocalParent = if ($action -in @('CopyToLocal','Conflict')) { Get-ExistingCopyParent -Path (Join-Path $Link.LocalPath $rel) } else { $null }
            RemoteParent = if ($action -in @('CopyToRemote','Conflict')) { Get-ExistingCopyParent -Path (Join-Path (Get-RemotePath -Link $Link) $rel) } else { $null }
        })
    }

    # Pair a tracked disappearance with a new path only when the moving side's
    # NTFS ID survived and BOTH versions still match their own baseline. Size
    # and time alone cannot prove a move. Require unique IDs, including history,
    # so hard links or a suspect manifest cannot choose the wrong counterpart.
    $paired = @{}
    foreach ($direction in @('Remote', 'Local')) {
        $side = if ($direction -eq 'Remote') { 'Local' } else { 'Remote' }
        $idField = if ($side -eq 'Local') { 'LocalFileId' } else { 'OdFileId' }
        $lengthField = if ($side -eq 'Local') { 'LocalLength' } else { 'OdLength' }
        $writeField = if ($side -eq 'Local') { 'LocalWriteUtc' } else { 'OdWriteUtc' }
        $ids = @{}
        foreach ($row in $results) {
            $snapshot = $row.$side
            if ($snapshot -and $snapshot.FileId) {
                if (-not $ids.ContainsKey($snapshot.FileId)) { $ids[$snapshot.FileId] = @() }
                $ids[$snapshot.FileId] += $row
            }
        }
        $historyCounts = @{}
        foreach ($entry in $manifest.Values) {
            if ($entry.$idField) { $historyCounts[$entry.$idField]++ }
        }
        foreach ($old in $results) {
            if ($old.Action -ne "Delete$direction") { continue }
            $id = $old.Manifest.$idField
            if (-not $id -or $historyCounts[$id] -ne 1 -or -not $ids.ContainsKey($id) -or $ids[$id].Count -ne 1) { continue }
            $new = $ids[$id][0]
            if ($new.Action -ne "CopyTo$direction" -or $new.Manifest) { continue }
            $counterpart = $old.$direction
            $counterpartIdField = if ($direction -eq 'Remote') { 'OdFileId' } else { 'LocalFileId' }
            if (-not $counterpart.FileId -or $counterpart.FileId -ne $old.Manifest.$counterpartIdField) { continue }
            if (-not (Test-SameFileState $new.$side.Length $new.$side.WriteUtc $old.Manifest.$lengthField $old.Manifest.$writeField)) { continue }
            $new.Action = "Move$direction"
            $new.Reason = "moved on $($side.ToLowerInvariant()) side: $($old.RelPath) -> $($new.RelPath)"
            $new | Add-Member -NotePropertyName OldRelPath -NotePropertyValue $old.RelPath
            $new | Add-Member -NotePropertyName MoveSource -NotePropertyValue $counterpart
            $paired[$old.RelPath.ToLowerInvariant()] = $true
        }
    }
    return ,@($results | Where-Object { -not $paired.ContainsKey($_.RelPath.ToLowerInvariant()) } | Sort-Object Action, RelPath)
}

function Test-ActionReady {
    <#
        Classification says what should happen; this says whether it can happen
        now. A file still being written, or held open by Tally or Excel, is not
        ready and is left for a later pass.

        Only the source side is gated: we never read a file someone else is
        using.
    #>
    param(
        [Parameter(Mandatory)][object] $Item,
        [int] $SettleMinutes = 3
    )

    switch ($Item.Action) {
        'MoveRemote' { $src = $Item.Local }
        'MoveLocal'  { $src = $Item.Remote }
        'CopyToRemote' { $src = $Item.Local }
        'CopyToLocal'    { $src = $Item.Remote }
        default          { return [pscustomobject]@{ Ready = $true; Reason = 'no source read required' } }
    }

    if (-not $src) { return [pscustomobject]@{ Ready = $false; Reason = 'source vanished' } }

    if (-not (Test-FileSettled -Path $src.FullPath -SettleMinutes $SettleMinutes)) {
        return [pscustomobject]@{ Ready = $false; Reason = 'still settling' }
    }
    if (Test-FileLocked -Path $src.FullPath) {
        return [pscustomobject]@{ Ready = $false; Reason = 'held open' }
    }

    if ($Item.Action -in @('MoveLocal', 'MoveRemote')) {
        if (-not (Test-FileSettled -Path $Item.MoveSource.FullPath -SettleMinutes $SettleMinutes)) {
            return [pscustomobject]@{ Ready = $false; Reason = 'counterpart still settling' }
        }
        if (Test-FileLocked -Path $Item.MoveSource.FullPath) {
            return [pscustomobject]@{ Ready = $false; Reason = 'counterpart held open' }
        }
    }

    return [pscustomobject]@{ Ready = $true; Reason = 'ok' }
}
