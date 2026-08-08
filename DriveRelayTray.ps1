<#
    DriveRelayTray.ps1  --  the tray agent.

    Sits by the clock, runs a pass every so often, and says what it is doing.
    This is what starts with Windows.

    Two rules shape the design:

      * Passes run as a hidden child process, never on the UI thread. A sync
        can take minutes -- hydrating a large file, waiting on an upload -- and
        a frozen tray icon would be worse than no tray icon. The child is the
        same CLI the command line uses, so there is no second implementation
        to keep honest.

      * Only one agent runs at a time. Windows will happily start the Startup
        shortcut again on a fast user switch or a second logon.
#>

[CmdletBinding()]
param(
    # Minutes between passes.
    [int] $IntervalMinutes = 10
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $root 'lib\Logging.ps1')
. (Join-Path $root 'lib\Icons.ps1')
. (Join-Path $root 'lib\Settings.ps1')

Set-LogPath      (Join-Path $root 'driverelay.log')
Set-SettingsPath (Join-Path $root 'config\settings.json')

$script:AppSettings = Get-AppSettings
if ($PSBoundParameters.ContainsKey('IntervalMinutes')) {
    $script:CurrentInterval = $IntervalMinutes
} else {
    $script:CurrentInterval = $script:AppSettings.IntervalMinutes
}

$script:StateRoot = Join-Path $root 'state'
$script:Cli       = Join-Path $root 'DriveRelay.ps1'
$script:Ui        = Join-Path $root 'DriveRelayUI.ps1'
$script:Child     = $null
$script:Paused    = $false
$script:LastSeen  = $null

# --------------------------------------------------------- single instance ---

$script:AgentMutex = New-Object System.Threading.Mutex($false, 'Global\DriveRelayTray')
if (-not $script:AgentMutex.WaitOne(0)) {
    $script:AgentMutex.Dispose()
    exit 0
}

$script:IconIdle = New-SyncIcon -Size 32 -State 'idle'
$script:IconSync = New-SyncIcon -Size 32 -State 'sync'
$script:IconWarn = New-SyncIcon -Size 32 -State 'warn'

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = $script:IconIdle
$notify.Text    = 'DriveRelay'
$notify.Visible = $true

function Set-TrayState {
    param(
        [ValidateSet('idle','sync','warn')][string] $State,
        [string] $Tip
    )

    switch ($State) {
        'sync' { $notify.Icon = $script:IconSync }
        'warn' { $notify.Icon = $script:IconWarn }
        default { $notify.Icon = $script:IconIdle }
    }
    if ($Tip) {
        if ($Tip.Length -gt 62) { $Tip = $Tip.Substring(0, 59) + '...' }
        $notify.Text = $Tip
    }
}

function Read-Summary {
    $p = Join-Path $script:StateRoot 'lastpass.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try   { return ConvertFrom-Json -InputObject (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }
    catch { return $null }
}

function Get-LinkCount {
    $cf = Join-Path $root 'config\links.json'
    if (-not (Test-Path $cf)) { return 0 }
    try {
        $raw = Get-Content -LiteralPath $cf -Raw -Encoding UTF8
        $parsed = ConvertFrom-Json -InputObject $raw
        if ($parsed -is [System.Array]) { return $parsed.Count }
        return 1
    } catch { return 0 }
}

# ------------------------------------------------------------------- menu ---

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RenderMode = 'System'

# Header
$miHeader = New-Object System.Windows.Forms.ToolStripMenuItem
$miHeader.Text = 'DriveRelay'
$miHeader.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9, ([System.Drawing.FontStyle]::Bold)
$miHeader.Enabled = $false
$null = $menu.Items.Add($miHeader)

# Status line
$miStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$miStatus.Text = 'Up to date'
$miStatus.Enabled = $false
$null = $menu.Items.Add($miStatus)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Sync now
$miSync = New-Object System.Windows.Forms.ToolStripMenuItem
$miSync.Text = 'Sync now'
$null = $menu.Items.Add($miSync)

# Pause / Resume
$miPause = New-Object System.Windows.Forms.ToolStripMenuItem
$miPause.Text = 'Pause syncing'
$null = $menu.Items.Add($miPause)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Open dashboard
$miFolders = New-Object System.Windows.Forms.ToolStripMenuItem
$miFolders.Text = 'Open dashboard'
$null = $menu.Items.Add($miFolders)

# Settings
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem
$miSettings.Text = 'Settings'
$null = $menu.Items.Add($miSettings)

# View log
$miLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miLog.Text = 'View log'
$null = $menu.Items.Add($miLog)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Exit
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = 'Exit'
$null = $menu.Items.Add($miExit)

$notify.ContextMenuStrip = $menu

# ----------------------------------------------------------------- actions ---

function Update-StatusLine {
    $s = Read-Summary
    $lc = Get-LinkCount
    if (-not $s) {
        $miStatus.Text = if ($lc -gt 0) { "{0} link(s) ready" -f $lc } else { 'No links' }
        return
    }
    $time = if ($s.When.Length -ge 16) { $s.When.Substring(11, 5) } else { $s.When }
    $miStatus.Text = "Last sync {0} - {1} link(s)" -f $time, $lc
}

function Start-Pass {
    if ($script:Child -and -not $script:Child.HasExited) { return }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = 'powershell.exe'
    $psi.Arguments       = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" run' -f $script:Cli)
    $psi.WindowStyle     = 'Hidden'
    $psi.CreateNoWindow  = $true
    $psi.UseShellExecute = $false

    try {
        $script:Child = [System.Diagnostics.Process]::Start($psi)
        Set-TrayState -State 'sync' -Tip 'DriveRelay - syncing'
        $miStatus.Text = 'Syncing...'
    }
    catch {
        Write-Log ("tray could not start a pass: {0}" -f $_.Exception.Message) 'ERROR'
        Set-TrayState -State 'warn' -Tip 'DriveRelay - could not start'
    }
}

function Complete-Pass {
    $script:Child = $null
    $s = Read-Summary
    if (-not $s) {
        Set-TrayState -State 'idle' -Tip 'DriveRelay'
        Update-StatusLine
        return
    }

    $trouble = ($s.Conflicts -gt 0) -or ($s.Failed -gt 0) -or (@($s.Aborted).Count -gt 0)

    if ($trouble) {
        Set-TrayState -State 'warn' -Tip 'DriveRelay - needs attention'
        $miStatus.Text = "Needs attention - {0} conflict(s)" -f $s.Conflicts
    }
    else {
        Set-TrayState -State 'idle' -Tip 'DriveRelay - up to date'
        if ($s.Applied -gt 0) {
            $time = if ($s.When.Length -ge 16) { $s.When.Substring(11, 5) } else { $s.When }
            $miStatus.Text = "Synced {0} change(s) at {1}" -f $s.Applied, $time
        }
        else { Update-StatusLine }
    }

    $stamp = "$($s.When)|$($s.Conflicts)|$($s.Failed)|$(@($s.Aborted).Count)"
    if ($trouble -and $stamp -ne $script:LastSeen) {
        $script:LastSeen = $stamp

        $lines = @()
        if ($s.Conflicts -gt 0) {
            $lines += "{0} file(s) changed in both places. Both versions were kept." -f $s.Conflicts
        }
        if (@($s.Aborted).Count -gt 0) { $lines += [string]($s.Aborted -join '; ') }
        if ($s.Failed -gt 0)           { $lines += "{0} file(s) could not be copied." -f $s.Failed }

        $notify.BalloonTipTitle = 'DriveRelay'
        $notify.BalloonTipText  = ($lines -join "`r`n")
        $notify.BalloonTipIcon  = 'Warning'
        $notify.ShowBalloonTip(8000)
    }
}

$miSync.Add_Click({ Start-Pass })

$miPause.Add_Click({
    $script:Paused = -not $script:Paused
    if ($script:Paused) {
        $miPause.Text  = 'Resume syncing'
        $miStatus.Text = 'Paused'
        Set-TrayState -State 'warn' -Tip 'DriveRelay - paused'
        Write-Log 'tray: syncing paused'
    }
    else {
        $miPause.Text = 'Pause syncing'
        Set-TrayState -State 'idle' -Tip 'DriveRelay'
        Write-Log 'tray: syncing resumed'
        Start-Pass
    }
})

$miFolders.Add_Click({
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"{0}"' -f $script:Ui)
    ) -WindowStyle Hidden
})

$miSettings.Add_Click({
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"{0}"' -f $script:Ui)
    ) -WindowStyle Hidden
})

$miLog.Add_Click({
    $log = Join-Path $root 'driverelay.log'
    # Fall back to legacy log name.
    if (-not (Test-Path $log)) { $log = Join-Path $root 'syncorch.log' }
    if (Test-Path $log) { Start-Process notepad.exe $log }
})

$miExit.Add_Click({
    $notify.Visible = $false
    Write-Log 'tray: exit requested'
    [System.Windows.Forms.Application]::Exit()
})

$notify.Add_MouseDoubleClick({ $miFolders.PerformClick() })
$notify.Add_BalloonTipClicked({ $miFolders.PerformClick() })

# ------------------------------------------------------------------ timers ---

$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 1000
$watch.Add_Tick({
    if ($script:Child -and $script:Child.HasExited) { Complete-Pass }
})
$watch.Start()

$cycle = New-Object System.Windows.Forms.Timer
$cycle.Interval = [Math]::Max(1, $script:CurrentInterval) * 60 * 1000
$cycle.Add_Tick({
    try {
        $s = Get-AppSettings
        if ($s -and $s.IntervalMinutes -gt 0) {
            $targetMs = [Math]::Max(1, [int]$s.IntervalMinutes) * 60 * 1000
            if ($cycle.Interval -ne $targetMs) {
                $cycle.Interval = $targetMs
                Write-Log ("tray sync interval updated to {0} minute(s)" -f $s.IntervalMinutes)
            }
        }
    } catch { }
    if (-not $script:Paused) { Start-Pass }
})
$cycle.Start()

Write-Log ("tray started, pass every {0} minute(s)" -f $script:CurrentInterval)
Update-StatusLine

$delaySeconds = if ($script:AppSettings.StartDelaySeconds -gt 0) { $script:AppSettings.StartDelaySeconds } else { 90 }
$firstRun = New-Object System.Windows.Forms.Timer
$firstRun.Interval = [Math]::Max(5, $delaySeconds) * 1000
$firstRun.Add_Tick({
    $firstRun.Stop()
    if (-not $script:Paused) { Start-Pass }
})
$firstRun.Start()

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $notify.Visible = $false
    $notify.Dispose()
    foreach ($i in @($script:IconIdle, $script:IconSync, $script:IconWarn)) {
        if ($i) { $i.Dispose() }
    }
    try { $script:AgentMutex.ReleaseMutex() } catch { }
    $script:AgentMutex.Dispose()
    Write-Log 'tray stopped'
}
