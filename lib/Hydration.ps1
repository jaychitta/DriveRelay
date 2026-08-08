<#
    Hydration.ps1  --  OneDrive placeholder control.

    Behaviour below was measured on this machine (Windows 11 26100, OneDrive
    client from C:\Program Files\Microsoft OneDrive) before being relied upon:

      fresh local file            0x20      Archive, no cloud flags
      attrib +U -P, not uploaded  0x100020  UNPINNED            <- request only
      once upload completed       0x501620  Offline, Recall, UNPINNED
      attrib +P -U                0x80420   PINNED              <- content back
      Get-Item / enumeration      unchanged                     <- safe
      Get-FileHash                Offline cleared               <- forces download

    Two consequences drive the whole design:

      1. UNPINNED is a *request*; Offline is the *receipt*. OneDrive will not
         convert a file to a placeholder until the service holds its content,
         so "did Offline appear?" is a reliable upload confirmation. Never
         assume an upload succeeded -- wait for the receipt.

      2. Reading content hydrates. Change detection must use size and
         LastWriteTime only. Never hash a file on the OneDrive side.
#>

# FILE_ATTRIBUTE_* values relevant to cloud files.
$script:AttrOffline  = 0x1000     # content is not local
$script:AttrRecall   = 0x400000   # RECALL_ON_DATA_ACCESS
$script:AttrPinned   = 0x80000    # "always keep on this device"
$script:AttrUnpinned = 0x100000   # "free up space" requested

function Get-CloudState {
    <#
        Metadata only -- this never triggers a download.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $a    = [int] $item.Attributes

    [pscustomobject]@{
        Path        = $item.FullName
        Raw         = $a
        IsOffline   = [bool]($a -band $script:AttrOffline)
        IsRecall    = [bool]($a -band $script:AttrRecall)
        IsPinned    = [bool]($a -band $script:AttrPinned)
        IsUnpinned  = [bool]($a -band $script:AttrUnpinned)
        Length      = $item.Length
        LastWrite   = $item.LastWriteTime
    }
}

function Test-Offline {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-CloudState -Path $Path).IsOffline
}

function Set-Dehydrated {
    <#
        Request "free up space". This only marks intent -- call
        Wait-UploadReceipt to find out whether it actually took effect.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Path)

    if ($PSCmdlet.ShouldProcess($Path, 'dehydrate (attrib +U -P)')) {
        & attrib.exe +U -P $Path
    }
}

function Set-Hydrated {
    <#
        Request "always keep on this device", which pulls content down.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Path)

    if ($PSCmdlet.ShouldProcess($Path, 'hydrate (attrib +P -U)')) {
        & attrib.exe +P -U $Path
    }
}

function Set-TreeDehydrated {
    <#
        Dehydrate a whole tree in one call.

        Per-file dehydration means one attrib.exe per file plus a poll for the
        receipt; across tens of thousands of files that costs hours. attrib
        recurses natively, so the same work becomes a single process.

        No receipt is waited for here, and that is safe rather than sloppy:
        OneDrive refuses to dehydrate a file it has not got, so the worst case
        is that a file stays on disk and is retried next pass. Dehydration
        cannot lose data -- waiting only tells us sooner.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Root, 'dehydrate tree (attrib +U -P /S /D)')) { return $false }

    & attrib.exe +U -P (Join-Path $Root '*') /S /D
    return $true
}

function Wait-UploadReceipt {
    <#
        Ask for dehydration, then wait for Offline to appear.

        Returns $true only when the receipt arrives, which means the service
        holds the content. Returns $false on timeout -- the caller should leave
        the file alone and retry on a later pass. A $false here is not an
        error; OneDrive may simply be paused, offline, or still working.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $TimeoutSeconds = 600,
        [int] $PollSeconds    = 5
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'dehydrate and await upload receipt')) {
        return $false
    }

    Set-Dehydrated -Path $Path -Confirm:$false

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if ((Get-CloudState -Path $Path).IsOffline) { return $true }
        }
        catch {
            # File vanished mid-wait; nothing to confirm.
            return $false
        }
        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

function Wait-Hydrated {
    <#
        Ask for content and wait until it is actually local, so the file can be
        copied out to the working side.

        Returns $true when Offline has cleared.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $TimeoutSeconds = 1800,
        [int] $PollSeconds    = 5
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'hydrate and await content')) {
        return $false
    }

    if (-not (Test-Offline -Path $Path)) { return $true }

    Set-Hydrated -Path $Path -Confirm:$false

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (-not (Get-CloudState -Path $Path).IsOffline) { return $true }
        }
        catch {
            return $false
        }
        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}
