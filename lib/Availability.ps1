<#
    Availability.ps1  --  is this link actually usable right now?

    A link can be unusable for reasons that look identical on the filesystem but
    mean very different things to the person using it:

      * the drive is not mounted            -- an external disk is unplugged,
                                               a network share is disconnected
      * the drive is there, the folder is not
                                            -- somebody deleted or renamed it
      * both paths exist, but the cloud client is not running
                                            -- files are placeholders that
                                               cannot be hydrated

    "Folder missing" covers all three if you only ask Test-Path, and that is not
    good enough to act on. An unplugged disk needs plugging in; a deleted folder
    needs a decision about the link; a stopped OneDrive needs starting. Telling
    someone "remote path missing" when their laptop is simply undocked is a bad
    answer to a question they did not ask.

    Nothing here ever creates a missing folder. A vanished path must never be
    read as "everything was deleted" -- the link is reported and skipped, which
    is the whole reason this file exists.
#>

# Cloud clients we can recognise, keyed by the label Get-ProviderLabel returns.
# Process names only -- we never talk to a service or an API.
$script:CloudClientProcesses = @{
    'OneDrive'     = @('OneDrive')
    'Google Drive' = @('GoogleDriveFS')
    'Dropbox'      = @('Dropbox')
    'Box'          = @('Box', 'BoxDrive')
    'iCloud'       = @('iCloudDrive', 'iCloudServices')
    'Nextcloud'    = @('nextcloud', 'owncloud')
}

function Test-DriveMounted {
    <#
        Is the volume (or UNC server root) behind this path actually present?

        Deliberately cheap and non-committal: a drive letter that is not in the
        filesystem provider's list is not mounted. For a UNC path we test the
        share root rather than trying to be clever about servers.
    #>
    param([Parameter(Mandatory)][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        # UNC: \\server\share\...  -- test \\server\share
        if ($Path -match '^\\\\([^\\]+)\\([^\\]+)') {
            return (Test-Path -LiteralPath ("\\{0}\{1}" -f $Matches[1], $Matches[2]))
        }

        $qualifier = Split-Path -Qualifier $Path -ErrorAction Stop   # e.g. 'D:'
        if (-not $qualifier) { return $true }
        return (Test-Path -LiteralPath ($qualifier + '\'))
    }
    catch {
        # No qualifier (relative path) or an unparseable path: fall back to the
        # path itself and let the caller's Test-Path decide.
        return $true
    }
}

function Test-CloudClientRunning {
    <#
        Is the desktop client for this provider running?

        Returns $null -- not $false -- when the provider is one we do not know
        how to check. "I cannot tell" and "it is not running" are different
        answers, and reporting the second when we mean the first would send
        someone looking for a problem that is not there.
    #>
    param([Parameter(Mandatory)][string] $ProviderLabel)

    if (-not $script:CloudClientProcesses.ContainsKey($ProviderLabel)) { return $null }

    foreach ($name in $script:CloudClientProcesses[$ProviderLabel]) {
        try {
            if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        }
        catch { }
    }
    return $false
}

function Get-LinkAvailability {
    <#
        One answer about whether a pass should run over this link, and what to
        say if it should not.

        Returns:
          Ok        can a pass run at all
          State     Ready | DriveOffline | FolderMissing | ClientNotRunning | NoRemote
          Summary   one line fit for a status badge or a tray tooltip
          Detail    the longer explanation, including what to do about it
          Blocking  whether this stops the pass (as opposed to merely degrading it)

        A stopped cloud client is reported but does not block: copies from the
        local side still work and still land on disk for the client to upload
        when it comes back. What it does change is hydration -- see
        Wait-Hydrated, which fails fast rather than spending its timeout waiting
        for a client that is not there.
    #>
    param([Parameter(Mandatory)][object] $Link)

    $localPath  = $Link.LocalPath
    $remotePath = Get-RemotePath -Link $Link

    if (-not $remotePath) {
        return [pscustomobject]@{
            Ok = $false; State = 'NoRemote'; Blocking = $true
            Summary = 'No remote folder configured'
            Detail  = "Link '$($Link.Id)' has no remote path. Remove and re-add it."
        }
    }

    # --- drives before folders: an unmounted disk is not a missing folder ---
    foreach ($side in @(
        [pscustomobject]@{ Name = 'Local';  Path = $localPath }
        [pscustomobject]@{ Name = 'Remote'; Path = $remotePath }
    )) {
        if (-not (Test-DriveMounted -Path $side.Path)) {
            $qualifier = try { Split-Path -Qualifier $side.Path -ErrorAction Stop } catch { $side.Path }
            return [pscustomobject]@{
                Ok = $false; State = 'DriveOffline'; Blocking = $true
                Summary = ("Drive {0} is not available" -f $qualifier)
                Detail  = ("The {0} side of '{1}' is on {2}, which is not mounted right now " +
                           "({3}). Nothing was copied or deleted -- an absent drive is never " +
                           "read as 'everything was deleted'. Reconnect it and the next pass " +
                           "continues where it left off.") -f
                          $side.Name.ToLower(), $Link.Id, $qualifier, $side.Path
            }
        }
    }

    # --- drive is there, so a missing folder is a real missing folder ---
    foreach ($side in @(
        [pscustomobject]@{ Name = 'Local';  Path = $localPath }
        [pscustomobject]@{ Name = 'Remote'; Path = $remotePath }
    )) {
        if (-not (Test-Path -LiteralPath $side.Path)) {
            return [pscustomobject]@{
                Ok = $false; State = 'FolderMissing'; Blocking = $true
                Summary = ("{0} folder is missing" -f $side.Name)
                Detail  = ("The {0} folder of '{1}' is gone: {2}. The drive is mounted, so this " +
                           "is the folder itself -- deleted, renamed, or not yet re-created by " +
                           "the cloud client. Nothing was copied or deleted. Restore the folder, " +
                           "or remove the link with 'rm {1}' if it is no longer wanted.") -f
                          $side.Name.ToLower(), $Link.Id, $side.Path
            }
        }
    }

    # --- both sides present: is the cloud client actually running? ---
    $label   = Get-ProviderLabel -Path $remotePath
    $running = Test-CloudClientRunning -ProviderLabel $label

    if ($running -eq $false) {
        return [pscustomobject]@{
            Ok = $true; State = 'ClientNotRunning'; Blocking = $false
            Summary = ("{0} is not running" -f $label)
            Detail  = ("{0} does not appear to be running. Changes made here are still copied " +
                       "to the {0} folder and will upload when it starts. Files that live only " +
                       "in the cloud cannot be fetched until then, so those are deferred rather " +
                       "than waited on.") -f $label
        }
    }

    return [pscustomobject]@{
        Ok = $true; State = 'Ready'; Blocking = $false
        Summary = 'Ready'
        Detail  = ''
    }
}

function Get-UnavailableLinks {
    <#
        Every registered, enabled link that is not fully ready, with its reason.
        Used by the tray and the dashboard to say something specific rather than
        a generic "needs attention".
    #>
    param([object[]] $Links)

    if (-not $Links) { $Links = @(Get-LinkRegistry) }

    $out = @()
    foreach ($l in @($Links | Where-Object { $_.Enabled })) {
        try {
            $a = Get-LinkAvailability -Link $l
            if ($a.State -ne 'Ready') {
                $out += [pscustomobject]@{
                    Id = $l.Id; State = $a.State; Summary = $a.Summary
                    Detail = $a.Detail; Blocking = $a.Blocking
                }
            }
        }
        catch { }
    }
    return ,$out
}
