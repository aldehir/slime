# Download the Microsoft.Windows.Console.ConPTY NuGet package and extract
# the x64 conpty.dll and OpenConsole.exe. build.zig runs this when the
# files are missing; the version and hash are pinned there.
#
#   .\scripts\fetch-conpty.ps1 -Version <ver> -Sha256 <hash> -Out <dir>
#
# Uses .NET directly rather than Get-FileHash/Expand-Archive: when
# Windows PowerShell is started from pwsh it inherits pwsh's PSModulePath
# and can't autoload those cmdlets.
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$id = 'microsoft.windows.console.conpty'
$url = "https://api.nuget.org/v3-flatcontainer/$id/$Version/$id.$Version.nupkg"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghostty-win-conpty-$Version"
$zip = "$tmp.zip"

Write-Host "fetching $url"
(New-Object Net.WebClient).DownloadFile($url, $zip)
$sha = [Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($zip)
$actual = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
$stream.Dispose()
if ($actual -ne $Sha256) {
    Remove-Item $zip
    throw "conpty package hash mismatch: expected $Sha256, got $actual"
}

if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item (Join-Path $tmp 'runtimes\win-x64\native\conpty.dll') $Out
Copy-Item (Join-Path $tmp 'build\native\runtimes\x64\OpenConsole.exe') $Out
Remove-Item -Recurse -Force $tmp, $zip
