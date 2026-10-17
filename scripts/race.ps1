# Run the Go tests under the race detector with zig cc. Dot-source
# setup-msvc.ps1 first, and build the libs with build-vt-lib.ps1.
#
#   .\scripts\race.ps1 [packages...]     (default ./...)
#
# lld turns on ASLR by default, and ThreadSanitizer's fixed shadow
# mapping then fails to allocate, so the tests link with
# --no-dynamicbase. libsynchronization.a, which the race runtime links,
# comes from build-vt-lib.ps1.
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$lib = Join-Path $root 'internal\vt\lib\windows_amd64'
if (-not (Test-Path (Join-Path $lib 'libsynchronization.a'))) {
    throw "no $lib\libsynchronization.a; run scripts\build-vt-lib.ps1"
}
[string[]]$pkgs = if ($args.Count -gt 0) { $args } else { './...' }
$env:CGO_LDFLAGS = "-L$($lib -replace '\\', '/')"
Push-Location $root
try {
    go test -race '-ldflags=-extldflags=-Wl,--no-dynamicbase' @pkgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
    Remove-Item Env:CGO_LDFLAGS
}
