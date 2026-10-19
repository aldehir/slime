# slime

A Windows terminal on **libghostty-vt** (`ghostty/` submodule). The
terminals run in the daemon, **slime** (`slime.exe`: `cmd/slime`, Go
module at the root, libghostty-vt through cgo), locally or on SSH hosts,
which the daemon logs in to (`internal/sshbridge`). The window,
**slime-gui** (`slime-gui.exe`: `clients/gui`, Zig: Win32, Direct3D 11,
DirectWrite) draws the frames slime sends (`internal/vt/frame.zig`) and
sends input back as events (`event.zig`). Plans live in `.plans/` (untracked);
`rearchitect-plan.md` is the current one.

## Build

```powershell
. .\scripts\setup-msvc.ps1   # once per shell: project Zig on PATH, modern MSVC
zig build run                # Debug build; logs on stderr
zig build test
```

- Zig 0.16.0 lives in `tools\` (gitignored; download from ziglang.org).
- slime links libghostty-vt with cgo, compiled by `zig cc` (the setup
  script sets `CC`); no other C toolchain. `zig build` builds the static
  libs into `internal\vt\lib`; for `go test` alone, run
  `scripts\build-vt-lib.ps1` once. `scripts\race.ps1` runs `-race`.
- A test build attaches to the daemon already running (one pipe per user,
  `\\.\pipe\slime-<sid>`). Set `SLIME_INSTANCE=<name>` so it starts its
  own, and stop that one by PID when done.
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
- The CLI is its own manual: `slime help` prints every command and the
  topics (env, ids, lua, methods, events). Each topic's text lives beside
  the code it describes (`daemon.EnvDoc`, `rpc.IDsDoc`, `lua.Doc`,
  `rpc.MethodDocs`); a new command, method, variable, or Lua function
  gets its line there, not in a separate doc. `skills/slime/SKILL.md`
  is the agent skill `slime skill install` ships; it points at the manual.
- Commits: one line, `module: description` (e.g. `renderer: ...`,
  `input: ...`), only when asked.
