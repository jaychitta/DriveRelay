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
. (Join-Path $root 'lib\Provider.ps1')
. (Join-Path $root 'lib\Icons.ps1')
. (Join-Path $root 'lib\Registry.ps1')
. (Join-Path $root 'lib\Settings.ps1')

Set-LogPath      (Join-Path $root 'driverelay.log')
Set-RegistryPath (Join-Path $root 'config\links.json')
Set-SettingsPath (Join-Path $root 'config\settings.json')
$script:StateRoot = Join-Path $root 'state'
$script:Cli       = Join-Path $root 'DriveRelay.ps1'
$script:Child     = $null

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
$script:StatusGray   = [System.Drawing.Color]::FromArgb(255, 110, 110, 120)
$script:BtnBg        = [System.Drawing.Color]::FromArgb(255, 55, 55, 62)
$script:BtnHover     = [System.Drawing.Color]::FromArgb(255, 70, 70, 78)
$script:SepColor     = [System.Drawing.Color]::FromArgb(255, 55, 55, 62)

$script:FontName     = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 11, ([System.Drawing.FontStyle]::Bold)
$script:FontPath     = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$script:FontStatus   = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5, ([System.Drawing.FontStyle]::Bold)
$script:FontBtn      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9

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
    param([object] $Link)
    if (-not $Link.Enabled) {
        return @{ Text = 'Paused'; Color = $script:StatusGray }
    }
    if (-not $Link.Seeded) {
        return @{ Text = 'Not synced yet'; Color = $script:StatusAmber }
    }
    if ($Link.LastResult -like 'aborted*') {
        return @{ Text = 'Needs attention'; Color = $script:StatusAmber }
    }
    return @{ Text = 'Up to date'; Color = $script:StatusGreen }
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
    $f.Size            = New-Object System.Drawing.Size -ArgumentList 540, 440
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

    # Buttons
    $ok = New-DarkBtn 'Save settings' 290 348 120
    $ok.BackColor = $script:AccentBlue
    $ok.FlatAppearance.BorderColor = $script:AccentBlue
    $ok.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(255, 70, 155, 245) })
    $ok.Add_MouseLeave({ $this.BackColor = $script:AccentBlue })

    $cancel = New-DarkBtn 'Cancel' 420 348 90
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
        }
        Save-AppSettings -Settings $newSettings

        # Propagate default settle time and maxdelete to existing links if desired
        $links = @(Get-LinkRegistry)
        foreach ($l in $links) {
            if ($l.SettleMinutes -ne $newSettings.SettleMinutes -or $l.MaxDelete -ne $newSettings.MaxDelete) {
                Set-LinkSettings -Id $l.Id -SettleMinutes $newSettings.SettleMinutes -MaxDelete $newSettings.MaxDelete
            }
        }

        Write-Log ("settings saved via UI: Interval={0}m Settle={1}m MaxDelete={2}" -f $newSettings.IntervalMinutes, $newSettings.SettleMinutes, $newSettings.MaxDelete)
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
$form.Size          = New-Object System.Drawing.Size -ArgumentList 760, 520
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size -ArgumentList 620, 420
$form.BackColor     = $script:BgColor
$form.ForeColor     = $script:TextPrimary
$form.Font          = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9.5

# Apply dark title bar and window icon.
$form.Add_HandleCreated({ try { [DwmHelper]::SetDarkTitleBar($form.Handle) } catch { } })
if ($script:AppIcon) { $form.Icon = $script:AppIcon }

# ---- top header bar ----
$headerBar = New-Object System.Windows.Forms.Panel
$headerBar.Location  = New-Object System.Drawing.Point -ArgumentList 0, 0
$headerBar.Size      = New-Object System.Drawing.Size -ArgumentList 760, 54
$headerBar.Anchor    = 'Top,Left,Right'
$headerBar.BackColor = [System.Drawing.Color]::FromArgb(255, 24, 24, 28)
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
        $logoPb.Location = New-Object System.Drawing.Point -ArgumentList 16, 9
        $logoPb.Size = New-Object System.Drawing.Size -ArgumentList 36, 36
        $logoPb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $logoPb.Image = [System.Drawing.Image]::FromFile($logoPath)
        $logoPb.BackColor = [System.Drawing.Color]::Transparent
        $headerBar.Controls.Add($logoPb)
    } catch { }
}

$lblAppTitle = New-Object System.Windows.Forms.Label
$lblAppTitle.Text = 'DriveRelay'
$lblAppTitle.Location = New-Object System.Drawing.Point -ArgumentList 58, 8
$lblAppTitle.Size = New-Object System.Drawing.Size -ArgumentList 180, 22
$lblAppTitle.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 11.5, ([System.Drawing.FontStyle]::Bold)
$lblAppTitle.ForeColor = $script:TextPrimary
$lblAppTitle.BackColor = [System.Drawing.Color]::Transparent
$headerBar.Controls.Add($lblAppTitle)

$lblAppSub = New-Object System.Windows.Forms.Label
$lblAppSub.Text = 'Local NTFS working folder relay for cloud drives'
$lblAppSub.Location = New-Object System.Drawing.Point -ArgumentList 59, 29
$lblAppSub.Size = New-Object System.Drawing.Size -ArgumentList 400, 18
$lblAppSub.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$lblAppSub.ForeColor = $script:TextMuted
$lblAppSub.BackColor = [System.Drawing.Color]::Transparent
$headerBar.Controls.Add($lblAppSub)

# ---- scrollable card container ----
$cardPanel = New-Object System.Windows.Forms.Panel
$cardPanel.Location   = New-Object System.Drawing.Point -ArgumentList 0, 54
$cardPanel.Size       = New-Object System.Drawing.Size -ArgumentList 740, 356
$cardPanel.Anchor     = 'Top,Left,Right,Bottom'
$cardPanel.AutoScroll = $true
$cardPanel.BackColor  = $script:BgColor
$form.Controls.Add($cardPanel)

# ---- bottom action bar ----
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Location  = New-Object System.Drawing.Point -ArgumentList 0, 410
$actionBar.Size      = New-Object System.Drawing.Size -ArgumentList 760, 70
$actionBar.Anchor    = 'Bottom,Left,Right'
$actionBar.BackColor = [System.Drawing.Color]::FromArgb(255, 26, 26, 30)
$form.Controls.Add($actionBar)

# Status label in action bar.
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location  = New-Object System.Drawing.Point -ArgumentList 18, 8
$statusLabel.Size      = New-Object System.Drawing.Size -ArgumentList 550, 20
$statusLabel.ForeColor = $script:TextMuted
$statusLabel.BackColor = [System.Drawing.Color]::Transparent
$statusLabel.Font      = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 8.5
$actionBar.Controls.Add($statusLabel)

function New-ActionBtn($text, $x, $w=105) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.FlatStyle = 'Flat'
    $b.BackColor = $script:BtnBg; $b.ForeColor = $script:TextPrimary
    $b.FlatAppearance.BorderColor = $script:SepColor
    $b.Location = New-Object System.Drawing.Point -ArgumentList $x, 32
    $b.Size = New-Object System.Drawing.Size -ArgumentList $w, 30
    $b.Anchor = 'Bottom,Left'
    $b.Font = $script:FontBtn
    $b.Add_MouseEnter({ $this.BackColor = $script:BtnHover })
    $b.Add_MouseLeave({ $this.BackColor = $script:BtnBg })
    return $b
}

$btnAdd      = New-ActionBtn '+ Add folder' 16 110
$btnSync     = New-ActionBtn 'Sync all' 132 90
$btnSettings = New-ActionBtn 'Settings' 228 95
$btnLog      = New-ActionBtn 'View log' 329 95
$btnClose    = New-ActionBtn 'Close' 430 80
$actionBar.Controls.AddRange(@($btnAdd, $btnSync, $btnSettings, $btnLog, $btnClose))

# ------------------------------------------------------------ card builder ---

function New-LinkCard {
    param([object] $Link, [int] $Y)

    $card = New-Object System.Windows.Forms.Panel
    $card.Location  = New-Object System.Drawing.Point -ArgumentList 16, $Y
    $card.Size      = New-Object System.Drawing.Size -ArgumentList 706, 80
    $card.Anchor    = 'Top,Left,Right'
    $card.BackColor = $script:CardColor
    $card.Tag       = $Link.Id
    $card.Cursor    = [System.Windows.Forms.Cursors]::Hand

    # Rounded feel via Paint event.
    $card.Add_Paint({
        param($s, $e)
        $r = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, ($s.Width - 1), ($s.Height - 1)
        $pen = New-Object System.Drawing.Pen -ArgumentList $script:SepColor, 1
        $e.Graphics.DrawRectangle($pen, $r)
        $pen.Dispose()
    })

    $card.Add_MouseEnter({ $this.BackColor = $script:CardHover })
    $card.Add_MouseLeave({ $this.BackColor = $script:CardColor })

    # Link name (bold).
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = $Link.Id
    $lblName.Font = $script:FontName
    $lblName.ForeColor = $script:TextPrimary
    $lblName.BackColor = [System.Drawing.Color]::Transparent
    $lblName.Location = New-Object System.Drawing.Point -ArgumentList 14, 10
    $lblName.Size = New-Object System.Drawing.Size -ArgumentList 300, 22
    $card.Controls.Add($lblName)

    # Status badge.
    $si = Get-StatusInfo -Link $Link
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = $si.Text
    $lblStatus.Font = $script:FontStatus
    $lblStatus.ForeColor = $si.Color
    $lblStatus.BackColor = [System.Drawing.Color]::Transparent
    $lblStatus.TextAlign = 'TopRight'
    $lblStatus.Location = New-Object System.Drawing.Point -ArgumentList 440, 12
    $lblStatus.Size = New-Object System.Drawing.Size -ArgumentList 160, 20
    $lblStatus.Anchor = 'Top,Right'
    $card.Controls.Add($lblStatus)

    # Paths.
    $remote = Get-RemotePath -Link $Link
    $drive = Get-ProviderLabel -Path $remote
    $lblPaths = New-Object System.Windows.Forms.Label
    $lblPaths.Text = "{0}  ->  {1}" -f $Link.LocalPath, $remote
    $lblPaths.Font = $script:FontPath
    $lblPaths.ForeColor = $script:TextMuted
    $lblPaths.BackColor = [System.Drawing.Color]::Transparent
    $lblPaths.Location = New-Object System.Drawing.Point -ArgumentList 14, 36
    $lblPaths.Size = New-Object System.Drawing.Size -ArgumentList 500, 18
    $lblPaths.Anchor = 'Top,Left,Right'
    $card.Controls.Add($lblPaths)

    # Drive label + settle time + last sync.
    $lastSync = if ($Link.LastRun) { $Link.LastRun } else { 'never' }
    $settleStr = if ($Link.SettleMinutes -ne $null) { "$($Link.SettleMinutes)m" } else { "3m" }
    $lblMeta = New-Object System.Windows.Forms.Label
    $lblMeta.Text = "{0}  |  Settle: {1}  |  Last sync: {2}" -f $drive, $settleStr, $lastSync
    $lblMeta.Font = $script:FontPath
    $lblMeta.ForeColor = $script:TextMuted
    $lblMeta.BackColor = [System.Drawing.Color]::Transparent
    $lblMeta.Location = New-Object System.Drawing.Point -ArgumentList 14, 56
    $lblMeta.Size = New-Object System.Drawing.Size -ArgumentList 450, 18
    $card.Controls.Add($lblMeta)

    # Edit button.
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = 'Edit'
    $btnEdit.FlatStyle = 'Flat'
    $btnEdit.BackColor = $script:BtnBg
    $btnEdit.ForeColor = $script:TextPrimary
    $btnEdit.FlatAppearance.BorderColor = $script:SepColor
    $btnEdit.Location = New-Object System.Drawing.Point -ArgumentList 535, 48
    $btnEdit.Size = New-Object System.Drawing.Size -ArgumentList 65, 24
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
    $btnToggle.Location = New-Object System.Drawing.Point -ArgumentList 608, 48
    $btnToggle.Size = New-Object System.Drawing.Size -ArgumentList 80, 24
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
    $card.Add_DoubleClick({ Start-Process explorer.exe $Link.LocalPath })
    $lblName.Add_DoubleClick({ Start-Process explorer.exe $Link.LocalPath })
    $lblPaths.Add_DoubleClick({ Start-Process explorer.exe $Link.LocalPath })

    return $card
}

function Update-Cards {
    $cardPanel.Controls.Clear()
    $links = @(Get-LinkRegistry)

    if ($links.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.Label
        $empty.Text = 'No folder pairs linked yet. Click "+ Add folder" to get started.'
        $empty.ForeColor = $script:TextMuted
        $empty.BackColor = [System.Drawing.Color]::Transparent
        $empty.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 10
        $empty.TextAlign = 'MiddleCenter'
        $empty.Location = New-Object System.Drawing.Point -ArgumentList 0, 120
        $empty.Size = New-Object System.Drawing.Size -ArgumentList 700, 40
        $empty.Anchor = 'Top,Left,Right'
        $cardPanel.Controls.Add($empty)
        $statusLabel.Text = ''
        return
    }

    $y = 12
    foreach ($l in $links) {
        $card = New-LinkCard -Link $l -Y $y
        $cardPanel.Controls.Add($card)
        $y += 92
    }

    $sum = Read-PassSummarySafe
    $statusLabel.Text = if ($sum) { "Last sync {0} - {1} change(s), {2} conflict(s)" -f $sum.When, $sum.Applied, $sum.Conflicts }
                        else      { "{0} folder pair(s) linked" -f $links.Count }
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

$btnAdd.Add_Click({
    if ((Show-AddDialog -Owner $form) -eq [System.Windows.Forms.DialogResult]::OK) { Update-Cards }
})

$btnSync.Add_Click({
    if ($script:Child) { return }
    $btnSync.Enabled = $false; $btnAdd.Enabled = $false
    $statusLabel.Text = 'Syncing...'
    $script:Child = Start-Cli -CliArgs @('run')
    $timer.Start()
})

$btnSettings.Add_Click({
    if ((Show-SettingsDialog -Owner $form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Update-Cards
    }
})

$btnLog.Add_Click({
    $log = Join-Path $root 'driverelay.log'
    if (-not (Test-Path $log)) { $log = Join-Path $root 'syncorch.log' }
    if (Test-Path $log) { Start-Process notepad.exe $log }
    else { [System.Windows.Forms.MessageBox]::Show($form, 'Nothing logged yet.', 'Log', 'OK', 'Information') | Out-Null }
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({ Update-Cards })
[void]$form.ShowDialog()
