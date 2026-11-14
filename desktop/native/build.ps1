param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$gcc = 'D:\Compilation_dependencies\msys64\mingw64\bin\g++.exe'
if (-not (Test-Path $gcc)) { throw "MinGW g++ not found: $gcc" }
$source = Join-Path $PSScriptRoot 'UnlockPortable.cpp'
$outputDir = Join-Path $PSScriptRoot 'release'
$output = if ($OutputPath) { $OutputPath } else { Join-Path $outputDir 'UnlockPortable-Native.exe' }
$icon = Join-Path $PSScriptRoot 'unlock-icon.ico'
$resource = Join-Path $env:TEMP 'UnlockPortable-Native-icon.o'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
Add-Type -AssemblyName System.Drawing
function New-RoundedPath([single]$x, [single]$y, [single]$width, [single]$height, [single]$radius) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $radius * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $width - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $width - $d, $y + $height - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}
$frames = [System.Collections.Generic.List[byte[]]]::new()
foreach ($size in @(16, 32, 48, 256)) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $scale = $size / 64.0
    $graphics.ScaleTransform([single]$scale, [single]$scale)
    $tile = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(8, 127, 120))
    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $teal = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(8, 127, 120), 6)
    $tilePath = New-RoundedPath 2 2 60 60 13
    $bodyPath = New-RoundedPath 15 29 34 27 5
    $graphics.FillPath($tile, $tilePath)
    $graphics.FillPath($white, $bodyPath)
    $graphics.DrawArc($teal, 20, 9, 24, 31, 180, 180)
    $checkPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(8, 127, 120), 4)
    $graphics.DrawLine($checkPen, 31, 41, 35, 45)
    $graphics.DrawLine($checkPen, 35, 45, 43, 36)
    $ms = [System.IO.MemoryStream]::new()
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames.Add($ms.ToArray())
    $ms.Dispose(); $tile.Dispose(); $white.Dispose(); $teal.Dispose(); $checkPen.Dispose(); $tilePath.Dispose(); $bodyPath.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$iconStream = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($iconStream)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
for ($i = 0; $i -lt $frames.Count; $i++) {
    $dim = @(16, 32, 48, 256)[$i]
    $writer.Write([byte]$(if ($dim -eq 256) { 0 } else { $dim }))
    $writer.Write([byte]$(if ($dim -eq 256) { 0 } else { $dim }))
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($frame in $frames) { $writer.Write($frame) }
[System.IO.File]::WriteAllBytes($icon, $iconStream.ToArray())
$writer.Dispose(); $iconStream.Dispose()
$windres = Join-Path (Split-Path $gcc) 'windres.exe'
$rc = Join-Path $env:TEMP 'UnlockPortable-Native-icon.rc'
'101 ICON "{0}"' -f $icon.Replace('\', '/') | Set-Content -Path $rc -Encoding Ascii
& $windres "--input=$rc" "--output=$resource" --input-format=rc --output-format=coff --codepage=65001
if ($LASTEXITCODE -ne 0) { throw 'Icon resource compilation failed.' }
& $gcc $source $resource -o $output -std=c++17 -O2 -s -static -static-libgcc -static-libstdc++ -municode -mwindows -lcomctl32 -lcomdlg32 -lshell32 -lole32 -lbcrypt -luuid
if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
Get-Item $output | Select-Object FullName, Length, LastWriteTime
