# Build libghostty-vt as wasm for slimed (ssh/internal/vt embeds it).
# Dot-source setup-msvc.ps1 first so the project Zig is on PATH.
#
#   .\scripts\build-vt-wasm.ps1 [-Optimize ReleaseSmall|ReleaseFast]
param(
    [ValidateSet('ReleaseSmall', 'ReleaseFast', 'ReleaseSafe', 'Debug')]
    [string]$Optimize = 'ReleaseSmall'
)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$prefix = Join-Path $root 'zig-out-wasm'
Push-Location (Join-Path $root 'ghostty')
try {
    zig build -Demit-lib-vt -Dtarget=wasm32-freestanding "-Doptimize=$Optimize" --prefix $prefix
    if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
Copy-Item (Join-Path $prefix 'bin\ghostty-vt.wasm') (Join-Path $root 'ssh\internal\vt\ghostty-vt.wasm')
Write-Host "ssh\internal\vt\ghostty-vt.wasm ($Optimize)"
