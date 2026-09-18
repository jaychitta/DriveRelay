<#
    LogViewer.ps1 -- a read-only log window shared by the tray and dashboard.

    The on-disk log deliberately remains chronological: appending is safe when
    the tray, dashboard and sync child happen to write at the same time.  This
    viewer moves its caret to the end after loading so the newest event is the
    first thing a person sees.
#>

function Get-DriveRelayLogPath {
    param([Parameter(Mandatory)][string] $Root)

    $current = Join-Path $Root 'driverelay.log'
    if (Test-Path -LiteralPath $current) { return $current }

    # Keep this migration fallback in one place. It can be removed when old
    # SyncOrchestrator installs are no longer supported.
    $legacy = Join-Path $Root 'syncorch.log'
    if (Test-Path -LiteralPath $legacy) { return $legacy }

    return $current
}

function Show-DriveRelayLog {
    param(
        [Parameter(Mandatory)][string] $Root,
        [object] $Owner,
        [System.Drawing.Icon] $Icon
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DriveRelay log'
    $form.Size = New-Object System.Drawing.Size -ArgumentList 920, 620
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 620, 420
    $form.StartPosition = if ($Owner) { 'CenterParent' } else { 'CenterScreen' }
    if ($Icon) { $form.Icon = $Icon }

    $heading = New-Object System.Windows.Forms.Label
    $heading.Dock = 'Top'
    $heading.Height = 30
    $heading.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 10, 7, 10, 0
    $heading.Text = 'Newest entries are shown below.'
    $form.Controls.Add($heading)

    $actions = New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Bottom'
    $actions.Height = 42
    $actions.FlowDirection = 'RightToLeft'
    $actions.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 8, 6, 8, 6
    $form.Controls.Add($actions)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.AutoSize = $true
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $actions.Controls.Add($close)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Refresh'
    $refresh.AutoSize = $true
    $actions.Controls.Add($refresh)

    $viewer = New-Object System.Windows.Forms.TextBox
    $viewer.Dock = 'Fill'
    $viewer.Multiline = $true
    $viewer.ReadOnly = $true
    $viewer.ScrollBars = 'Both'
    $viewer.WordWrap = $false
    $viewer.Font = New-Object System.Drawing.Font -ArgumentList 'Consolas', 9
    $form.Controls.Add($viewer)

    $load = {
        $path = Get-DriveRelayLogPath -Root $Root
        try {
            if (Test-Path -LiteralPath $path) {
                $heading.Text = "Newest entries -- $path"
                $viewer.Text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            }
            else {
                $heading.Text = 'No log has been written yet.'
                $viewer.Text = ''
            }
        }
        catch {
            $heading.Text = 'Could not read the log.'
            $viewer.Text = $_.Exception.Message
        }

        # TextBox opens at the start by default. Placing the selection at the
        # end makes the newest log entry visible without altering the file.
        $viewer.SelectionStart = $viewer.TextLength
        $viewer.SelectionLength = 0
        $viewer.ScrollToCaret()
    }.GetNewClosure()

    $refresh.Add_Click($load)
    $form.Add_Shown($load)
    $form.CancelButton = $close

    if ($Owner) { $null = $form.ShowDialog($Owner) }
    else        { $null = $form.ShowDialog() }
    $form.Dispose()
}
