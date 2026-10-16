# Smoke test: launch the app, screenshot it at two sizes, close it via
# WM_CLOSE, and print its exit code and log.
#
#   .\scripts\smoke.ps1 -Out <dir> [-Exe zig-out\bin\ghostty-win.exe]
#
# Writes <Out>\shot1.png (900x600), <Out>\shot2.png (1300x800) and
# <Out>\stderr.txt. Resizing exercises swap chain resize and terminal reflow.
#
# Only touches the window of the process it started (matched by PID), so
# other ghostty-win windows that are open are left alone. Captures with
# PrintWindow, which works even when the window is covered.
param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghostty-win.exe'),
    [Parameter(Mandatory)][string]$Out
)

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class SmokeUser32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int c, uint f);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern IntPtr PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr FindForPid(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
      if (p == pid && sb.ToString() == "ghostty-win") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
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
    $dc = $g.GetHdc()
    [SmokeUser32]::PrintWindow($h, $dc, 2) | Out-Null # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($dc)
    $bmp.Save($path)
    $g.Dispose(); $bmp.Dispose()
    "$path  $($r.R - $r.L)x$($r.B - $r.T)"
}

New-Item -ItemType Directory -Force $Out | Out-Null
$p = Start-Process $Exe -PassThru -RedirectStandardError "$Out\stderr.txt" -WindowStyle Normal
$null = $p.Handle # keeps ExitCode available after exit

# In console-subsystem builds MainWindowHandle is the console host, not
# our window, so look for our window class owned by this PID.
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 50 -and $h -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 100
    $h = [SmokeUser32]::FindForPid([uint32]$p.Id)
}
if ($h -eq [IntPtr]::Zero) { "no window for pid $($p.Id)"; $p.Kill(); exit 1 }
"hwnd=$h pid=$($p.Id)"

[SmokeUser32]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 900, 600, 0x14) | Out-Null # NOZORDER|NOACTIVATE
Start-Sleep -Milliseconds 600
Shot $h "$Out\shot1.png"

[SmokeUser32]::SetWindowPos($h, [IntPtr]::Zero, 100, 100, 1300, 800, 0x14) | Out-Null
Start-Sleep -Milliseconds 600
Shot $h "$Out\shot2.png"

[SmokeUser32]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null # WM_CLOSE
if ($p.WaitForExit(5000)) { "exited code=$($p.ExitCode)" } else { "did not exit"; $p.Kill() }
"--- stderr"
Get-Content "$Out\stderr.txt"
