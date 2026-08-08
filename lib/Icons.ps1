<#
    Icons.ps1  --  the artwork, drawn in code.

    No image files ship with this project, so the icon is drawn with GDI+.
    Two consumers share this one implementation:

      * the tray, which builds icons in memory at runtime
      * tools\New-Icons.ps1, which writes .ico files for shortcuts

    Why the tray does not simply load the .ico: System.Drawing.Icon cannot
    decode PNG-compressed frames inside an ICO. Explorer and the shell handle
    them perfectly, but System.Drawing reads the PNG bytes as though they were
    a device-independent bitmap and produces garbage. Building the icon from a
    Bitmap avoids that decoder entirely.

    States: idle (plain), sync (green pip), warn (amber pip).
#>

Add-Type -AssemblyName System.Drawing

function New-SyncIconBitmap {
    param(
        [int] $Size = 32,
        [ValidateSet('idle','sync','warn')][string] $State = 'idle'
    )

    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $Size, $Size,
             ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Check for pre-rendered master badge image
    $root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
    $assetCandidates = @(
        (Join-Path $root 'assets\DriveRelay_badge.png'),
        (Join-Path $root 'assets\DriveRelay.png'),
        (Join-Path $root 'DriveRelay.png')
    )
    $badgePath = $assetCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    $drawn = $false
    if ($badgePath) {
        try {
            $master = [System.Drawing.Image]::FromFile($badgePath)
            $pad = [Math]::Max(0, [int]($Size * 0.04))
            $destRect = New-Object System.Drawing.Rectangle -ArgumentList $pad, $pad, ($Size - 2 * $pad), ($Size - 2 * $pad)
            $g.DrawImage($master, $destRect)
            $master.Dispose()
            $drawn = $true
        } catch {
            $drawn = $false
        }
    }

    if (-not $drawn) {
        $pad    = [Math]::Max(1, [int]($Size * 0.06))
        $side   = $Size - (2 * $pad)
        $radius = [Math]::Max(2, [int]($Size * 0.22))

        # Rounded square body.
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d    = $radius * 2
        $path.AddArc($pad, $pad, $d, $d, 180, 90)
        $path.AddArc($pad + $side - $d, $pad, $d, $d, 270, 90)
        $path.AddArc($pad + $side - $d, $pad + $side - $d, $d, $d, 0, 90)
        $path.AddArc($pad, $pad + $side - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $gp1 = New-Object System.Drawing.Point -ArgumentList $pad, $pad
        $gp2 = New-Object System.Drawing.Point -ArgumentList ($pad + $side), ($pad + $side)
        $gc1 = [System.Drawing.Color]::FromArgb(255, 38, 132, 226)
        $gc2 = [System.Drawing.Color]::FromArgb(255, 14,  74, 152)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $gp1, $gp2, $gc1, $gc2
        $g.FillPath($brush, $path)

        $penWidth = [Math]::Max(1.2, $Size * 0.09)
        $pen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::White), $penWidth
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'

        $cx = $Size / 2.0; $cy = $Size / 2.0
        $r  = $Size * 0.25
        $box = New-Object System.Drawing.RectangleF -ArgumentList ($cx - $r), ($cy - $r), (2 * $r), (2 * $r)
        $g.DrawArc($pen, $box, 40, 140)
        $g.DrawArc($pen, $box, 220, 140)

        if ($Size -ge 24) {
            $h = $Size * 0.14
            $ax = $cx + ($r * 0.77); $ay = $cy + ($r * 0.64)
            $g.FillPolygon([System.Drawing.Brushes]::White, @(
                (New-Object System.Drawing.PointF -ArgumentList ($ax + $h), ($ay + ($h * 0.15))),
                (New-Object System.Drawing.PointF -ArgumentList ($ax - ($h * 0.25)), ($ay + ($h * 0.85))),
                (New-Object System.Drawing.PointF -ArgumentList ($ax - ($h * 0.1)), ($ay - ($h * 0.7)))
            ))
            $bx = $cx - ($r * 0.77); $by = $cy - ($r * 0.64)
            $g.FillPolygon([System.Drawing.Brushes]::White, @(
                (New-Object System.Drawing.PointF -ArgumentList ($bx - $h), ($by - ($h * 0.15))),
                (New-Object System.Drawing.PointF -ArgumentList ($bx + ($h * 0.25)), ($by - ($h * 0.85))),
                (New-Object System.Drawing.PointF -ArgumentList ($bx + ($h * 0.1)), ($by + ($h * 0.7)))
            ))
        }
        $pen.Dispose(); $brush.Dispose(); $path.Dispose()
    }

    # State pip, bottom right, with a light ring so it reads on any wallpaper.
    if ($State -ne 'idle') {
        $pipColour = if ($State -eq 'sync') { [System.Drawing.Color]::FromArgb(255, 42, 187, 88) }
                     else                   { [System.Drawing.Color]::FromArgb(255, 240, 168, 20) }
        $pr = $Size * 0.34
        $px = $Size - $pr - ($Size * 0.03)
        $py = $Size - $pr - ($Size * 0.03)
        $ringBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::White)
        $g.FillEllipse($ringBrush, ($px - ($Size * 0.035)), ($py - ($Size * 0.035)),
                                   ($pr + ($Size * 0.07)),  ($pr + ($Size * 0.07)))
        $pipBrush = New-Object System.Drawing.SolidBrush -ArgumentList $pipColour
        $g.FillEllipse($pipBrush, $px, $py, $pr, $pr)
        $pipBrush.Dispose(); $ringBrush.Dispose()
    }

    $g.Dispose()
    return $bmp
}

function New-SyncIcon {
    <#
        A live Icon for the tray, built from a Bitmap rather than parsed from a
        file. GetHicon allocates an unmanaged handle, so the caller keeps these
        for the life of the process rather than creating them per update.
    #>
    param(
        [int] $Size = 32,
        [ValidateSet('idle','sync','warn')][string] $State = 'idle'
    )

    $bmp    = New-SyncIconBitmap -Size $Size -State $State
    $handle = $bmp.GetHicon()
    $icon   = [System.Drawing.Icon]::FromHandle($handle)
    $bmp.Dispose()
    return $icon
}
