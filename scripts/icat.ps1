# Show an image in the terminal with the kitty graphics protocol, like
# `kitten icat`, which has no Windows build.
#
#   .\scripts\icat.ps1 <image> [-Cols N] [-Rows N]
#
# PNGs are sent as is; other formats System.Drawing can read (JPEG, GIF,
# BMP, TIFF) are converted to PNG first. -Cols/-Rows scale the image to
# that many cells (one alone keeps the aspect ratio).
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Cols = 0,
    [int]$Rows = 0
)

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
$png = $bytes.Length -ge 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47
if (-not $png) {
    Add-Type -AssemblyName System.Drawing
    $in = New-Object IO.MemoryStream (, $bytes)
    $img = [Drawing.Image]::FromStream($in)
    $out = New-Object IO.MemoryStream
    $img.Save($out, [Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()
    $bytes = $out.ToArray()
}
$b64 = [Convert]::ToBase64String($bytes)

# q=2 keeps the terminal's replies out of the shell's input.
$ctl = "a=T,f=100,q=2"
if ($Cols -gt 0) { $ctl += ",c=$Cols" }
if ($Rows -gt 0) { $ctl += ",r=$Rows" }

$esc = [char]27
$w = [Console]::Out
$chunk = 4096
for ($o = 0; $o -lt $b64.Length; $o += $chunk) {
    $part = $b64.Substring($o, [Math]::Min($chunk, $b64.Length - $o))
    $more = if ($o + $chunk -lt $b64.Length) { 1 } else { 0 }
    $keys = if ($o -eq 0) { "$ctl,m=$more" } else { "q=2,m=$more" }
    $w.Write("${esc}_G${keys};${part}${esc}\")
}
$w.Write("`r`n")
$w.Flush()
