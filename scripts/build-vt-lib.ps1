# Build libghostty-vt as static libraries for slime, which links them
# with cgo (internal/vt), one per target, into internal\vt\lib.
# internal\vt\slime.zig is compiled in for slime's own exports.
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
# slime's own exports, compiled in next to the C API.
$extra = Join-Path $root 'internal\vt\slime.zig'
$libs = @()
Push-Location (Join-Path $root 'ghostty')
try {
    foreach ($t in $targets) {
        $prefix = Join-Path $root "zig-out-vt\$($t.Zig)"
        zig build -Demit-lib-vt "-Dtarget=$($t.Zig)" "-Doptimize=$Optimize" "-Dvt-extra=$extra" --prefix $prefix
        if ($LASTEXITCODE -ne 0) { throw "zig build for $($t.Zig) failed ($LASTEXITCODE)" }
        $dir = Join-Path $root "internal\vt\lib\$($t.Go)"
        New-Item -ItemType Directory -Force $dir | Out-Null
        # Named as an archive on both, for cgo's -l (its flag check
        # rejects a .lib path).
        Copy-Item (Join-Path $prefix "lib\$($t.Lib)") (Join-Path $dir 'libghostty-vt.a')
        $libs += Join-Path $prefix "lib\$($t.Lib)"
        Write-Host "internal\vt\lib\$($t.Go)\libghostty-vt.a ($Optimize)"
    }
} finally {
    Pop-Location
}

# A Go file with the libraries' hash, so go build and go test relink
# when they change (cgo doesn't track a static library's bytes); as
# build.zig writes it with build/libstamp.zig.
$stamp = Join-Path $root 'internal\vt\zz_libstamp.go'
zig run (Join-Path $root 'build\libstamp.zig') -- $stamp @libs
if ($LASTEXITCODE -ne 0) { throw "libstamp failed ($LASTEXITCODE)" }

# Go's race runtime links -lsynchronization, which Zig's MinGW has no
# import library for. scripts\race.ps1 points cgo here.
$def = Join-Path $root 'zig-out-vt\synchronization.def'
Set-Content $def "LIBRARY api-ms-win-core-synch-l1-2-0.dll`nEXPORTS`nWaitOnAddress`nWakeByAddressSingle`nWakeByAddressAll"
zig dlltool -d $def -l (Join-Path $root 'internal\vt\lib\windows_amd64\libsynchronization.a') -m i386:x86-64
if ($LASTEXITCODE -ne 0) { throw "zig dlltool failed ($LASTEXITCODE)" }
