# ghostty-win

A Windows terminal built on **libghostty-vt** (Ghostty's terminal core,
`ghostty/` submodule) with our own Win32 window, Direct3D 11 renderer, and
DirectWrite text stack, all in Zig. We do not use Ghostty's app runtime,
renderer, or font code; only the `ghostty-vt` Zig module.

## Build and run

```powershell
. .\env.ps1          # required in every new shell
zig build run        # Debug: console subsystem, D3D11 debug layer, logs on stderr
zig build test
zig build "-Doptimize=ReleaseFast"   # GUI subsystem; quote -D args in PowerShell
```

- Zig 0.16.0 lives in `tools\zig-x86_64-windows-0.16.0` (gitignored; download
  from ziglang.org if missing). `env.ps1` puts it on PATH.
- Target defaults to `x86_64-windows-msvc`. `env.ps1` sets `VCToolsInstallDir`
  via vswhere. Without it, Zig's clang detects legacy VS 2012/2013/2015
  registrations on this machine, runs in MSVC 2013 compatibility mode
  (`-fms-compatibility-version=18.0`) against modern STL headers, and
  libghostty-vt's C++ deps (simdutf, highway) fail with `char16_t`
  undeclared. Do not "fix" this by removing the machine's old VS installs.
- Clone with `--recursive` (or `git submodule update --init`).
- We ship our own ConPTY (`Microsoft.Windows.Console.ConPTY`, version and
  SHA-256 pinned in `build.zig`). The build runs `scripts\fetch-conpty.ps1`
  when `tools\conpty-<ver>\` is missing, then installs `conpty.dll` and
  `x64\OpenConsole.exe` next to the exe. `zig fetch` can't unpack `.nupkg`.
- `zig build run -- pwsh -NoLogo` runs that command; with no args the shell
  is `%COMSPEC%`.

## Verifying changes

- `.\scripts\smoke.ps1 -Out <dir>` launches the built exe, screenshots it at
  900x600 and 1300x800, closes it with WM_CLOSE, and prints the exit code and
  log. Read the PNGs to check rendering. Use it after renderer/font changes.
- The display is 175% scale (DPI 168): Cascadia Code 12pt is a 16x33 px cell.
- The D3D11 debug layer reports through OutputDebugString, not stderr.
- To script input, post WM_KEYDOWN/WM_CHAR to our HWND (find it by PID) and
  capture with `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)`. Never use
  SendKeys/SendInput: focus-steal prevention sends the keys to whatever
  window the user has focused. Posted keys can't carry modifier state.

## Layout

```
src/main.zig            entry, message loop, std_options log levels, shell command line
src/Window.zig          HWND + owns Terminal, stream, RenderState, font Grid, renderer,
                        Pty, reader thread; SRW lock guards terminal/stream
src/Pty.zig             pipes + pseudoconsole + child process in a kill-on-close job
src/input.zig           Win32 key messages -> libghostty-vt KeyEvent (scancode table)
src/renderer/cells.zig  RenderState -> per-cell bg colors + instanced quads (API agnostic)
src/renderer/D3D11.zig  swap chain, pipeline, buffer/atlas upload, draw
src/renderer/shaders.hlsl  compiled at runtime with d3dcompiler_47
src/font/Grid.zig       faces (primary styles + fallback), metrics, glyph cache, atlas
src/font/Shaper.zig     DirectWrite shaping of runs -> glyphs assigned to cells
src/font/analysis.zig   our COM implementations of IDWriteTextAnalysisSource/Sink
src/font/Atlas.zig      grayscale shelf-packed atlas (CPU side)
src/font/Face.zig       one IDWriteFontFace
src/win32/*.zig         hand-written bindings (conpty.zig loads our conpty.dll at runtime)
```

## Conventions

- **Win32/COM bindings are hand-written**, only for what we call. COM methods
  are called by vtable slot: `com.call(self, slot, fn (args) Ret, .{...})`.
  Take slot numbers from the C vtable structs in Zig's bundled mingw headers
  (`tools/zig-.../lib/libc/include/any-windows-any/*.h`); inherited methods
  count, starting with IUnknown's 3. A wrong slot silently calls the wrong
  method. Interfaces we implement (callbacks) get typed VTable structs.
- **Text pipeline**: cells are grouped into runs (same face, no empty cells,
  cursor cell alone), shaped with DirectWrite, and glyphs are placed at the
  cell where their cluster starts. Glyphs are cached by (FaceId, glyph index),
  never by codepoint. Shaping never moves text off the cell grid.
- libghostty-vt decides cell widths and grapheme clustering (mode 2027 is
  enabled in `Window.zig`); the renderer only decides what to draw in cells.
- **Threads**: the reader thread parses output with the terminal locked, and
  stream effects (`write_pty`, ...) run there. Never call anything that waits
  on the UI thread (SendMessage, SetWindowTextW) from it; PostMessage instead.
- Match the existing comment density; doc comments on files and public decls.
- Commits: one-line conventional commits with an `Assisted-by:` trailer.
  Only commit when asked.
