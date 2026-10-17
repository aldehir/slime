# Build libghostty-vt as static libraries for slimed (ssh/internal/vt
# links them with cgo), one per target, into ssh\internal\vt\lib.
# Dot-source setup-msvc.ps1 first so the project Zig is on PATH.
#
#   .\scripts\build-vt-lib.ps1 [-Optimize ReleaseFast|ReleaseSmall]
param(
    [ValidateSet('ReleaseFast', 'ReleaseSmall', 'ReleaseSafe', 'Debug')]
    [string]$Optimize = 'ReleaseFast'
)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$targets = @(
    @{ Zig = 'x86_64-windows-gnu'; Go = 'windows_amd64'; Lib = 'ghostty-vt-static.lib' }
    @{ Zig = 'x86_64-linux-musl'; Go = 'linux_amd64'; Lib = 'libghostty-vt.a' }
)
Push-Location (Join-Path $root 'ghostty')
try {
    foreach ($t in $targets) {
        $prefix = Join-Path $root "zig-out-vt\$($t.Zig)"
        zig build -Demit-lib-vt "-Dtarget=$($t.Zig)" "-Doptimize=$Optimize" --prefix $prefix
        if ($LASTEXITCODE -ne 0) { throw "zig build for $($t.Zig) failed ($LASTEXITCODE)" }
        $dir = Join-Path $root "ssh\internal\vt\lib\$($t.Go)"
        New-Item -ItemType Directory -Force $dir | Out-Null
        # Named as an archive on both, for cgo's -l (its flag check
        # rejects a .lib path).
        Copy-Item (Join-Path $prefix "lib\$($t.Lib)") (Join-Path $dir 'libghostty-vt.a')
        Write-Host "ssh\internal\vt\lib\$($t.Go)\libghostty-vt.a ($Optimize)"
    }
} finally {
    Pop-Location
}

# Go's race runtime links -lsynchronization, which Zig's MinGW has no
# import library for. scripts\race.ps1 points cgo here.
$def = Join-Path $root 'zig-out-vt\synchronization.def'
Set-Content $def "LIBRARY api-ms-win-core-synch-l1-2-0.dll`nEXPORTS`nWaitOnAddress`nWakeByAddressSingle`nWakeByAddressAll"
zig dlltool -d $def -l (Join-Path $root 'ssh\internal\vt\lib\windows_amd64\libsynchronization.a') -m i386:x86-64
if ($LASTEXITCODE -ne 0) { throw "zig dlltool failed ($LASTEXITCODE)" }
