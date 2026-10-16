# slime

A Windows terminal on **libghostty-vt** (`ghostty/` submodule) with our own
Win32 window, Direct3D 11 renderer, and DirectWrite text stack, in Zig.

## Build

```powershell
. .\scripts\setup-msvc.ps1   # once per shell: project Zig on PATH, modern MSVC
zig build run                # Debug build; logs on stderr
zig build test
```

- Zig 0.16.0 lives in `tools\` (gitignored; download from ziglang.org).
- Without the setup script, clang picks a legacy MSVC and the C++ deps fail
  with `char16_t` undeclared. Don't remove the machine's old VS installs.

## Rules

- `ghostty/` tracks Alde's fork (`aldehir/ghostty`). **Never** open PRs,
  push, comment, or file issues on upstream ghostty-org/ghostty.
- Alde may be running slime while you work. Only touch processes you
  started, matched by PID. Never use SendKeys/SendInput; post messages to
  your own HWND. `scripts\smoke.ps1 -Out <dir>` launches and screenshots
  safely.
- Win32/COM bindings are hand-written; take vtable slots from Zig's bundled
  mingw headers (inherited methods count, IUnknown is 3).
- The reader thread must never call anything that waits on the UI thread
  (SendMessage, SetWindowTextW); use PostMessage.
- Check `deferred.md` before building adjacent features; keep it current.
- Commits: one line, `module: description` (e.g. `renderer: ...`,
  `input: ...`), only when asked.
