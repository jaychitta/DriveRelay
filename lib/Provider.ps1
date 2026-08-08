<#
    Provider.ps1  --  what kind of folder is on the far side.

    The orchestrator copies between two ordinary paths, so most of it does not
    care what the remote side is. Only one behaviour is provider-specific:
    freeing space by turning a synced file back into a placeholder.

      Plain       No placeholder handling. Files are just files. Correct for
                  Google Drive in Mirror mode, Dropbox, a network share, a
                  second internal disk, a NAS, a USB drive.

      CloudFiles  Windows Cloud Files placeholders, driven by the PINNED and
                  UNPINNED attributes. Measured working with OneDrive on this
                  machine. Google Drive in Stream mode uses the same Windows
                  API and is expected to behave the same way, but that is not
                  verified here because Google Drive is not installed.

      Auto        Look at the folder and decide. This is the default.

    Detection failing in the cautious direction costs nothing: a cloud folder
    mistaken for Plain simply keeps its files on disk instead of freeing them.
    Nothing is copied wrongly and no data is at risk either way.
#>

$script:AttrOfflineP  = 0x1000
$script:AttrRecallP   = 0x400000
$script:AttrPinnedP   = 0x80000
$script:AttrUnpinnedP = 0x100000
$script:AttrReparse   = 0x400

function Get-RemotePath {
    <#
        Links written before multi-provider support used OneDrivePath. Read
        either, so existing links keep working untouched.
    #>
    param([Parameter(Mandatory)][object] $Link)

    if ($Link.PSObject.Properties['RemotePath'] -and $Link.RemotePath) { return $Link.RemotePath }
    if ($Link.PSObject.Properties['OneDrivePath']) { return $Link.OneDrivePath }
    return $null
}

function Test-CloudPlaceholderRoot {
    <#
        Does this folder look like it is backed by a cloud filter driver?

        Two signals, either is enough:
          * a file carrying Offline, RecallOnDataAccess, PINNED or UNPINNED
          * a directory that is a reparse point, which is how the cloud
            providers project their namespace

        Only a sample is examined -- walking a folder of 170,000 files to
        answer a yes/no question is not worth the wait.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [int] $SampleSize = 200
    )

    if (-not (Test-Path -LiteralPath $Root)) { return $false }

    try {
        $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if (([int] $rootItem.Attributes) -band $script:AttrReparse) { return $true }
    }
    catch { }

    $cloudMask = $script:AttrOfflineP -bor $script:AttrRecallP -bor
                 $script:AttrPinnedP  -bor $script:AttrUnpinnedP

    $seen = 0
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue)) {
        if (([int] $f.Attributes) -band $cloudMask)  { return $true }
        if ($f.PSIsContainer -and (([int] $f.Attributes) -band $script:AttrReparse)) { return $true }
        $seen++
        if ($seen -ge $SampleSize) { break }
    }

    return $false
}

function Resolve-LinkProvider {
    <#
        Returns 'CloudFiles' or 'Plain' for this link. An explicit setting is
        honoured; 'Auto' (the default) inspects the folder.
    #>
    param([Parameter(Mandatory)][object] $Link)

    $declared = 'Auto'
    if ($Link.PSObject.Properties['Provider'] -and $Link.Provider) { $declared = $Link.Provider }

    switch ($declared) {
        'Plain'      { return 'Plain' }
        'CloudFiles' { return 'CloudFiles' }
        default {
            $remote = Get-RemotePath -Link $Link
            if (-not $remote) { return 'Plain' }
            if (Test-CloudPlaceholderRoot -Root $remote) { return 'CloudFiles' }
            return 'Plain'
        }
    }
}

function Get-ProviderLabel {
    <#
        A friendly name for display. Best-effort only: it reads the path, so it
        is a hint for the user interface, never a basis for behaviour.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $p = $Path.ToLowerInvariant()
    if ($p -match 'onedrive')                 { return 'OneDrive' }
    if ($p -match 'google ?drive|my drive|shared drives') { return 'Google Drive' }
    if ($p -match 'dropbox')                  { return 'Dropbox' }
    if ($p -match 'box\\|\\box$')             { return 'Box' }
    if ($p -match 'icloud')                   { return 'iCloud' }
    if ($p -match 'nextcloud|owncloud')       { return 'Nextcloud' }
    if ($p -match '^\\\\')                    { return 'Network share' }
    return 'Folder'
}
