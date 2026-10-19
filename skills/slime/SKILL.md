---
name: slime
description: >-
  Drive slime, the terminal daemon this shell runs in, from the command
  line: split panes, open tabs and workspaces, type into panes, read their
  screens, move and focus them, run Lua in the daemon. Use when asked to
  arrange, read, or control the terminal, open something beside the current
  pane, watch another pane's output, or script slime. Applies when the
  environment has SLIME_PANE or SLIME_EXE.
---

# Driving slime

slime is a daemon that owns terminals. Each pane is a program on a pty
with its terminal state; panes sit in tabs (a layout tree), tabs in
workspaces; windows draw them, locally or over SSH, and panes outlive
their windows. The `slime` command controls all of it, and every control
is also a JSON-RPC method (`slime call`) and a Lua function (`slime do`).

## Find the CLI

A shell in a slime pane has `SLIME_EXE`, the daemon's own executable, and
its directory is first on `PATH`, so `slime` runs it. If `slime` isn't
found (a shell profile reset `PATH`), run `"$SLIME_EXE"` (`& $env:SLIME_EXE`
in PowerShell), or put `$(dirname "$SLIME_EXE")` back on `PATH`. Use that
executable and not another slime on the machine: it is the build the
daemon runs, so its commands and its manual match the daemon.

No `SLIME_EXE` means this shell isn't in a slime pane. Then slime can't
be driven from here unless a `slime` on `PATH` reaches a daemon.

## Learn it from the CLI

The CLI is its own manual, for the exact build you're talking to. Run
`slime help` once and read it all: every command with its flags, then the
topics. Afterwards, `slime help <command>` (`slime help pane split`) or
`slime help <topic>`:

- `env`: `SLIME_PANE`, `SLIME_WORKSPACE`, `SLIME_EXE`, `SLIME_INSTANCE`
- `ids`: workspaces, tabs, and panes are paths (`1`, `1.2`, `1.2.3`)
- `lua`: the `slime` table scripts get, with examples
- `methods`, `events`: the control plane, for `slime call` and scripts

Don't guess flags, methods, or fields: read them from `slime help`.

## The shape of it

- `slime ls` lists every workspace, tab, and pane, with ids; `--json` on
  any command gives the daemon's reply as data.
- Pane commands (`split`, `write`, `text`, `focus`, `move`, `info`,
  `kill`) act on this pane when given none; `slime tab new` adds to this
  workspace; `slime do` runs its script for this pane.
- `slime pane split right <command>` opens a pane beside this one and
  prints its id; `slime pane text <id>` reads its screen and scrollback
  without disturbing it; `slime pane write <id> <text>` types into it,
  where a carriage return presses enter.
- A pane's program ending ends the pane. To keep a result on screen,
  run a shell and write the command to it.
- `slime do <file.lua>` runs Lua in the daemon; `slime do <action>` runs
  an action the user's `init.lua` defined (`slime actions` lists them,
  `slime config show` the rest of the config). Don't edit `init.lua`
  unless asked.

## Manners

The user is working in these panes. Don't kill, move, or type into
panes you didn't make unless asked; read them freely. Prefer a new pane
or tab for your own work, and clean up what you opened when done.
