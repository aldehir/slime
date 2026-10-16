# Smoke test: launch the app, screenshot it at two sizes, close it via
# WM_CLOSE, and print its exit code and log.
#
#   .\scripts\smoke.ps1 -Out <dir> [-Exe zig-out\bin\ghostty-win.exe]
#
# Writes <Out>\shot1.png (900x600), <Out>\shot2.png (1300x800) and
# <Out>\stderr.txt. Resizing exercises swap chain resize and terminal reflow.
param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghostty-win.exe'),
    [Parameter(Mandatory)][string]$Out
)

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class SmokeUser32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int c, uint f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@

# Without per-monitor DPI awareness, window coordinates are virtualized
# and the screenshots come out offset and scaled.
[SmokeUser32]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

function Shot($h, $path) {
    $r = New-Object SmokeUser32+RECT
    [SmokeUser32]::GetWindowRect($h, [ref]$r) | Out-Null
    $bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $bmp.Save($path)
    $g.Dispose(); $bmp.Dispose()
    "$path  $($r.R - $r.L)x$($r.B - $r.T)"
}

New-Item -ItemType Directory -Force $Out | Out-Null
$p = Start-Process $Exe -PassThru -RedirectStandardError "$Out\stderr.txt" -WindowStyle Normal

# Find our window by class. In console-subsystem builds MainWindowHandle
# is the console host, not our window. [NullString] because PowerShell
# would otherwise pass "" as the title.
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 50 -and $h -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 100
    $h = [SmokeUser32]::FindWindowW("ghostty-win", [NullString]::Value)
}
"hwnd=$h"

[SmokeUser32]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 900, 600, 0x4) | Out-Null
[SmokeUser32]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 600
Shot $h "$Out\shot1.png"

[SmokeUser32]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 1300, 800, 0x4) | Out-Null
Start-Sleep -Milliseconds 600
Shot $h "$Out\shot2.png"

[SmokeUser32]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null # WM_CLOSE
if ($p.WaitForExit(5000)) { "exited code=$($p.ExitCode)" } else { "did not exit"; $p.Kill() }
"--- stderr"
Get-Content "$Out\stderr.txt"
