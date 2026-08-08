<#
    Settle.ps1  --  decides when a file is safe to touch.

    A file is eligible only when it is not excluded, not held open by anything,
    and has been left alone for the link's settle window. Anything failing these
    is skipped and retried on a later pass -- never copied mid-write.

    This is what keeps Tally companies and open workbooks intact: an application
    holding the file blocks only that file, not the rest of the link.
#>

function Test-FileExcluded {
    <#
        Transient artefacts that are never worth syncing.
        $Patterns are simple wildcard patterns matched against the file name.
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [string[]] $Patterns
    )

    if (-not $Patterns) { return $false }
    foreach ($p in $Patterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Test-FileLocked {
    <#
        True when something else holds the file open.

        Detection works by asking for exclusive access: if any other handle
        exists, the open fails. An indexer or antivirus can cause a false
        positive, which is harmless -- the file is simply retried next pass.

        A dehydrated placeholder is reported as unlocked without being opened.
        It has no local content, so no application can be editing it, and
        opening it for read would trigger the download this design exists to
        avoid.
    #>
    param([Parameter(Mandatory)][string] $Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return $true   # cannot inspect it; treat as unsafe
    }

    if (([int] $item.Attributes) -band 0x1000) { return $false }   # Offline

    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
                                         [IO.FileAccess]::Read,
                                         [IO.FileShare]::None)
        return $false
    }
    catch [IO.IOException] {
        return $true
    }
    catch {
        return $true
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Test-FileSettled {
    <#
        True when the file has not changed for at least $SettleMinutes.

        This is the "reasonable time of suspense" -- a file saved and closed
        becomes eligible once it has been quiet long enough that we can be
        confident the application has finished with it.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $SettleMinutes = 3
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return $false
    }

    $age = (Get-Date) - $item.LastWriteTime
    return ($age.TotalMinutes -ge $SettleMinutes)
}

function Test-FileEligible {
    <#
        The single gate the sync pass asks about each file.
        Returns an object so callers can report *why* something was skipped
        rather than silently ignoring it.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $SettleMinutes = 3,
        [string[]] $ExcludePatterns
    )

    $name = Split-Path -Leaf $Path

    if (Test-FileExcluded -Name $name -Patterns $ExcludePatterns) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'excluded' }
    }
    if (-not (Test-FileSettled -Path $Path -SettleMinutes $SettleMinutes)) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'still settling' }
    }
    if (Test-FileLocked -Path $Path) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'held open' }
    }

    return [pscustomobject]@{ Eligible = $true; Reason = 'ok' }
}
