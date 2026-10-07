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
