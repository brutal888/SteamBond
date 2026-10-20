# Draws SteamBond.ico (16/24/32/48/64/256): two network lines merging into one download arrow.
Add-Type -AssemblyName System.Drawing
$Out = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'SteamBond.ico'

function New-Frame([int]$S) {
    $bmp = New-Object Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $k = $S / 256.0

    # Rounded square background, blue -> teal
    $r = 56 * $k; $pad = 8 * $k; $w = $S - 2 * $pad
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($pad, $pad, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($pad + $w - 2 * $r, $pad, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($pad + $w - 2 * $r, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($pad, $pad + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $bg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF(0, 0)), (New-Object Drawing.PointF($S, $S)), [Drawing.Color]::FromArgb(23, 26, 33), [Drawing.Color]::FromArgb(27, 40, 56))
    $g.FillPath($bg, $path)

    # Two incoming lines (Wi-Fi = cyan, Ethernet = green) merging at the centre
    $lw = [single][math]::Max(28 * $k, 2.2)
    $cyan  = New-Object Drawing.Pen([Drawing.Color]::FromArgb(102, 192, 244), $lw); $cyan.StartCap = 'Round'; $cyan.EndCap = 'Round'
    $green = New-Object Drawing.Pen([Drawing.Color]::FromArgb(91, 214, 120), $lw);  $green.StartCap = 'Round'; $green.EndCap = 'Round'
    $g.DrawBezier($cyan,  [single](64 * $k), [single](58 * $k), [single](64 * $k), [single](110 * $k), [single](128 * $k), [single](100 * $k), [single](128 * $k), [single](140 * $k))
    $g.DrawBezier($green, [single](192 * $k), [single](58 * $k), [single](192 * $k), [single](110 * $k), [single](128 * $k), [single](100 * $k), [single](128 * $k), [single](140 * $k))

    # Merged white arrow pointing down
    $white = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $g.FillRectangle($white, [single](128 * $k - $lw / 2), [single](132 * $k), $lw, [single](40 * $k))
    $pts = @(
        (New-Object Drawing.PointF([single](76 * $k), [single](160 * $k))),
        (New-Object Drawing.PointF([single](180 * $k), [single](160 * $k))),
        (New-Object Drawing.PointF([single](128 * $k), [single](214 * $k)))
    )
    $g.FillPolygon($white, $pts)
    $g.Dispose()
    $bmp
}

# Classic 32-bit DIB frames for the small sizes (WinForms can only read those), PNG for 256.
function Get-Dib($bmp) {
    $s = $bmp.Width
    $rect = New-Object Drawing.Rectangle(0, 0, $s, $s)
    $data = $bmp.LockBits($rect, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($s * $s * 4)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
    $bmp.UnlockBits($data)
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $maskRow = [int]([math]::Ceiling($s / 32.0) * 4)
    $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($s * $s * 4 + $maskRow * $s)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($px, $y * $s * 4, $s * 4) }   # bottom-up rows, BGRA
    $w.Write((New-Object byte[] ($maskRow * $s)))                                # AND mask (alpha does the work)
    $w.Flush(); , $ms.ToArray()   # leading comma keeps the byte[] from being unrolled
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = foreach ($s in $sizes) {
    $b = New-Frame $s
    if ($s -ge 256) { $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bytes = $ms.ToArray() }
    else { $bytes = Get-Dib $b }
    $b.Dispose(); , $bytes
}
$fs = [IO.File]::Create($Out); $bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
"Wrote $Out"
