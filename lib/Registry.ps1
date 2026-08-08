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
        try   { $mutex = New-Object System.Threading.Mutex($false, $script:RegistryMutexName) }
        catch { return (& $Body) }   # no mutex available; better to proceed than to fail closed

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
        [int] $SettleMinutes = 3,
        [int] $MaxDelete = 50,
        [bool] $Dehydrate = $true,
        [bool] $HydrateBeforeDelete = $false
    )

    if (Test-PathOverlap -A $Local -B $Remote) {
        throw 'The two sides of a link must not contain one another.'
    }

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
        Save-LinkRegistry -Links (@($links) + $link)
    }

    return $link

    }   # end Invoke-RegistryTransaction
}

function Remove-Link {
    <#
        Unregisters a pair. Files on both sides are left exactly as they are --
        this forgets the link, it does not delete anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Id)

    Invoke-RegistryTransaction {
        $links = @(Get-LinkRegistry)
        if (@($links | Where-Object { $_.Id -eq $Id }).Count -eq 0) {
            throw ("No link with id '{0}'." -f $Id)
        }

        if ($PSCmdlet.ShouldProcess($Id, 'unregister link (files untouched)')) {
            Save-LinkRegistry -Links @($links | Where-Object { $_.Id -ne $Id })
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
