# Development environment for slime. Dot-source it:
#
#   . .\scripts\setup-msvc.ps1
#
# Puts the project-local Zig on PATH and points clang at a modern MSVC
# toolset. Zig picks MSVC include paths on its own, but its bundled clang
# detects the MSVC compatibility version separately and, on machines with
# legacy VS registrations (VS1x0COMNTOOLS, SxS\VC7), settles on an ancient
# cl.exe. Modern STL headers then fail to parse (e.g. char16_t is not a
# keyword in MSVC 2013 mode). VCToolsInstallDir takes precedence over that
# legacy discovery.

$zigDir = Join-Path $PSScriptRoot '..\tools\zig-x86_64-windows-0.16.0'
if (-not (Test-Path (Join-Path $zigDir 'zig.exe'))) {
    Write-Error "zig not found at $zigDir"
    return
}
if (($env:PATH -split ';') -notcontains $zigDir) {
    $env:PATH = "$zigDir;$env:PATH"
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) {
    Write-Error 'No Visual Studio install with the MSVC x64 toolset found'
    return
}

$vcVersion = (Get-Content (Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
$env:VCToolsInstallDir = Join-Path $vsPath "VC\Tools\MSVC\$vcVersion\"

# cgo (ssh/internal/vt links libghostty-vt) compiles with Zig's clang, so
# `go build` and `go test` in ssh\ need no other C toolchain. build.zig
# sets its own CC for each host target.
$env:CGO_ENABLED = '1'
$env:CC = 'zig cc -target x86_64-windows-gnu'

Write-Host "zig  $(& zig version)"
Write-Host "msvc $env:VCToolsInstallDir"
