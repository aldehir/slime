# Show an image in the terminal with the kitty graphics protocol, like
# `kitten icat`, which has no Windows build.
#
#   .\scripts\icat.ps1 <image> [-Cols N] [-Rows N]
#   .\scripts\icat.ps1 <image> -Placeholder -Cols N -Rows N [-Id N]
#
# PNGs are sent as is; other formats System.Drawing can read (JPEG, GIF,
# BMP, TIFF) are converted to PNG first. -Cols/-Rows scale the image to
# that many cells (one alone keeps the aspect ratio).
#
# -Placeholder sends the image as a virtual placement and prints Unicode
# placeholder cells (U+10EEEE) where it goes, as `kitten icat` does in
# tmux. The image ID (1-255) goes in the cells' foreground color.
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Cols = 0,
    [int]$Rows = 0,
    [switch]$Placeholder,
    [ValidateRange(1, 255)][int]$Id = 42
)
if ($Placeholder -and ($Cols -le 0 -or $Rows -le 0 -or $Rows -gt 32)) {
    throw "-Placeholder needs -Cols and -Rows (up to 32 rows)"
}

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
if ($Placeholder) { $ctl += ",U=1,i=$Id" }
if ($Cols -gt 0) { $ctl += ",c=$Cols" }
if ($Rows -gt 0) { $ctl += ",r=$Rows" }

$esc = [char]27
# The OEM code page has no U+10EEEE; placeholders would come out as "?".
if ($Placeholder) { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
$w = [Console]::Out
$chunk = 4096
for ($o = 0; $o -lt $b64.Length; $o += $chunk) {
    $part = $b64.Substring($o, [Math]::Min($chunk, $b64.Length - $o))
    $more = if ($o + $chunk -lt $b64.Length) { 1 } else { 0 }
    $keys = if ($o -eq 0) { "$ctl,m=$more" } else { "q=2,m=$more" }
    $w.Write("${esc}_G${keys};${part}${esc}\")
}

if ($Placeholder) {
    # Row diacritics from the kitty spec (rowcolumn-diacritics.txt). The
    # first cell of a row names its row and column 0; the rest continue
    # the run.
    $diacritics = 0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
        0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
        0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
        0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484
    $cell = [char]::ConvertFromUtf32(0x10EEEE)
    $w.Write("${esc}[38;5;${Id}m")
    for ($r = 0; $r -lt $Rows; $r++) {
        $w.Write($cell + [char]$diacritics[$r] + [char]$diacritics[0] + ($cell * ($Cols - 1)))
        $w.Write("`r`n")
    }
    $w.Write("${esc}[39m")
}
$w.Write("`r`n")
$w.Flush()
