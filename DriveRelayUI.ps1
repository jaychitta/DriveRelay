<#
    DriveRelayUI.ps1  --  the dashboard window.

    A clean, modern card-style view of all linked folder pairs. Everything here
    drives the same engine the command line and the tray use, so there is no
    behaviour that only exists in the interface.

    Long work never runs on the UI thread. Syncing launches the CLI as a hidden
    child process and the window polls for it, which keeps the window from
    greying out and lets the pass mutex do its job.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $root 'lib\Logging.ps1')
. (Join-Path $root 'lib\LogViewer.ps1')
. (Join-Path $root 'lib\Provider.ps1')
. (Join-Path $root 'lib\Conflicts.ps1')
. (Join-Path $root 'lib\Availability.ps1')
. (Join-Path $root 'lib\Icons.ps1')
. (Join-Path $root 'lib\Registry.ps1')
. (Join-Path $root 'lib\Settings.ps1')

Set-LogPath      (Join-Path $root 'driverelay.log')
Set-RegistryPath (Join-Path $root 'config\links.json')
Set-SettingsPath (Join-Path $root 'config\settings.json')
Initialize-LoggingFromSettings
$script:StateRoot = Join-Path $root 'state'
$script:Cli       = Join-Path $root 'DriveRelay.ps1'
$script:Child     = $null
# The dashboard keeps the duplicate list in the selected card rather than
# opening a second window.  Only one expanded list is useful at a time.
$script:ExpandedDuplicateLink = $null
$script:ConflictCopiesByLink = @{}

# Try to enable dark title bar on Windows 10/11.
try {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DwmHelper {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    public static void SetDarkTitleBar(IntPtr handle) {
        int val = 1;
        DwmSetWindowAttribute(handle, 20, ref val, 4);
    }
}
'@ -ErrorAction SilentlyContinue
} catch { }

# ------------------------------------------------------------------ colors ---

$script:BgColor      = [System.Drawing.Color]::FromArgb(255, 30, 30, 34)
$script:CardColor    = [System.Drawing.Color]::FromArgb(255, 42, 42, 48)
$script:CardHover    = [System.Drawing.Color]::FromArgb(255, 52, 52, 58)
$script:TextPrimary  = [System.Drawing.Color]::FromArgb(255, 230, 230, 235)
$script:TextMuted    = [System.Drawing.Color]::FromArgb(255, 140, 140, 150)
$script:AccentBlue   = [System.Drawing.Color]::FromArgb(255, 56, 142, 240)
$script:StatusGreen  = [System.Drawing.Color]::FromArgb(255, 50, 190, 90)
$script:StatusAmber  = [System.Drawing.Color]::FromArgb(255, 240, 170, 30)
# Red is reserved for "this pair cannot sync at all right now" -- a drive that is
# not mounted, a folder that is gone. Amber stays for degraded-but-running.
$script:StatusRed    = [System.Drawing.Color]::FromArgb(255, 240, 90, 90)
$script:StatusGray   = [System.Drawing.Color]::FromArgb(255, 110, 110, 120)
$script:BtnBg        = [System.Drawing.Color]::FromArgb(255, 55, 55, 62)
$script:BtnHover     = [System.Drawing.Color]::FromArgb(255, 70, 70, 78)
$script:SepColor     = [System.Drawing.Color]::FromArgb(255, 55, 55, 62)
$script:HeaderColor  = [System.Drawing.Color]::FromArgb(255, 24, 24, 28)
$script:PanelColor   = [System.Drawing.Color]::FromArgb(255, 35, 35, 41)

$script:FontName     = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 11, ([System.Drawing.FontStyle]::Bold)
$script:FontPath     = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$script:FontStatus   = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5, ([System.Drawing.FontStyle]::Bold)
$script:FontBtn      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
$script:FontCaption  = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 7.5, ([System.Drawing.FontStyle]::Bold)

# ------------------------------------------------------------------ helpers ---

function Start-Cli {
    param([Parameter(Mandatory)][string[]] $CliArgs)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = 'powershell.exe'
    $psi.Arguments       = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $script:Cli, ($CliArgs -join ' '))
    $psi.WindowStyle     = 'Hidden'
    $psi.CreateNoWindow  = $true
    $psi.UseShellExecute = $false
    return [System.Diagnostics.Process]::Start($psi)
}

function Select-FolderDialog {
    param([string] $Description, [string] $Start)

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description  = $Description
    $dlg.ShowNewFolderButton = $true
    if ($Start -and (Test-Path $Start)) { $dlg.SelectedPath = $Start }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Get-StatusInfo {
    param([object] $Link, [object[]] $ConflictCopies, [switch] $ConflictCopiesChecked)
    if (-not $Link.Enabled) {
        return @{ Text = 'Paused'; Color = $script:StatusGray; Detail = '' }
    }

    # Availability outranks everything else: if the drive is not there, saying
    # "up to date" is worse than saying nothing. Checked live, so the card is
    # right the moment the window opens rather than as of the last pass.
    try {
        $a = Get-LinkAvailability -Link $Link
        if ($a.State -ne 'Ready') {
            $colour = if ($a.Blocking) { $script:StatusRed } else { $script:StatusAmber }
            return @{ Text = $a.Summary; Color = $colour; Detail = $a.Detail }
        }
    }
    catch { }

    if (-not $Link.Seeded) {
        return @{ Text = 'Not synced yet'; Color = $script:StatusAmber; Detail = '' }
    }
    if ($Link.LastResult -like 'aborted*') {
        # The pass persists the concrete reason (for example, that the delete
        # limit was exceeded). Show it on the card instead of hiding it behind
        # a generic warning; the tooltip shows the same actionable explanation.
        $detail = [string]$Link.LastResult
        $reason = ($detail -replace '^aborted:\s*', '').Trim()
        if ($reason -match '^(?<count>\d+) deletions exceeds MaxDelete of (?<limit>\d+); nothing applied$') {
            $count = [int]$Matches['count']
            $oldLimit = [int]$Matches['limit']
            $currentLimit = if ($Link.PSObject.Properties['MaxDelete'] -and
                                $null -ne $Link.MaxDelete) { [int]$Link.MaxDelete } else { $oldLimit }
            if ($currentLimit -gt $oldLimit) {
                # This warning belongs to a pass that used the old limit. The
                # new setting is already saved, so do not keep showing a stale
                # error while the dashboard waits to retry the sync.
                return @{ Text = 'Ready to sync'; Color = $script:AccentBlue
                          Detail = 'The higher delete limit is saved. Sync all will retry this link.'
                          Attention = $false }
            }
            $reason = '{0} deletions were blocked (limit: {1}). Increase it in Edit, then sync again.' -f
                      $count, $oldLimit
        }
        return @{ Text = $(if ($reason) { $reason } else { 'Needs attention' })
                  Color = $script:StatusAmber
                  Detail = $(if ($reason) { $reason } else { $detail }) }
    }
    $files = @($ConflictCopies)
    if (-not $ConflictCopiesChecked) {
        try { $files = @(Get-LinkConflictCopies -Link $Link) } catch { $files = @() }
    }
    if ($files.Count -gt 0) {
        return @{ Text = ("{0} duplicate(s)" -f $files.Count); Color = $script:StatusAmber
            Detail = 'Click Duplicates to review the original and conflict copy.' }
    }
    return @{ Text = 'Up to date'; Color = $script:StatusGreen; Detail = '' }
}

# Resolve application icon.
$script:AppIcon = $null
$icoCandidates = @(
    (Join-Path $root 'assets\DriveRelay.ico'),
    (Join-Path $root 'DriveRelay.ico')
)
$icoPath = $icoCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($icoPath) {
    try { $script:AppIcon = New-Object System.Drawing.Icon -ArgumentList $icoPath } catch { }
}

function Read-PassSummarySafe {
    $p = Join-Path $script:StateRoot 'lastpass.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try   { return ConvertFrom-Json -InputObject (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }
    catch { return $null }
}

function New-ConflictGrid {
    param([object[]] $Copies)
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.BackgroundColor = $script:BgColor
    $grid.DefaultCellStyle.BackColor = $script:CardColor
    $grid.DefaultCellStyle.ForeColor = $script:TextPrimary
    $grid.DefaultCellStyle.SelectionBackColor = $script:BtnBg
    $grid.DefaultCellStyle.SelectionForeColor = $script:TextPrimary
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:BtnBg
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:TextPrimary
    $grid.RowTemplate.Height = 34
    foreach ($columnInfo in @(
        @{ Name = 'Original'; Caption = 'Original file'; Width = 150 }
        @{ Name = 'Duplicate'; Caption = 'Duplicate file'; Width = 250 }
        @{ Name = 'Folder'; Caption = 'Folder'; Width = 170 }
    )) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $columnInfo.Name
        $column.HeaderText = $columnInfo.Caption
        $column.Width = $columnInfo.Width
        $null = $grid.Columns.Add($column)
    }
    foreach ($side in @('Local', 'Remote')) {
        $column = New-Object System.Windows.Forms.DataGridViewButtonColumn
        $column.Name = $side
        $column.HeaderText = "$side copy"
        $column.Width = 100
        $column.FlatStyle = 'Flat'
        $null = $grid.Columns.Add($column)
    }
    foreach ($copy in $Copies) {
        $index = $grid.Rows.Add(
            [IO.Path]::GetFileName($copy.OriginalRelPath),
            [IO.Path]::GetFileName($copy.CopyRelPath),
            $(if ([IO.Path]::GetDirectoryName($copy.CopyRelPath)) { [IO.Path]::GetDirectoryName($copy.CopyRelPath) } else { '(root)' }),
            $(if ($copy.CopyLocalPath) { 'Open folder' } else { 'Not present' }),
            $(if ($copy.CopyRemotePath) { 'Open folder' } else { 'Not present' }))
        $row = $grid.Rows[$index]
        $row.Tag = $copy
        $row.Cells[0].ToolTipText = $copy.OriginalRelPath
        $row.Cells[1].ToolTipText = $copy.CopyRelPath
        $row.Cells[3].ToolTipText = $copy.CopyLocalPath
        $row.Cells[4].ToolTipText = $copy.CopyRemotePath
    }
    $grid.Add_CellContentClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -lt 3) { return }
        $copy = $sender.Rows[$eventArgs.RowIndex].Tag
        $path = if ($eventArgs.ColumnIndex -eq 3) { $copy.CopyLocalPath } else { $copy.CopyRemotePath }
        if (-not $path) { return }
        $folder = [IO.Path]::GetDirectoryName($path)
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            $null = [System.Windows.Forms.MessageBox]::Show($sender.FindForm(), 'This folder is no longer available.', 'Open folder', 'OK', 'Warning')
            return
        }
        # Selecting in Explorer opens the containing folder without opening content.
        $arguments = if (Test-Path -LiteralPath $path -PathType Leaf) { '/select,"{0}"' -f $path } else { '"{0}"' -f $folder }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $arguments
    })
    return $grid
}

# ------------------------------------------------------------- add dialog ---

function Show-AddDialog {
    param([object] $Owner)

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = 'Add folder pair'
    $f.Size            = New-Object System.Drawing.Size -ArgumentList 580, 310
    $f.StartPosition   = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false; $f.MinimizeBox = $false
    $f.BackColor       = $script:BgColor
    $f.ForeColor       = $script:TextPrimary
    $f.Font            = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5
    if ($script:AppIcon) { $f.Icon = $script:AppIcon }

    try { [DwmHelper]::SetDarkTitleBar($f.Handle) } catch { }

    function New-DarkLabel($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $script:TextMuted
        $l.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $l.Size = New-Object System.Drawing.Size -ArgumentList $w, 20
        $l.BackColor = [System.Drawing.Color]::Transparent
        return $l
    }
    function New-DarkTextBox($x, $y, $w) {
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $tb.Size = New-Object System.Drawing.Size -ArgumentList $w, 26
        $tb.BackColor = $script:CardColor; $tb.ForeColor = $script:TextPrimary
        $tb.BorderStyle = 'FixedSingle'; $tb.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5
        return $tb
    }
    function New-DarkBtn($text, $x, $y, $w) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'
        $b.BackColor = $script:BtnBg; $b.ForeColor = $script:TextPrimary
        $b.FlatAppearance.BorderColor = $script:SepColor
        $b.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $b.Size = New-Object System.Drawing.Size -ArgumentList $w, 28
        $b.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $b.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
        $b.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
        return $b
    }

    $f.Controls.Add((New-DarkLabel 'Local folder (where you work)' 20 16 400))
    $tbLocal = New-DarkTextBox 20 38 430
    $btnLocal = New-DarkBtn 'Browse' 460 37 90
    $btnLocal.Add_Click({
        $p = Select-FolderDialog -Description 'Folder on this PC' -Start $tbLocal.Text
        if ($p) { $tbLocal.Text = $p }
    })
    $f.Controls.AddRange(@($tbLocal, $btnLocal))

    $f.Controls.Add((New-DarkLabel 'Cloud or backup folder' 20 76 400))
    $tbRemote = New-DarkTextBox 20 98 430
    $btnRemote = New-DarkBtn 'Browse' 460 97 90
    $lblKind = New-DarkLabel '' 20 128 400
    $btnRemote.Add_Click({
        $p = Select-FolderDialog -Description 'Cloud or backup folder' -Start $tbRemote.Text
        if ($p) {
            $tbRemote.Text = $p
            $lblKind.Text = 'Detected: {0}' -f (Get-ProviderLabel -Path $p)
        }
    })
    $f.Controls.AddRange(@($tbRemote, $btnRemote, $lblKind))

    $f.Controls.Add((New-DarkLabel 'First sync copies from:' 20 156 160))
    $rbLocal = New-Object System.Windows.Forms.RadioButton
    $rbLocal.Text = 'This PC'; $rbLocal.Checked = $true
    $rbLocal.ForeColor = $script:TextPrimary; $rbLocal.BackColor = [System.Drawing.Color]::Transparent
    $rbLocal.Location = New-Object System.Drawing.Point -ArgumentList 190, 154; $rbLocal.Size = New-Object System.Drawing.Size -ArgumentList 100, 22
    $rbRemote = New-Object System.Windows.Forms.RadioButton
    $rbRemote.Text = 'Cloud folder'
    $rbRemote.ForeColor = $script:TextPrimary; $rbRemote.BackColor = [System.Drawing.Color]::Transparent
    $rbRemote.Location = New-Object System.Drawing.Point -ArgumentList 300, 154; $rbRemote.Size = New-Object System.Drawing.Size -ArgumentList 130, 22
    $f.Controls.AddRange(@($rbLocal, $rbRemote))

    $cbSafe = New-Object System.Windows.Forms.CheckBox
    $cbSafe.Text = 'Keep deleted files in the Recycle Bin'
    $cbSafe.ForeColor = $script:TextPrimary; $cbSafe.BackColor = [System.Drawing.Color]::Transparent
    $cbSafe.Location = New-Object System.Drawing.Point -ArgumentList 20, 186; $cbSafe.Size = New-Object System.Drawing.Size -ArgumentList 500, 22
    $cbSafe.Checked = $true
    $f.Controls.Add($cbSafe)

    $ok = New-DarkBtn 'Add' 360 230 90
    $ok.BackColor = $script:AccentBlue
    $ok.FlatAppearance.BorderColor = $script:AccentBlue
    $ok.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(255, 70, 155, 245) })
    $ok.Add_MouseLeave({ $this.BackColor = $script:AccentBlue })

    $cancel = New-DarkBtn 'Cancel' 460 230 90
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($ok, $cancel))
    $f.CancelButton = $cancel

    $ok.Add_Click({
        $local  = $tbLocal.Text.Trim()
        $remote = $tbRemote.Text.Trim()
        if (-not $local -or -not $remote) {
            [System.Windows.Forms.MessageBox]::Show($f, 'Choose both folders.', 'Add folder', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $local) -or -not (Test-Path -LiteralPath $remote)) {
            [System.Windows.Forms.MessageBox]::Show($f, 'One of those folders does not exist.', 'Add folder', 'OK', 'Warning') | Out-Null
            return
        }
        try {
            $settings = Get-AppSettings
            $seed = if ($rbLocal.Checked) { 'Local' } else { 'Remote' }
            $link = Add-Link -Local $local -Remote $remote -Seed $seed -SettleMinutes $settings.SettleMinutes -MaxDelete $settings.MaxDelete -HydrateBeforeDelete ([bool]$cbSafe.Checked)
            $mf = Join-Path (Join-Path $script:StateRoot $link.Id) 'manifest.json'
            if (Test-Path -LiteralPath $mf) {
                Move-Item -LiteralPath $mf -Destination ("$mf.superseded-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
            }
            Write-Log ("link added via UI: {0}  {1} <-> {2}" -f $link.Id, $link.LocalPath, $link.RemotePath)
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($f, $_.Exception.Message, 'Could not add folder', 'OK', 'Error') | Out-Null
        }
    })

    return $f.ShowDialog($Owner)
}

# -------------------------------------------------------- settings dialog ---

function Show-SettingsDialog {
    param([object] $Owner)

    $current = Get-AppSettings

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = 'DriveRelay Settings'
    $f.Size            = New-Object System.Drawing.Size -ArgumentList 540, 478
    $f.StartPosition   = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false; $f.MinimizeBox = $false
    $f.BackColor       = $script:BgColor
    $f.ForeColor       = $script:TextPrimary
    $f.Font            = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5
    if ($script:AppIcon) { $f.Icon = $script:AppIcon }

    try { [DwmHelper]::SetDarkTitleBar($f.Handle) } catch { }

    function New-DarkLabel($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $script:TextPrimary
        $l.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $l.Size = New-Object System.Drawing.Size -ArgumentList $w, 20
        $l.BackColor = [System.Drawing.Color]::Transparent
        return $l
    }
    function New-DarkSubLabel($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $script:TextMuted
        $l.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $l.Size = New-Object System.Drawing.Size -ArgumentList $w, 18
        $l.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
        $l.BackColor = [System.Drawing.Color]::Transparent
        return $l
    }
    function New-DarkNumBox($val, $min, $max, $x, $y, $w) {
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Minimum = $min; $num.Maximum = $max; $num.Value = [Math]::Max($min, [Math]::Min($max, $val))
        $num.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $num.Size = New-Object System.Drawing.Size -ArgumentList $w, 26
        $num.BackColor = $script:CardColor; $num.ForeColor = $script:TextPrimary
        return $num
    }
    function New-DarkBtn($text, $x, $y, $w) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'
        $b.BackColor = $script:BtnBg; $b.ForeColor = $script:TextPrimary
        $b.FlatAppearance.BorderColor = $script:SepColor
        $b.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $b.Size = New-Object System.Drawing.Size -ArgumentList $w, 28
        $b.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $b.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
        $b.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
        return $b
    }

    # Settle time
    $f.Controls.Add((New-DarkLabel 'Settle time before sync (minutes)' 24 20 400))
    $f.Controls.Add((New-DarkSubLabel 'Wait duration after file writes stop before syncing changes.' 24 40 480))
    $numSettle = New-DarkNumBox $current.SettleMinutes 0 120 24 62 100
    $f.Controls.Add($numSettle)

    # Sync interval
    $f.Controls.Add((New-DarkLabel 'Background sync interval (minutes)' 24 100 400))
    $f.Controls.Add((New-DarkSubLabel 'How frequently the background system tray runs a sync pass.' 24 120 480))
    $numInterval = New-DarkNumBox $current.IntervalMinutes 1 1440 24 142 100
    $f.Controls.Add($numInterval)

    # Max deletions limit
    $f.Controls.Add((New-DarkLabel 'Maximum deletions safety threshold' 24 180 400))
    $f.Controls.Add((New-DarkSubLabel 'Abort sync pass if proposed file deletions exceed this count.' 24 200 480))
    $numMaxDelete = New-DarkNumBox $current.MaxDelete 1 10000 24 222 100
    $f.Controls.Add($numMaxDelete)

    # Safe delete checkbox
    $cbSafe = New-Object System.Windows.Forms.CheckBox
    $cbSafe.Text = 'Keep deleted cloud files in Recycle Bin (Hydrate before delete)'
    $cbSafe.ForeColor = $script:TextPrimary; $cbSafe.BackColor = [System.Drawing.Color]::Transparent
    $cbSafe.Location = New-Object System.Drawing.Point -ArgumentList 24, 264; $cbSafe.Size = New-Object System.Drawing.Size -ArgumentList 480, 22
    $cbSafe.Checked = [bool]$current.HydrateBeforeDelete
    $f.Controls.Add($cbSafe)

    # Start with Windows
    $cbStartup = New-Object System.Windows.Forms.CheckBox
    $cbStartup.Text = 'Start DriveRelay background agent when Windows starts'
    $cbStartup.ForeColor = $script:TextPrimary; $cbStartup.BackColor = [System.Drawing.Color]::Transparent
    $cbStartup.Location = New-Object System.Drawing.Point -ArgumentList 24, 292; $cbStartup.Size = New-Object System.Drawing.Size -ArgumentList 480, 22
    $cbStartup.Checked = [bool]$current.StartWithWindows
    $f.Controls.Add($cbStartup)

    # Apply-to-all, opt in.
    #
    # Saving here used to force the global settle time and max-delete onto every
    # link, which silently destroyed exactly the per-link overrides the Edit
    # dialog exists to set. Now it only happens if asked for, and the label says
    # what it will do.
    $cbApplyAll = New-Object System.Windows.Forms.CheckBox
    $cbApplyAll.Text = 'Also apply settle time and max deletions to all existing folder pairs'
    $cbApplyAll.ForeColor = $script:TextPrimary; $cbApplyAll.BackColor = [System.Drawing.Color]::Transparent
    $cbApplyAll.Location = New-Object System.Drawing.Point -ArgumentList 24, 320; $cbApplyAll.Size = New-Object System.Drawing.Size -ArgumentList 480, 22
    $cbApplyAll.Checked = $false
    $f.Controls.Add($cbApplyAll)

    $f.Controls.Add((New-DarkSubLabel 'Leave unticked to keep any per-pair values set with Edit.' 44 342 460))

    # Buttons
    $ok = New-DarkBtn 'Save settings' 290 372 120
    $ok.BackColor = $script:AccentBlue
    $ok.FlatAppearance.BorderColor = $script:AccentBlue
    $ok.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(255, 70, 155, 245) })
    $ok.Add_MouseLeave({ $this.BackColor = $script:AccentBlue })

    $cancel = New-DarkBtn 'Cancel' 420 372 90
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($ok, $cancel))
    $f.CancelButton = $cancel

    $ok.Add_Click({
        $newSettings = [pscustomobject]@{
            IntervalMinutes     = [int]$numInterval.Value
            SettleMinutes       = [int]$numSettle.Value
            MaxDelete           = [int]$numMaxDelete.Value
            HydrateBeforeDelete = [bool]$cbSafe.Checked
            StartWithWindows    = [bool]$cbStartup.Checked
            StartDelaySeconds   = [int]$current.StartDelaySeconds
            Paused              = [bool]$current.Paused
        }
        Save-AppSettings -Settings $newSettings

        # Only on request -- see the note by the checkbox.
        $applied = 0
        if ($cbApplyAll.Checked) {
            foreach ($l in @(Get-LinkRegistry)) {
                if ($l.SettleMinutes -ne $newSettings.SettleMinutes -or $l.MaxDelete -ne $newSettings.MaxDelete) {
                    $null = Set-LinkSettings -Id $l.Id -SettleMinutes $newSettings.SettleMinutes -MaxDelete $newSettings.MaxDelete
                    $applied++
                }
            }
        }

        Write-Log ("settings saved via UI: Interval={0}m Settle={1}m MaxDelete={2}; per-link overrides {3}" -f
                   $newSettings.IntervalMinutes, $newSettings.SettleMinutes, $newSettings.MaxDelete,
                   $(if ($cbApplyAll.Checked) { "overwritten on $applied link(s)" } else { 'preserved' }))
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })

    return $f.ShowDialog($Owner)
}

# ------------------------------------------------------ link edit dialog ---

function Show-LinkEditDialog {
    param([object] $Owner, [object] $Link)

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = "Edit Link: $($Link.Id)"
    $f.Size            = New-Object System.Drawing.Size -ArgumentList 540, 390
    $f.StartPosition   = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false; $f.MinimizeBox = $false
    $f.BackColor       = $script:BgColor
    $f.ForeColor       = $script:TextPrimary
    $f.Font            = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5
    if ($script:AppIcon) { $f.Icon = $script:AppIcon }

    try { [DwmHelper]::SetDarkTitleBar($f.Handle) } catch { }

    function New-DarkLabel($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $script:TextPrimary
        $l.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $l.Size = New-Object System.Drawing.Size -ArgumentList $w, 20
        $l.BackColor = [System.Drawing.Color]::Transparent
        return $l
    }
    function New-DarkSubLabel($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $script:TextMuted
        $l.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $l.Size = New-Object System.Drawing.Size -ArgumentList $w, 18
        $l.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
        $l.BackColor = [System.Drawing.Color]::Transparent
        return $l
    }
    function New-DarkNumBox($val, $min, $max, $x, $y, $w) {
        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.Minimum = $min; $num.Maximum = $max; $num.Value = [Math]::Max($min, [Math]::Min($max, $val))
        $num.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $num.Size = New-Object System.Drawing.Size -ArgumentList $w, 26
        $num.BackColor = $script:CardColor; $num.ForeColor = $script:TextPrimary
        return $num
    }
    function New-DarkBtn($text, $x, $y, $w) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'
        $b.BackColor = $script:BtnBg; $b.ForeColor = $script:TextPrimary
        $b.FlatAppearance.BorderColor = $script:SepColor
        $b.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
        $b.Size = New-Object System.Drawing.Size -ArgumentList $w, 28
        $b.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $b.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
        $b.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
        return $b
    }

    # Paths display
    $f.Controls.Add((New-DarkSubLabel "Local: $($Link.LocalPath)" 24 16 480))
    $remote = Get-RemotePath -Link $Link
    $f.Controls.Add((New-DarkSubLabel "Remote: $remote" 24 38 480))

    # Settle time
    $settleVal = if ($Link.SettleMinutes -ne $null) { [int]$Link.SettleMinutes } else { 3 }
    $f.Controls.Add((New-DarkLabel 'Settle time for this link (minutes)' 24 70 400))
    $f.Controls.Add((New-DarkSubLabel 'Minutes to wait after file activity ceases before syncing.' 24 90 480))
    $numSettle = New-DarkNumBox $settleVal 0 120 24 112 100
    $f.Controls.Add($numSettle)

    # Max delete
    $maxDelVal = if ($Link.MaxDelete -ne $null) { [int]$Link.MaxDelete } else { 50 }
    $f.Controls.Add((New-DarkLabel 'Max deletions threshold' 24 150 400))
    $f.Controls.Add((New-DarkSubLabel 'Aborts sync if file deletions exceed this threshold.' 24 170 480))
    $numMaxDelete = New-DarkNumBox $maxDelVal 1 10000 24 192 100
    $f.Controls.Add($numMaxDelete)

    # Safe delete checkbox
    $safeVal = if ($Link.HydrateBeforeDelete -ne $null) { [bool]$Link.HydrateBeforeDelete } else { $true }
    $cbSafe = New-Object System.Windows.Forms.CheckBox
    $cbSafe.Text = 'Keep deleted files in Recycle Bin (Hydrate before delete)'
    $cbSafe.ForeColor = $script:TextPrimary; $cbSafe.BackColor = [System.Drawing.Color]::Transparent
    $cbSafe.Location = New-Object System.Drawing.Point -ArgumentList 24, 234; $cbSafe.Size = New-Object System.Drawing.Size -ArgumentList 480, 22
    $cbSafe.Checked = $safeVal
    $f.Controls.Add($cbSafe)

    # Remove link button (red)
    $btnDelete = New-DarkBtn 'Remove folder pair' 24 300 140
    $btnDelete.ForeColor = [System.Drawing.Color]::FromArgb(255, 255, 120, 120)
    $btnDelete.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show($f, "Unregister '$($Link.Id)'? No files will be deleted.", 'Remove folder pair', 'YesNo', 'Question')
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Remove-Link -Id $Link.Id
            $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $f.Close()
        }
    })
    $f.Controls.Add($btnDelete)

    # Save & Cancel
    $ok = New-DarkBtn 'Save' 310 300 90
    $ok.BackColor = $script:AccentBlue
    $ok.FlatAppearance.BorderColor = $script:AccentBlue
    $ok.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(255, 70, 155, 245) })
    $ok.Add_MouseLeave({ $this.BackColor = $script:AccentBlue })

    $cancel = New-DarkBtn 'Cancel' 410 300 90
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($ok, $cancel))
    $f.CancelButton = $cancel

    $ok.Add_Click({
        Set-LinkSettings -Id $Link.Id -SettleMinutes ([int]$numSettle.Value) -MaxDelete ([int]$numMaxDelete.Value) -HydrateBeforeDelete ([bool]$cbSafe.Checked)
        Write-Log ("link {0} settings updated: Settle={1}m MaxDelete={2}" -f $Link.Id, $numSettle.Value, $numMaxDelete.Value)
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $f.Close()
    })

    return $f.ShowDialog($Owner)
}

# ------------------------------------------------------------ main window ---

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'DriveRelay'
$form.Size          = New-Object System.Drawing.Size -ArgumentList 920, 620
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size -ArgumentList 760, 500
$form.BackColor     = $script:BgColor
$form.ForeColor     = $script:TextPrimary
$form.Font          = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5

# Apply dark title bar and window icon.
$form.Add_HandleCreated({ try { [DwmHelper]::SetDarkTitleBar($form.Handle) } catch { } })
if ($script:AppIcon) { $form.Icon = $script:AppIcon }

# ---- top header bar ----
$headerBar = New-Object System.Windows.Forms.Panel
$headerBar.Location  = New-Object System.Drawing.Point -ArgumentList 0, 0
$headerBar.Size      = New-Object System.Drawing.Size -ArgumentList 920, 112
$headerBar.Anchor    = 'Top,Left,Right'
$headerBar.BackColor = $script:HeaderColor
$form.Controls.Add($headerBar)

# Header logo from badge / png asset
$logoCandidates = @(
    (Join-Path $root 'assets\DriveRelay_badge.png'),
    (Join-Path $root 'assets\DriveRelay.png'),
    (Join-Path $root 'DriveRelay.png')
)
$logoPath = $logoCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($logoPath) {
    try {
        $logoPb = New-Object System.Windows.Forms.PictureBox
        $logoPb.Location = New-Object System.Drawing.Point -ArgumentList 20, 17
        $logoPb.Size = New-Object System.Drawing.Size -ArgumentList 48, 48
        $logoPb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $logoPb.Image = [System.Drawing.Image]::FromFile($logoPath)
        $logoPb.BackColor = [System.Drawing.Color]::Transparent
        $headerBar.Controls.Add($logoPb)
    } catch { }
}

$lblAppTitle = New-Object System.Windows.Forms.Label
$lblAppTitle.Text = 'DriveRelay'
$lblAppTitle.Location = New-Object System.Drawing.Point -ArgumentList 82, 18
$lblAppTitle.Size = New-Object System.Drawing.Size -ArgumentList 260, 25
$lblAppTitle.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold)
$lblAppTitle.ForeColor = $script:TextPrimary
$lblAppTitle.BackColor = [System.Drawing.Color]::Transparent
$headerBar.Controls.Add($lblAppTitle)

$lblAppSub = New-Object System.Windows.Forms.Label
$lblAppSub.Text = 'Your local folders, safely relayed to cloud storage.'
$lblAppSub.Location = New-Object System.Drawing.Point -ArgumentList 83, 45
$lblAppSub.Size = New-Object System.Drawing.Size -ArgumentList 340, 18
$lblAppSub.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$lblAppSub.ForeColor = $script:TextMuted
$lblAppSub.BackColor = [System.Drawing.Color]::Transparent
$headerBar.Controls.Add($lblAppSub)

function New-HeaderMetric($caption, $x, $w) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point -ArgumentList $x, 72
    $panel.Size = New-Object System.Drawing.Size -ArgumentList $w, 32
    $panel.Anchor = 'Top,Right'
    $panel.BackColor = $script:PanelColor

    $captionLabel = New-Object System.Windows.Forms.Label
    $captionLabel.Text = $caption.ToUpperInvariant()
    $captionLabel.Location = New-Object System.Drawing.Point -ArgumentList 8, 3
    $captionLabel.Size = New-Object System.Drawing.Size -ArgumentList ($w - 16), 12
    $captionLabel.Font = $script:FontCaption
    $captionLabel.ForeColor = $script:TextMuted
    $captionLabel.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($captionLabel)

    $value = New-Object System.Windows.Forms.Label
    $value.Location = New-Object System.Drawing.Point -ArgumentList 8, 15
    $value.Size = New-Object System.Drawing.Size -ArgumentList ($w - 16), 15
    $value.Font = $script:FontStatus
    $value.ForeColor = $script:TextPrimary
    $value.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($value)
    $headerBar.Controls.Add($panel)
    return $value
}

$summaryLinks   = New-HeaderMetric 'Folder pairs' 480 105
$summaryHealth  = New-HeaderMetric 'Status' 594 150
$summaryLastRun = New-HeaderMetric 'Last sync' 753 145

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'Sync all now'
$btnSync.FlatStyle = 'Flat'
$btnSync.BackColor = $script:AccentBlue
$btnSync.ForeColor = [System.Drawing.Color]::White
$btnSync.FlatAppearance.BorderColor = $script:AccentBlue
$btnSync.Location = New-Object System.Drawing.Point -ArgumentList 753, 24
$btnSync.Size = New-Object System.Drawing.Size -ArgumentList 145, 34
$btnSync.Anchor = 'Top,Right'
$btnSync.Font = $script:FontBtn
$btnSync.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(255, 70, 155, 245) })
$btnSync.Add_MouseLeave({ $this.BackColor = $script:AccentBlue })
$headerBar.Controls.Add($btnSync)

# At the minimum supported width the status tiles would compete with the
# product description. Hide the secondary information instead of letting
# controls overlap; the full summary returns as soon as the window is widened.
$form.Add_Resize({
    $compact = $form.ClientSize.Width -lt 860
    $lblAppSub.Visible = -not $compact
    foreach ($metric in @($summaryLinks, $summaryHealth, $summaryLastRun)) {
        $metric.Parent.Visible = -not $compact
    }
})

# ---- scrollable card container ----
$cardPanel = New-Object System.Windows.Forms.Panel
$cardPanel.Location   = New-Object System.Drawing.Point -ArgumentList 0, 112
$cardPanel.Size       = New-Object System.Drawing.Size -ArgumentList 900, 413
$cardPanel.Anchor     = 'Top,Left,Right,Bottom'
$cardPanel.AutoScroll = $true
$cardPanel.BackColor  = $script:BgColor
$form.Controls.Add($cardPanel)

# ---- bottom action bar ----
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Location  = New-Object System.Drawing.Point -ArgumentList 0, 525
$actionBar.Size      = New-Object System.Drawing.Size -ArgumentList 920, 56
$actionBar.Anchor    = 'Bottom,Left,Right'
$actionBar.BackColor = $script:HeaderColor
$form.Controls.Add($actionBar)

# Status label in action bar.
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location  = New-Object System.Drawing.Point -ArgumentList 160, 18
$statusLabel.Size      = New-Object System.Drawing.Size -ArgumentList 410, 20
$statusLabel.Anchor    = 'Top,Left,Right'
$statusLabel.ForeColor = $script:TextMuted
$statusLabel.BackColor = [System.Drawing.Color]::Transparent
$statusLabel.Font      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$actionBar.Controls.Add($statusLabel)

function New-ActionBtn($text, $x, $w=105, [bool] $rightAligned=$false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.FlatStyle = 'Flat'
    $b.BackColor = $script:BtnBg; $b.ForeColor = $script:TextPrimary
    $b.FlatAppearance.BorderColor = $script:SepColor
    $b.Location = New-Object System.Drawing.Point -ArgumentList $x, 13
    $b.Size = New-Object System.Drawing.Size -ArgumentList $w, 30
    $b.Anchor = if ($rightAligned) { 'Bottom,Right' } else { 'Bottom,Left' }
    $b.Font = $script:FontBtn
    $b.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
    $b.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
    return $b
}

$btnAdd      = New-ActionBtn '+ Add folder pair' 16 136
$btnSettings = New-ActionBtn 'Settings' 630 90 $true
$btnLog      = New-ActionBtn 'View log' 728 88 $true
$btnClose    = New-ActionBtn 'Close' 824 76 $true
$actionBar.Controls.AddRange(@($btnAdd, $btnSettings, $btnLog, $btnClose))

# ------------------------------------------------------------ card builder ---

function New-LinkCard {
    param([object] $Link, [int] $Y)

    # Scan at render time so the affordance is only present while conflict
    # copies actually exist.  Pass summaries can be stale between background
    # runs, whereas this inexpensive metadata-only inventory is current.
    $duplicateCopies = if ($script:ConflictCopiesByLink.ContainsKey($Link.Id)) {
        @($script:ConflictCopiesByLink[$Link.Id])
    } else {
        try { @(Get-LinkConflictCopies -Link $Link) } catch { @() }
    }
    $duplicatesExpanded = ($script:ExpandedDuplicateLink -eq $Link.Id -and $duplicateCopies.Count -gt 0)
    $cardHeight = if ($duplicatesExpanded) { 398 } else { 116 }

    $card = New-Object System.Windows.Forms.Panel
    $card.Location  = New-Object System.Drawing.Point -ArgumentList 18, $Y
    $card.Size      = New-Object System.Drawing.Size -ArgumentList 864, $cardHeight
    $card.Anchor    = 'Top,Left,Right'
    $card.BackColor = $script:CardColor
    $card.Tag       = $Link.Id
    $card.Cursor    = [System.Windows.Forms.Cursors]::Hand

    # A restrained border and a status stripe distinguish links without making
    # the dashboard look like a wall of equally weighted buttons.
    $card.Add_Paint({
        param($s, $e)
        $r = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($s.Width - 1), ($s.Height - 1)
        $pen = New-Object System.Drawing.Pen -ArgumentList $script:SepColor, 1
        $e.Graphics.DrawRectangle($pen, $r)
        $pen.Dispose()
    })

    $card.Add_MouseEnter({ $this.BackColor = $script:CardHover })
    $card.Add_MouseLeave({ $this.BackColor = $script:CardColor })

    $si = Get-StatusInfo -Link $Link -ConflictCopies $duplicateCopies -ConflictCopiesChecked
    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Location = New-Object System.Drawing.Point -ArgumentList 0, 0
    $stripe.Size = New-Object System.Drawing.Size -ArgumentList 5, $cardHeight
    $stripe.Anchor = 'Top,Bottom,Left'
    $stripe.BackColor = $si.Color
    $card.Controls.Add($stripe)

    # Link name (bold).
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = $Link.Id
    $lblName.Font = $script:FontName
    $lblName.ForeColor = $script:TextPrimary
    $lblName.BackColor = [System.Drawing.Color]::Transparent
    $lblName.Location = New-Object System.Drawing.Point -ArgumentList 20, 12
    $lblName.Size = New-Object System.Drawing.Size -ArgumentList 464, 22
    $lblName.Anchor = 'Top,Left,Right'
    $card.Controls.Add($lblName)

    # Status badge.
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = $si.Text
    $lblStatus.Font = $script:FontStatus
    $lblStatus.ForeColor = $si.Color
    $lblStatus.BackColor = [System.Drawing.Color]::Transparent
    $lblStatus.TextAlign = 'TopRight'
    $lblStatus.Location = New-Object System.Drawing.Point -ArgumentList 604, 12
    $lblStatus.Size = New-Object System.Drawing.Size -ArgumentList 240, 64
    $lblStatus.Anchor = 'Top,Right'
    $card.Controls.Add($lblStatus)

    # The badge shows the immediate reason; the tooltip retains the complete
    # saved result and any suggested remedy.
    if ($si.Detail) {
        $tip = New-Object System.Windows.Forms.ToolTip
        $tip.AutoPopDelay = 20000
        $tip.InitialDelay = 300
        $tip.SetToolTip($lblStatus, $si.Detail)
        $tip.SetToolTip($card, $si.Detail)
    }

    # Paths have labels so it is clear at a glance which side is the fast work
    # folder and which is the cloud or backup destination.
    $remote = Get-RemotePath -Link $Link
    $drive = Get-ProviderLabel -Path $remote
    foreach ($pathInfo in @(
        [pscustomobject]@{ Label = 'LOCAL';  Value = $Link.LocalPath; Y = 40 }
        [pscustomobject]@{ Label = 'REMOTE'; Value = $remote;         Y = 62 }
    )) {
        $caption = New-Object System.Windows.Forms.Label
        $caption.Text = $pathInfo.Label
        $caption.Font = $script:FontCaption
        $caption.ForeColor = $script:TextMuted
        $caption.BackColor = [System.Drawing.Color]::Transparent
        $caption.Location = New-Object System.Drawing.Point -ArgumentList 20, $pathInfo.Y
        $caption.Size = New-Object System.Drawing.Size -ArgumentList 54, 16
        $card.Controls.Add($caption)

        $value = New-Object System.Windows.Forms.Label
        $value.Text = $pathInfo.Value
        $value.Font = $script:FontPath
        $value.ForeColor = $script:TextPrimary
        $value.BackColor = [System.Drawing.Color]::Transparent
        $value.Location = New-Object System.Drawing.Point -ArgumentList 80, $pathInfo.Y
        $value.Size = New-Object System.Drawing.Size -ArgumentList 514, 16
        $value.Anchor = 'Top,Left,Right'
        $value.AutoEllipsis = $true
        $card.Controls.Add($value)
        if ($pathInfo.Label -eq 'LOCAL') { $lblPaths = $value }
    }

    # Drive label + settle time + last sync.
    $lastSync = if ($Link.LastRun) { $Link.LastRun } else { 'never' }
    $settleStr = if ($Link.SettleMinutes -ne $null) { "$($Link.SettleMinutes)m" } else { "3m" }
    $lblMeta = New-Object System.Windows.Forms.Label
    $lblMeta.Text = "{0}  |  Settle: {1}  |  Last sync: {2}" -f $drive, $settleStr, $lastSync
    $lblMeta.Font = $script:FontPath
    $lblMeta.ForeColor = $script:TextMuted
    $lblMeta.BackColor = [System.Drawing.Color]::Transparent
    $lblMeta.Location = New-Object System.Drawing.Point -ArgumentList 20, 88
    $lblMeta.Size = New-Object System.Drawing.Size -ArgumentList 488, 18
    $lblMeta.Anchor = 'Top,Left,Right'
    $card.Controls.Add($lblMeta)

    if ($duplicateCopies.Count -gt 0) {
        $btnDuplicates = New-Object System.Windows.Forms.Button
        $btnDuplicates.Text = if ($duplicatesExpanded) { 'Hide' } else { 'Duplicates' }
        $btnDuplicates.FlatStyle = 'Flat'
        $btnDuplicates.BackColor = $script:BtnBg
        $btnDuplicates.ForeColor = $script:TextPrimary
        $btnDuplicates.Location = New-Object System.Drawing.Point -ArgumentList 514, 84
        $btnDuplicates.Size = New-Object System.Drawing.Size -ArgumentList 84, 25
        $btnDuplicates.Anchor = 'Top,Right'
        $btnDuplicates.Tag = $Link.Id
        $btnDuplicates.Add_Click({
            $script:ExpandedDuplicateLink = if ($script:ExpandedDuplicateLink -eq $this.Tag) { $null } else { $this.Tag }
            Update-Cards
        })
        $card.Controls.Add($btnDuplicates)

        if ($duplicatesExpanded) {
            $details = New-Object System.Windows.Forms.Panel
            $details.Location = New-Object System.Drawing.Point -ArgumentList 20, 122
            $details.Size = New-Object System.Drawing.Size -ArgumentList 824, 258
            $details.Anchor = 'Top,Left,Right,Bottom'
            $details.BackColor = $script:BgColor
            $card.Controls.Add($details)
            $details.Controls.Add((New-ConflictGrid -Copies $duplicateCopies))
        }
    }

    # Give the common double-click action a visible button as well.
    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Open folder'
    $btnOpen.FlatStyle = 'Flat'
    $btnOpen.BackColor = $script:BtnBg
    $btnOpen.ForeColor = $script:TextPrimary
    $btnOpen.FlatAppearance.BorderColor = $script:SepColor
    $btnOpen.Location = New-Object System.Drawing.Point -ArgumentList 604, 84
    $btnOpen.Size = New-Object System.Drawing.Size -ArgumentList 84, 25
    $btnOpen.Anchor = 'Top,Right'
    $btnOpen.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8
    $btnOpen.Tag = $Link.Id
    $btnOpen.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
    $btnOpen.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
    $btnOpen.Add_Click({
        $lid = $this.Tag
        $lnk = Get-LinkRegistry | Where-Object { $_.Id -eq $lid }
        if ($lnk -and (Test-Path -LiteralPath $lnk.LocalPath)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $lnk.LocalPath)
        }
    })
    $card.Controls.Add($btnOpen)

    # Edit button.
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = 'Edit'
    $btnEdit.FlatStyle = 'Flat'
    $btnEdit.BackColor = $script:BtnBg
    $btnEdit.ForeColor = $script:TextPrimary
    $btnEdit.FlatAppearance.BorderColor = $script:SepColor
    $btnEdit.Location = New-Object System.Drawing.Point -ArgumentList 696, 84
    $btnEdit.Size = New-Object System.Drawing.Size -ArgumentList 48, 25
    $btnEdit.Anchor = 'Top,Right'
    $btnEdit.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8
    $btnEdit.Tag = $Link.Id
    $btnEdit.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
    $btnEdit.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
    $btnEdit.Add_Click({
        $lid = $this.Tag
        $lnk = Get-LinkRegistry | Where-Object { $_.Id -eq $lid }
        if ($lnk) {
            if ((Show-LinkEditDialog -Owner $form -Link $lnk) -eq [System.Windows.Forms.DialogResult]::OK) {
                Update-Cards
            }
        }
    })
    $card.Controls.Add($btnEdit)

    # Pause/Resume button.
    $btnToggle = New-Object System.Windows.Forms.Button
    $btnToggle.Text = if ($Link.Enabled) { 'Pause' } else { 'Resume' }
    $btnToggle.FlatStyle = 'Flat'
    $btnToggle.BackColor = $script:BtnBg
    $btnToggle.ForeColor = $script:TextPrimary
    $btnToggle.FlatAppearance.BorderColor = $script:SepColor
    $btnToggle.Location = New-Object System.Drawing.Point -ArgumentList 752, 84
    $btnToggle.Size = New-Object System.Drawing.Size -ArgumentList 92, 25
    $btnToggle.Anchor = 'Top,Right'
    $btnToggle.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8
    $btnToggle.Tag = $Link.Id
    $btnToggle.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
    $btnToggle.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
    $btnToggle.Add_Click({
        $lid = $this.Tag
        $lnk = Get-LinkRegistry | Where-Object { $_.Id -eq $lid }
        if ($lnk) {
            Set-LinkEnabled -Id $lid -Enabled (-not $lnk.Enabled)
            Update-Cards
        }
    })
    $card.Controls.Add($btnToggle)

    # Double-click card to open local folder.
    #
    # .GetNewClosure() is required, not decorative. A plain scriptblock is not a
    # closure in PowerShell: it resolves its variables when it runs, and by then
    # New-LinkCard has long since returned, so $Link would be $null and the
    # handler would open nothing (or the wrong folder). GetNewClosure snapshots
    # $Link now. The Edit and Pause buttons above solve the same problem the
    # other way, by stashing the id in .Tag and re-reading the registry.
    $openLocal = {
        $target = $Link.LocalPath
        if ($target -and (Test-Path -LiteralPath $target)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $target)
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                ("That folder is not there any more:`r`n{0}" -f $target),
                'Open folder', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure()

    $card.Add_DoubleClick($openLocal)
    $lblName.Add_DoubleClick($openLocal)
    $lblPaths.Add_DoubleClick($openLocal)

    return $card
}

function Update-Cards {
    $cardPanel.Controls.Clear()
    $links = @(Get-LinkRegistry)
    $sum = Read-PassSummarySafe
    $script:ConflictCopiesByLink = @{}
    foreach ($link in $links) {
        try { $script:ConflictCopiesByLink[$link.Id] = @(Get-LinkConflictCopies -Link $link) }
        catch { $script:ConflictCopiesByLink[$link.Id] = @() }
    }

    $summaryLinks.Text = "{0} linked" -f $links.Count
    $summaryLastRun.Text = if ($sum) { $sum.When } else { 'Not run yet' }

    $paused = $false
    try { $paused = [bool](Get-AppSettings).Paused } catch { }

    if ($paused) {
        $summaryHealth.ForeColor = $script:StatusAmber
        $summaryHealth.Text = 'Background paused'
    }
    elseif ($links.Count -eq 0) {
        $summaryHealth.ForeColor = $script:TextMuted
        $summaryHealth.Text = 'Ready to add'
    }
    else {
        $attention = @($links | Where-Object {
            $status = Get-StatusInfo -Link $_ -ConflictCopies $script:ConflictCopiesByLink[$_.Id] -ConflictCopiesChecked
            if ($status.ContainsKey('Attention')) { return [bool]$status.Attention }
            return $status.Text -ne 'Up to date'
        }).Count
        $summaryHealth.ForeColor = if ($attention -gt 0) { $script:StatusAmber } else { $script:StatusGreen }
        $summaryHealth.Text = if ($attention -eq 1) { '1 needs attention' }
                              elseif ($attention -gt 1) { "{0} need attention" -f $attention }
                              else { 'All healthy' }
    }

    if ($links.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = 'No folder pairs linked yet. Add a folder pair to get started.'
        $empty.ForeColor = $script:TextMuted
        $empty.BackColor = [System.Drawing.Color]::Transparent
        $empty.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 10
        $empty.TextAlign = 'MiddleCenter'
        $empty.Location = New-Object System.Drawing.Point -ArgumentList 0, 150
        $empty.Size = New-Object System.Drawing.Size -ArgumentList 880, 40
        $empty.Anchor = 'Top,Left,Right'
        $cardPanel.Controls.Add($empty)
        $statusLabel.Text = ''
        return
    }

    $y = 16
    foreach ($l in $links) {
        $card = New-LinkCard -Link $l -Y $y
        $cardPanel.Controls.Add($card)
        $y += $card.Height + 12
    }

    $base = if ($sum) { "Last sync {0} - {1} change(s), {2} conflict(s)" -f $sum.When, $sum.Applied, $sum.Conflicts }
            else      { "{0} folder pair(s) linked" -f $links.Count }

    if ($paused) {
        $statusLabel.ForeColor = $script:StatusAmber
        $statusLabel.Text = "Background syncing is PAUSED (resume from the tray menu)  -  $base"
    }
    else {
        $statusLabel.ForeColor = $script:TextMuted
        $statusLabel.Text = $base
    }
}

# ------------------------------------------------------------ button wiring ---

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:Child -and $script:Child.HasExited) {
        $script:Child = $null
        $btnSync.Enabled = $true; $btnAdd.Enabled = $true
        $timer.Stop()
        Update-Cards
    }
})

# Conflict copies can be resolved in Explorer while the dashboard is open.
# Rebuild the cards periodically so the duplicate badge/list disappears without
# requiring a sync or a close-and-reopen of this window.
$duplicateRefreshTimer = New-Object System.Windows.Forms.Timer
$duplicateRefreshTimer.Interval = 5000
$duplicateRefreshTimer.Add_Tick({
    if (-not $script:Child) { Update-Cards }
})
$duplicateRefreshTimer.Start()

$btnAdd.Add_Click({
    if ((Show-AddDialog -Owner $form) -eq [System.Windows.Forms.DialogResult]::OK) { Update-Cards }
})

$btnSync.Add_Click({
    if ($script:Child) { return }
    $btnSync.Enabled = $false; $btnAdd.Enabled = $false
    $statusLabel.Text = 'Syncing...'
    # Wait for an existing scheduled or tray pass so an explicit dashboard
    # retry is not discarded merely because it arrived while one was finishing.
    $script:Child = Start-Cli -CliArgs @('run', '-WaitForPass')
    $timer.Start()
})

$btnSettings.Add_Click({
    if ((Show-SettingsDialog -Owner $form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Update-Cards
    }
})

$btnLog.Add_Click({
    Show-DriveRelayLog -Root $root -Owner $form -Icon $script:AppIcon
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({ Update-Cards })
[void]$form.Add_FormClosed({ $duplicateRefreshTimer.Stop(); $duplicateRefreshTimer.Dispose() })
[void]$form.ShowDialog()
