# Identify existing DriveRelay conflict copies by its timestamped filename format.
# Lists metadata on either side without reading content or hydrating placeholders.
function Get-LinkConflictCopies {
    param([Parameter(Mandatory)][object] $Link)
    $copies = @{}
    foreach ($side in @('Local', 'Remote')) {
        $rootPath = if ($side -eq 'Local') { $Link.LocalPath } else { Get-RemotePath -Link $Link }
        if (-not $rootPath -or -not (Test-Path -LiteralPath $rootPath)) { continue }
        $prefix = [IO.Path]::GetFullPath($rootPath).TrimEnd('\').Length + 1
        Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction Stop |
            ForEach-Object {
                $extension = [IO.Path]::GetExtension($_.Name)
                $stem = [IO.Path]::GetFileNameWithoutExtension($_.Name)
                if ($stem -notmatch '^(?<Original>.+) \(conflict from (?<Provider>.+) (?<Created>\d{4}-\d{2}-\d{2} \d{6})\)$') { return }
                $rel = $_.FullName.Substring($prefix)
                $key = $rel.ToLowerInvariant()
                if (-not $copies.ContainsKey($key)) {
                    $parent = [IO.Path]::GetDirectoryName($rel)
                    $original = $Matches.Original + $extension
                    if ($parent) { $original = Join-Path $parent $original }
                    $copies[$key] = [pscustomobject]@{
                        LinkId = $Link.Id; OriginalRelPath = $original; CopyRelPath = $rel
                        Created = $Matches.Created; Provider = $Matches.Provider
                        OriginalLocalPath = Join-Path $Link.LocalPath $original
                        OriginalRemotePath = Join-Path (Get-RemotePath -Link $Link) $original
                        CopyLocalPath = ''; CopyRemotePath = ''
                    }
                }
                if ($side -eq 'Local') { $copies[$key].CopyLocalPath = $_.FullName }
                else { $copies[$key].CopyRemotePath = $_.FullName }
            }
    }
    $copies.Values | Sort-Object CopyRelPath
}

function Format-ConflictCopies {
    param([object[]] $Copies)
    if (@($Copies).Count -eq 0) { return 'No DriveRelay conflict copies found.' }
    ($Copies | ForEach-Object {
        "Original: $($_.OriginalRelPath)`r`nDuplicate: $($_.CopyRelPath)`r`nOriginal local:  $($_.OriginalLocalPath)`r`nOriginal remote: $($_.OriginalRemotePath)`r`nDuplicate local:  $(if ($_.CopyLocalPath) { $_.CopyLocalPath } else { '(not present)' })`r`nDuplicate remote: $(if ($_.CopyRemotePath) { $_.CopyRemotePath } else { '(not present)' })"
    }) -join "`r`n`r`n"
}

function New-DeletionConflict {
    param([object] $Item, [object] $Link)
    [pscustomobject]@{
        LinkId = $Link.Id
        RelPath = $Item.RelPath
        DeletedSide = if ($Item.Local) { 'Remote' } else { 'Local' }
        SurvivingPath = if ($Item.Local) { $Item.Local.FullPath } else { $Item.Remote.FullPath }
        DeletedPath = if ($Item.Local) { Join-Path (Get-RemotePath -Link $Link) $Item.RelPath } else { Join-Path $Link.LocalPath $Item.RelPath }
        Reason = $Item.Reason
    }
}

function Get-LinkDeletionConflicts {
    param([object] $Link, [string] $StateRoot = $script:DefaultStateRoot, [string[]] $ExcludePatterns)
    # A live scan keeps review accurate after the user resolves a conflict.
    if (-not $Link.Seeded) { return }
    if ((Get-LinkAvailability -Link $Link).Blocking) { return }
    foreach ($item in (Compare-LinkState -Link $Link -StateRoot $StateRoot -ExcludePatterns $ExcludePatterns)) {
        if ($item.Action -eq 'DeletionConflict') { New-DeletionConflict -Item $item -Link $Link }
    }
}

function Format-DeletionConflicts {
    param([object[]] $Conflicts)
    $intro = 'These files were deleted on one side, but the surviving copy has changed metadata. DriveRelay has left both sides as they are. To keep the deletion, delete the surviving copy. To keep the file, deliberately restore it to the deleted path.'
    $rows = ($Conflicts | ForEach-Object {
        "File: $($_.RelPath)`r`nDeleted side: $($_.DeletedSide)`r`nSurviving copy: $($_.SurvivingPath)`r`nRestore to: $($_.DeletedPath)"
    }) -join "`r`n`r`n"
    return "$intro`r`n`r`n$rows"
}
