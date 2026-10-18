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
. (Join-Path $PSScriptRoot 'FileIdentity.ps1')
$script:DefaultStateRoot = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) 'state' } else { 'state' }

function Get-SideSnapshot {
    <#
        Enumerate one side. Metadata only -- never opens a file.
        Returns a hashtable keyed by lower-cased relative path.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $ExcludePatterns
    )

    $map  = @{}
    $root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root)) { return $map }

    $prefix = $root.Length + 1

    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $name = $_.Name
            if (Test-FileExcluded -Name $name -Patterns $ExcludePatterns) { return }

            $rel = $_.FullName.Substring($prefix)
            $map[$rel.ToLowerInvariant()] = [pscustomobject]@{
                RelPath   = $rel
                FullPath  = $_.FullName
                Length    = $_.Length
                WriteUtc  = $_.LastWriteTimeUtc
                IsOffline = [bool](([int] $_.Attributes) -band 0x1000)
                FileId    = Get-FileIdentity -Path $_.FullName
            }
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

    # Temp-then-move: a half-written manifest would make the next pass
    # misread deletions as new files.
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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
        [string] $StateRoot = $script:DefaultStateRoot
    )

    $local    = Get-SideSnapshot -Root $Link.LocalPath              -ExcludePatterns $ExcludePatterns
    $od       = Get-SideSnapshot -Root (Get-RemotePath -Link $Link) -ExcludePatterns $ExcludePatterns
    $manifest = Read-Manifest -Path (Get-ManifestPath -LinkId $Link.Id -StateRoot $StateRoot)

    $keys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $local.Keys)    { $null = $keys.Add($k) }
    foreach ($k in $od.Keys)       { $null = $keys.Add($k) }
    foreach ($k in $manifest.Keys) { $null = $keys.Add($k) }

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
