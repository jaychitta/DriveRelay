<#
    DriveRelay.ps1  --  Drive Relay

    Keeps a local working folder and a cloud drive folder in step, so you
    can work on plain NTFS at full speed while the cloud client still holds
    a copy.

    Both sides are ordinary paths. This script never talks to a network:
    it copies between folders, and the cloud client uploads from its side
    as it normally would.

    `check` reports what would happen and writes nothing. `sync` applies it.
    Run sync with -WhatIf first on anything you care about.

    Deletes go to the Recycle Bin. Conflicts keep both versions. A pass that
    would delete more than the link's MaxDelete aborts without applying
    anything.

    Usage:
      DriveRelay add    <local> <remote> [-Seed Local|Remote]
      DriveRelay list
      DriveRelay rm     <id>
      DriveRelay pause  <id>
      DriveRelay resume <id>
      DriveRelay check  [<id>] [-Detailed]
      DriveRelay sync   [<id>] [-WhatIf]
      DriveRelay status [<id>]
      DriveRelay start  [-IntervalMinutes 10]
      DriveRelay stop
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('add','list','rm','pause','resume','check','sync','run','status','start','stop','config','settings','help')]
    [string] $Command = 'help',

    # Positional target: link id for most commands, local path for 'add'.
    [Parameter(Position = 1)]
    [string] $Target,

    # Second positional: remote path (only used by 'add').
    [Parameter(Position = 2)]
    [string] $Target2,

    # Legacy named parameters (still accepted for backward compatibility).
    [string] $Id,
    [string] $Local,
    [Alias('OneDrive')]
    [string] $Remote,

    [ValidateSet('Local','Remote','OneDrive')]
    [string] $Seed = 'Local',

    [ValidateSet('Auto','CloudFiles','Plain')]
    [string] $Provider = 'Auto',

    [int]    $SettleMinutes,
    [int]    $MaxDelete,
    [switch] $Off,
    [switch] $Detailed,
    [switch] $NoDehydrate,
    [switch] $HydrateBeforeDelete,
    [int]    $IntervalMinutes,

    [ValidateSet('DEBUG','INFO','WARN','ERROR')]
    [string] $LogLevel,
    [double] $LogMaxSizeMB,
    [int]    $LogKeepFiles
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Which switches the caller actually typed, captured here because the command
# functions below cannot see it themselves.
#
# Inside a function, $PSBoundParameters is that function's own -- and these take
# no parameters, so it is always empty. Every "did the caller override this?"
# test read as no, which silently ignored -SettleMinutes and -MaxDelete on add,
# -IntervalMinutes on start, and every override on config: the command printed
# the unchanged settings and reported nothing wrong.
$script:Typed = $PSBoundParameters

. (Join-Path $root 'lib\Logging.ps1')
. (Join-Path $root 'lib\Settings.ps1')
. (Join-Path $root 'lib\Provider.ps1')
. (Join-Path $root 'lib\Availability.ps1')
. (Join-Path $root 'lib\Hydration.ps1')
. (Join-Path $root 'lib\Settle.ps1')
. (Join-Path $root 'lib\Registry.ps1')
. (Join-Path $root 'lib\Manifest.ps1')
. (Join-Path $root 'lib\Actions.ps1')
. (Join-Path $root 'lib\Pass.ps1')

Set-LogPath      (Join-Path $root 'driverelay.log')
Set-RegistryPath (Join-Path $root 'config\links.json')
Set-SettingsPath (Join-Path $root 'config\settings.json')
Initialize-LoggingFromSettings
$script:StateRoot    = Join-Path $root 'state'
$script:ExcludesFile = Join-Path $root 'config\excludes.txt'

function Get-ExcludePatterns {
    if (-not (Test-Path $script:ExcludesFile)) { return @() }
    return @(Get-Content $script:ExcludesFile |
             Where-Object { $_ -and $_ -notmatch '^\s*#' } |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ })
}

# ------------------------------------------------------------------- help ---

function Show-Help {
@'
DriveRelay -- relay files between a local folder and a cloud drive.

  add <local> <remote>   Register a new link pair.
                         [-Seed Local|Remote] [-Provider Auto|CloudFiles|Plain]
                         [-SettleMinutes 3] [-MaxDelete 50] [-HydrateBeforeDelete]

                         <remote> can be any folder: OneDrive, Google Drive,
                         Dropbox, a network share, another disk.

  list                   Show all registered links.

  rm <id>                Unregister a link. No files are touched.

  pause <id>             Disable a link (skip it during passes).
  resume <id>            Re-enable a paused link.

  check [<id>]           Report what a sync would do. Writes nothing.
                         [-Detailed]

  sync [<id>]            Apply it. Conflicts keep both versions, and a pass
                         exceeding MaxDelete aborts without touching anything.
                         [-WhatIf]

  status [<id>]          Per-link state: last run, outstanding work.

  start                  Install a scheduled task to run passes automatically.
                         [-IntervalMinutes 10]

  stop                   Remove the scheduled task.

  config                 Show global settings, or change them.
                         [-IntervalMinutes 10] [-SettleMinutes 3] [-MaxDelete 50]
                         [-HydrateBeforeDelete]
                         [-LogLevel DEBUG|INFO|WARN|ERROR]
                         [-LogMaxSizeMB 1] [-LogKeepFiles 3]

                         At INFO the log records what changed. DEBUG adds the
                         per-file and per-pass detail for diagnosing a problem;
                         it is verbose, so turn it back down afterwards. The log
                         rotates to driverelay.1.log .. driverelay.<Keep>.log at
                         the size cap.

Seed decides which side is authoritative the first time a link runs.
After that the pair is two-way.
'@
}

# -------------------------------------------------------------------- add ---

function Invoke-AddCommand {
    # Resolve positional or named arguments.
    $localPath  = if ($Target)  { $Target }  elseif ($Local)  { $Local }  else { $null }
    $remotePath = if ($Target2) { $Target2 } elseif ($Remote) { $Remote } else { $null }

    if (-not $localPath -or -not $remotePath) { throw 'add needs <local> and <remote> paths.' }
    if (-not (Test-Path -LiteralPath $localPath)) {
        throw ("Local path does not exist: {0}" -f $localPath)
    }
    if (-not (Test-Path -LiteralPath $remotePath)) {
        throw ("Remote path does not exist: {0}" -f $remotePath)
    }

    $seedSide = if ($Seed -eq 'OneDrive') { 'Remote' } else { $Seed }

    $globalSettings = Get-AppSettings
    $actualSettle = if ($script:Typed.ContainsKey('SettleMinutes')) { $SettleMinutes } else { $globalSettings.SettleMinutes }
    $actualMaxDel = if ($script:Typed.ContainsKey('MaxDelete')) { $MaxDelete } else { $globalSettings.MaxDelete }
    $actualHydrate = if ($script:Typed.ContainsKey('HydrateBeforeDelete')) { [bool]$HydrateBeforeDelete } else { [bool]$globalSettings.HydrateBeforeDelete }

    $l = Add-Link -Local $localPath -Remote $remotePath -Seed $seedSide -Provider $Provider `
                  -SettleMinutes $actualSettle -MaxDelete $actualMaxDel `
                  -Dehydrate (-not $NoDehydrate) `
                  -HydrateBeforeDelete $actualHydrate
    Write-Log ("link added: {0}  {1} <-> {2}  seed={3}" -f $l.Id, $l.LocalPath, $l.RemotePath, $l.Seed)

    $mf = Get-ManifestPath -LinkId $l.Id -StateRoot $script:StateRoot
    if (Test-Path -LiteralPath $mf) {
        $aside = "$mf.superseded-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $mf -Destination $aside -Force
        Write-Log ("set aside stale manifest for {0}: {1}" -f $l.Id, $aside) 'WARN'
    }
    "Registered '{0}'" -f $l.Id
    "  local     {0}" -f $l.LocalPath
    "  remote    {0}   ({1})" -f $l.RemotePath, (Get-ProviderLabel -Path $l.RemotePath)
    "  storage   {0}" -f (Resolve-LinkProvider -Link $l)
    "  seed      {0}   settle {1}m   maxdelete {2}" -f $l.Seed, $l.SettleMinutes, $l.MaxDelete
    ''
    "Nothing has been copied. Run 'check {0}' to see what a sync would do." -f $l.Id
}

# ------------------------------------------------------------------- list ---

function Invoke-ListCommand {
    $links = @(Get-LinkRegistry)
    if ($links.Count -eq 0) { 'No links registered.'; return }
    $links | ForEach-Object {
        [pscustomobject]@{
            Id      = $_.Id
            Local   = $_.LocalPath
            Remote  = (Get-RemotePath -Link $_)
            Drive   = (Get-ProviderLabel -Path (Get-RemotePath -Link $_))
            Seed    = $_.Seed
            Seeded  = $_.Seeded
            Enabled = $_.Enabled
            Settle  = "$($_.SettleMinutes)m"
            LastRun = $_.LastRun
        }
    } | Format-Table -AutoSize
}

# --------------------------------------------------------------------- rm ---

function Invoke-RemoveCommand {
    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }
    if (-not $linkId) { throw 'rm needs a link id.' }
    Remove-Link -Id $linkId
    Write-Log ("link removed: {0}" -f $linkId)
    "Unregistered '{0}'. No files were touched on either side." -f $linkId
}

# -------------------------------------------------------------- pause/resume --

function Invoke-PauseCommand {
    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }
    if (-not $linkId) { throw 'pause needs a link id.' }
    Set-LinkEnabled -Id $linkId -Enabled $false
    "Link '{0}' is now paused." -f $linkId
}

function Invoke-ResumeCommand {
    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }
    if (-not $linkId) { throw 'resume needs a link id.' }
    Set-LinkEnabled -Id $linkId -Enabled $true
    "Link '{0}' is now active." -f $linkId
}

# ------------------------------------------------------------------ check ---

function Invoke-CheckCommand {
    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }

    $links = @(Get-LinkRegistry)
    if ($linkId) { $links = @($links | Where-Object { $_.Id -eq $linkId }) }
    if ($links.Count -eq 0) { 'No matching links.'; return }

    $patterns = Get-ExcludePatterns

    foreach ($link in $links) {
        ''
        "=== {0}   {1}  <->  {2}" -f $link.Id, $link.LocalPath, (Get-RemotePath -Link $link)
        if (-not $link.Seeded) {
            "    not yet seeded -- first run would seed from: {0}" -f $link.Seed
        }

        $avail = Get-LinkAvailability -Link $link
        if ($avail.Blocking) {
            "    SKIPPED -- {0}" -f $avail.Summary
            "    {0}" -f $avail.Detail
            continue
        }
        if ($avail.State -ne 'Ready') {
            "    WARNING -- {0}" -f $avail.Summary
            "    {0}" -f $avail.Detail
            ''
        }

        $items = Compare-LinkState -Link $link -ExcludePatterns $patterns -StateRoot $script:StateRoot

        $actionable = @($items | Where-Object { $_.Action -ne 'InSync' -and $_.Action -ne 'Forget' })
        $summary = $items | Group-Object Action | Sort-Object Name

        foreach ($g in $summary) { "    {0,-16} {1}" -f $g.Name, $g.Count }

        $deletes = @($items | Where-Object { $_.Action -like 'Delete*' }).Count
        if ($deletes -gt $link.MaxDelete) {
            ''
            "    !! {0} deletions exceeds MaxDelete of {1}." -f $deletes, $link.MaxDelete
            "       A real run would abort rather than proceed."
        }

        if ($actionable.Count -gt 0) {
            ''
            foreach ($i in $actionable) {
                $ready = Test-ActionReady -Item $i -SettleMinutes $link.SettleMinutes
                $mark  = if ($ready.Ready) { ' ' } else { '~' }
                "    {0} {1,-16} {2}" -f $mark, $i.Action, $i.RelPath
                if ($Detailed -or -not $ready.Ready) {
                    "        {0}{1}" -f $i.Reason, $(if (-not $ready.Ready) { " | not yet: $($ready.Reason)" } else { '' })
                }
            }
            ''
            "    '~' marks files a real run would defer to a later pass."
        }

        if ($actionable.Count -eq 0) { '    nothing to do' }
    }

    ''
    'Report only. Nothing was copied, deleted or modified.'
}

# ------------------------------------------------------------------- sync ---

function Invoke-SyncCommand {
    param([switch] $Silent)

    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }

    # An unattended pass honours the global pause; an explicit `sync` typed by a
    # person does not. Pausing means "stop doing this on your own", not "refuse
    # when I ask". Checked here so the pause holds whichever scheduler is
    # driving -- the tray, the scheduled task, or neither.
    if ($Silent) {
        $paused = $false
        try { $paused = [bool](Get-AppSettings).Paused } catch { }
        if ($paused) {
            Write-Log 'pass skipped: syncing is paused'
            return
        }
    }

    $patterns = Get-ExcludePatterns
    $outcome  = Invoke-SyncPass -LinkId $linkId -ExcludePatterns $patterns -StateRoot $script:StateRoot -Quiet:$Silent

    if ($Silent) { return }

    if ($outcome.Skipped) { "Skipped: {0}" -f $outcome.Reason; return }
    if ($outcome.Results.Count -eq 0) { $outcome.Reason; return }

    foreach ($r in $outcome.Results) {
        $link = Get-LinkRegistry | Where-Object { $_.Id -eq $r.LinkId }
        ''
        "=== {0}   {1}  <->  {2}" -f $r.LinkId, $link.LocalPath, (Get-RemotePath -Link $link)

        if ($r.Aborted) {
            "    SKIPPED: {0}" -f $r.Message
            if ($r.PSObject.Properties['Detail'] -and $r.Detail) { "    {0}" -f $r.Detail }
            continue
        }
        if ($r.PSObject.Properties['State'] -and $r.State -and $r.State -ne 'Ready') {
            "    WARNING: {0}" -f $r.Detail
        }

        "    applied {0}, deferred {1}, conflicts {2}, deleted {3}, failed {4}" -f `
            $r.Applied, $r.Deferred, $r.Conflicts, $r.Deleted, $r.Failed

        if ($r.Conflicts -gt 0) {
            "    {0} conflict(s): both versions kept, the remote one renamed alongside the local file." -f $r.Conflicts
        }
        if ($r.Deleted -gt 0) {
            $recycled = $r.Deleted - $r.CloudOnlyDeletes
            if ($recycled -gt 0) { "    {0} file(s) sent to the Recycle Bin." -f $recycled }
            if ($r.CloudOnlyDeletes -gt 0) {
                "    {0} cloud-only file(s) deleted -- these were placeholders with no local" -f $r.CloudOnlyDeletes
                "      content, so recover them from the cloud service's online recycle bin."
                "      Use -HydrateBeforeDelete on the link to keep local copies instead."
            }
        }
        if ($r.Deferred -gt 0) {
            "    {0} file(s) left for a later pass (still settling or held open)." -f $r.Deferred
        }
    }

    ''
    if ($WhatIfPreference) { 'WhatIf: nothing was changed.' }
}

# --------------------------------------------------------------- scheduling ---

$script:TaskName = 'DriveRelay'

function Invoke-StartCommand {
    $globalSettings = Get-AppSettings
    $minutes = if ($script:Typed.ContainsKey('IntervalMinutes') -and $IntervalMinutes -gt 0) { $IntervalMinutes }
               elseif ($globalSettings.IntervalMinutes -gt 0) { $globalSettings.IntervalMinutes }
               else { 10 }
    $script  = Join-Path $root 'DriveRelay.ps1'

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" run' -f $script)

    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes $minutes)

    $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 4)

    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                  -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
                           -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log ("scheduled task installed, every {0} minutes" -f $minutes)
    "Installed scheduled task '{0}', running every {1} minutes while you are logged in." -f $script:TaskName, $minutes
    "Passes that overlap are skipped, so a slow run cannot pile up."
}

function Invoke-StopCommand {
    # Also check for old task name for migration.
    foreach ($name in @($script:TaskName, 'SyncOrchestrator')) {
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Log ("scheduled task removed: {0}" -f $name)
            "Removed scheduled task '{0}'." -f $name
        }
    }
}

function Invoke-SettingsCommand {
    $current = Get-AppSettings
    $changed = $false

    if ($script:Typed.ContainsKey('IntervalMinutes')) {
        $current.IntervalMinutes = [int]$IntervalMinutes
        $changed = $true
    }
    if ($script:Typed.ContainsKey('SettleMinutes')) {
        $current.SettleMinutes = [int]$SettleMinutes
        $changed = $true
    }
    if ($script:Typed.ContainsKey('MaxDelete')) {
        $current.MaxDelete = [int]$MaxDelete
        $changed = $true
    }
    if ($script:Typed.ContainsKey('HydrateBeforeDelete')) {
        $current.HydrateBeforeDelete = [bool]$HydrateBeforeDelete
        $changed = $true
    }
    if ($script:Typed.ContainsKey('LogLevel')) {
        $current.LogLevel = $LogLevel.ToUpperInvariant()
        $changed = $true
    }
    if ($script:Typed.ContainsKey('LogMaxSizeMB')) {
        $current.LogMaxSizeMB = [double]$LogMaxSizeMB
        $changed = $true
    }
    if ($script:Typed.ContainsKey('LogKeepFiles')) {
        $current.LogKeepFiles = [int]$LogKeepFiles
        $changed = $true
    }

    if ($changed) {
        Save-AppSettings -Settings $current
        Write-Log ("settings updated via CLI: Interval={0}m Settle={1}m MaxDelete={2}" -f $current.IntervalMinutes, $current.SettleMinutes, $current.MaxDelete)
        "Updated global settings."
        ''
    }

    "DriveRelay Configuration:"
    "  IntervalMinutes     : {0}" -f $current.IntervalMinutes
    "  SettleMinutes       : {0}" -f $current.SettleMinutes
    "  MaxDelete           : {0}" -f $current.MaxDelete
    "  HydrateBeforeDelete : {0}" -f $current.HydrateBeforeDelete
    "  StartWithWindows    : {0}" -f $current.StartWithWindows
    "  StartDelaySeconds   : {0}" -f $current.StartDelaySeconds
    "  LogLevel            : {0}" -f $current.LogLevel
    "  LogMaxSizeMB        : {0}" -f $current.LogMaxSizeMB
    "  LogKeepFiles        : {0}" -f $current.LogKeepFiles
    "  Paused              : {0}" -f $current.Paused
    if ($current.Paused) {
        ''
        "Syncing is paused: unattended passes are skipped. 'sync' still works when"
        "you run it yourself. Resume from the tray menu."
    }
}

# ----------------------------------------------------------------- status ---

function Invoke-StatusCommand {
    $linkId = if ($Target) { $Target } elseif ($Id) { $Id } else { $null }

    $links = @(Get-LinkRegistry)
    if ($linkId) { $links = @($links | Where-Object { $_.Id -eq $linkId }) }
    if ($links.Count -eq 0) { 'No matching links.'; return }

    $patterns = Get-ExcludePatterns

    foreach ($link in $links) {
        ''
        "=== {0}{1}" -f $link.Id, $(if (-not $link.Enabled) { '   [paused]' } else { '' })
        "    local     {0}" -f $link.LocalPath
        "    remote    {0}   ({1}, {2})" -f (Get-RemotePath -Link $link),
                                            (Get-ProviderLabel -Path (Get-RemotePath -Link $link)),
                                            (Resolve-LinkProvider -Link $link)
        "    seeded    {0}    settle {1}m    maxdelete {2}" -f $link.Seeded, $link.SettleMinutes, $link.MaxDelete
        "    last run  {0}" -f $(if ($link.LastRun) { "$($link.LastRun)  --  $($link.LastResult)" } else { 'never' })

        $avail = Get-LinkAvailability -Link $link
        if ($avail.State -ne 'Ready') {
            "    {0}: {1}" -f $(if ($avail.Blocking) { 'UNAVAILABLE' } else { 'WARNING' }), $avail.Summary
            "    {0}" -f $avail.Detail
            if ($avail.Blocking) { continue }
        }

        $items = Compare-LinkState -Link $link -ExcludePatterns $patterns -StateRoot $script:StateRoot
        $pending = @($items | Where-Object { $_.Action -ne 'InSync' -and $_.Action -ne 'Forget' })

        if ($pending.Count -eq 0) { '    up to date'; continue }

        "    {0} pending:" -f $pending.Count
        foreach ($i in $pending) {
            $rd = Test-ActionReady -Item $i -SettleMinutes $link.SettleMinutes
            if ($rd.Ready) { "      {0,-16} {1}" -f $i.Action, $i.RelPath }
            else           { "      {0,-16} {1}   [waiting: {2}]" -f $i.Action, $i.RelPath, $rd.Reason }
        }
    }
}

# ----------------------------------------------------------- command router ---

switch ($Command) {
    'add'                 { Invoke-AddCommand }
    'list'                { Invoke-ListCommand }
    'rm'                  { Invoke-RemoveCommand }
    'pause'               { Invoke-PauseCommand }
    'resume'              { Invoke-ResumeCommand }
    'check'               { Invoke-CheckCommand }
    'sync'                { Invoke-SyncCommand }
    'run'                 { Invoke-SyncCommand -Silent }
    'status'              { Invoke-StatusCommand }
    'start'               { Invoke-StartCommand }
    'stop'                { Invoke-StopCommand }
    { $_ -in 'config','settings' } { Invoke-SettingsCommand }
    default               { Show-Help }
}
