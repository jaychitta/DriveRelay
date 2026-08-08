<#
    New-Icons.ps1  --  write the .ico files used by shortcuts.

    Drawing lives in lib\Icons.ps1 so the tray and these files never drift.

    Frames are written as device-independent bitmaps rather than PNG. PNG
    frames are smaller and the shell reads them happily, but System.Drawing
    cannot decode them -- so a PNG-framed .ico looks right in Explorer and like
    noise anywhere managed code touches it. DIB frames work in both.

    Run once at install time.
#>

[CmdletBinding()]
param([string] $OutDir)

$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'assets' }

. (Join-Path $root 'lib\Icons.ps1')

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function ConvertTo-IcoFrame {
    <#
        BITMAPINFOHEADER + 32bpp BGRA rows (bottom-up) + an AND mask.

        The header records double the real height: the format expects the XOR
        image and the AND mask stacked. The mask is all zeroes because the
        alpha channel already carries transparency, but it must still be
        present and padded to a 4-byte row stride.
    #>
    param([Parameter(Mandatory)][System.Drawing.Bitmap] $Bitmap)

    $w = $Bitmap.Width; $h = $Bitmap.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    $bw.Write([uint32]40)          # header size
    $bw.Write([int32]$w)
    $bw.Write([int32]($h * 2))     # XOR + AND
    $bw.Write([uint16]1)           # planes
    $bw.Write([uint16]32)          # bpp
    $bw.Write([uint32]0)           # BI_RGB
    $bw.Write([uint32]($w * $h * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)

    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $p = $Bitmap.GetPixel($x, $y)
            $bw.Write([byte]$p.B); $bw.Write([byte]$p.G)
            $bw.Write([byte]$p.R); $bw.Write([byte]$p.A)
        }
    }

    $maskStride = [int](([math]::Floor(($w + 31) / 32)) * 4)
    $blank = New-Object byte[] $maskStride
    for ($y = 0; $y -lt $h; $y++) { $bw.Write($blank) }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()

    # Leading comma: returning a byte[] bare unrolls it into the caller's
    # pipeline, and each frame arrives as a single byte.
    return ,$bytes
}

function Write-IcoFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int[]]  $Sizes,
        [Parameter(Mandatory)][string] $State
    )

    $frames = @()
    foreach ($s in $Sizes) {
        $bmp = New-SyncIconBitmap -Size $s -State $State
        $frames += ,@($s, (ConvertTo-IcoFrame -Bitmap $bmp))
        $bmp.Dispose()
    }

    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)

        $offset = 6 + (16 * $frames.Count)
        foreach ($f in $frames) {
            $size = $f[0]; $data = $f[1]
            $dim  = if ($size -ge 256) { 0 } else { $size }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim)
            $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$data.Length)
            $bw.Write([uint32]$offset)
            $offset += $data.Length
        }
        foreach ($f in $frames) { $bw.Write($f[1]) }
    }
    finally { $bw.Dispose(); $fs.Dispose() }
}

# 256 is left out deliberately: as an uncompressed DIB it costs ~256 KB per
# frame for a shortcut icon nobody views that large.
$sizes = @(16, 20, 24, 32, 48, 64, 128)

Write-IcoFile -Path (Join-Path $OutDir 'driverelay.ico')      -Sizes $sizes -State 'idle'
Write-IcoFile -Path (Join-Path $OutDir 'driverelay-sync.ico') -Sizes $sizes -State 'sync'
Write-IcoFile -Path (Join-Path $OutDir 'driverelay-warn.ico') -Sizes $sizes -State 'warn'

Get-ChildItem $OutDir -Filter *.ico | ForEach-Object {
    '{0,-22} {1,8} bytes' -f $_.Name, $_.Length
}
