---
name: slime
description: >-
  Drive slime, the terminal daemon in this repo, from the command line and
  from Lua: list, create, split, write to, read, focus, and kill workspaces,
  tabs, and panes with `slime ls|ws|tab|pane|call`; run Lua in the daemon with
  `slime do` (files, -e code, stdin, key=value args, --detach, slime scripts);
  build layouts with slime.layout; call any control-plane method. Use when the
  user wants to script or inspect slime's workspaces, write a slime Lua script,
  automate a layout, or look up the slime Lua API, the method table, its
  params and results, events, or error codes. Covers SLIME_INSTANCE,
  SLIME_PANE, SLIME_WORKSPACE, and the rules for test daemons.
---

# Driving slime

slime (`slime.exe`, `cmd/slime`) is a daemon that owns terminals: each
pane is a pty plus its terminal state, panes sit in tabs (a layout tree),
tabs in workspaces. Windows (`slime-gui.exe`) attach a workspace and draw
it; any number may view one workspace. Everything that manages the model
is a JSON-RPC method on one table (`internal/rpc` names it,
`internal/daemon/rpc.go` serves it). The CLI calls that table over the
pipe, and Lua run by `slime do` calls it in process. A method that
exists for one exists for all.

## Before running anything

- Alde may be dogfooding slime. Every CLI command talks to the daemon
  on the per-user pipe `\\.\pipe\slime-<sid>` and starts one if none is
  running. **To stay off the dogfood daemon, set `SLIME_INSTANCE=<name>`**
  in the shell: the pipe becomes `slime-<sid>-<name>` and `slime do`
  starts a daemon of its own. Stop that one by PID when done; never kill
  processes you didn't start.
- Build the CLI with `go build -o <dir>\slime.exe ./cmd/slime` after
  `. .\scripts\setup-msvc.ps1` (cgo needs `zig cc`). `zig build` puts
  it in `zig-out\bin\`. See `AGENTS.md`.
- Pane ids, tab ids, workspace ids, and script ids share one counter,
  so they are unique across kinds.

## The CLI

```
slime ls [--json]                                  workspaces, tabs, panes
slime ws new [name] | rename <ws> <name> | kill <ws> | info <ws>
slime ws focus <ws> <tab> [pane]                   show a tab in every window on the workspace
slime tab new [-w ws] [-n name] [--split right|down] [command]...
slime tab rename <tab> <name> | close <tab> | info <tab>
slime pane split <pane> right|down|left|up [-p percent] [command]
slime pane move <pane> <tab|new> [right|down|left|up]
slime pane focus <pane> [--zoom|--unzoom]
slime pane write <pane> <text>                     typed as is; "\r" presses enter
slime pane text <pane> [--vt]                      screen and scrollback
slime pane info <pane> | kill <pane>...
slime do <file.lua | -> [key=value...] [-e code] [-p pane] [--detach]
slime scripts [ls] | scripts kill <id>...
slime call <method> [params-json]                  any method, raw reply
slime host connect <dest> | ls | disconnect <id|dest>   (Windows daemon)
slime serve [--idle 10s] [--log file] [-v]         run the daemon in the foreground
```

`--json` on any command prints the daemon's reply as it came. Commands
take `CreateProcessW` syntax for a pane's command; an empty command is
the default shell. `slime tab new` with several commands gives each a
pane sharing the tab along `--split`.

## `slime do`

```powershell
slime do dev.lua file=app.log            # a file, with slime.args.file = "app.log"
slime do -e 'return slime.workspace.list{}'
'print("hi")' | slime do -               # stdin
slime do --detach -e 'while true do end' # prints the script id, returns at once
slime do --json -e 'return { a = 1 }'    # the result as raw JSON
```

- Arguments after the script are `key=value`, strings in `slime.args`.
  A bare word that isn't a file is an error (named actions come with
  the config stage).
- `-p <pane>` sets the pane the script runs for; it defaults to
  `$SLIME_PANE`, which every pane's shell has. From inside a pane,
  `slime do` therefore targets that pane, its tab, and its workspace
  unless the script says otherwise.
- What the script `print`s comes to stdout as it runs; `slime.log` goes
  to stderr and the daemon's log. The value the chunk returns prints at
  the end: a string as is, anything else as JSON, nothing for `nil`.
- An uncaught error prints the message and stack trace and exits 1.
- Ctrl+C sends `script.cancel`; a second Ctrl+C gives up waiting.
- Without `--detach`, closing the console cancels the script. With it,
  the script runs on; `slime scripts` lists it and `slime scripts kill`
  ends it.

## Lua API: the `slime` table

The runtime is gopher-lua (Lua 5.1). Libraries: base, package, table,
string, math, coroutine, debug, and os without `exit`. There is no `io`;
`print` is stdout. One state per run, cancelled between instructions,
so a blocking Go call finishes before a cancel lands.

| name | what |
|---|---|
| `slime.args` | table of the `key=value` arguments (an empty table if none) |
| `slime.workspace_id`, `slime.tab_id`, `slime.pane_id` | the context, or nil; read at call time, so a script may set them to retarget |
| `slime.call(method, params)` | any method by wire name; `params` a table or nil |
| `slime.workspace.<m>{...}` | `workspace.<m>` with `id` filled from `workspace_id` (not for `list`, `new`) |
| `slime.tab.<m>{...}` | `tab.<m>`; `tab.new` gets `workspace`, the rest get `id` from `tab_id` |
| `slime.pane.<m>{...}` | `pane.<m>`; `split` and `move` get `pane`, the rest get `id` from `pane_id` |
| `slime.layout.pane{command, cwd, env}` | a leaf for `tabs` in `workspace.new` or `layout` in `tab.new` |
| `slime.layout.horizontal([ratio,] a, b, ...)` | side by side; `ratio` is `a`'s share (0 to 1), the rest share what's left equally; no ratio divides equally |
| `slime.layout.vertical([ratio,] a, b, ...)` | stacked; same rule |
| `slime.json.encode(v)`, `slime.json.decode(s)` | JSON; return `nil, err` on failure |
| `slime.log(...)` | a line to the daemon's log and the script's stderr; arguments joined by tabs like `print` |
| `slime.stop([result])` | ends the run successfully, with `result` as its return value |

**Calls return the result table, or `nil, message, code`** where code
is the error code below. Wrap in `assert(...)` when failure should end
the script. The namespaces are metatables: any method the daemon has
works, including ones added later, without a Lua-side list.

**Values cross as JSON.** Numbers are doubles (ids fit). A table whose
keys are exactly 1..n is an array; any other table, including an empty
one, is an object. So a method that takes a list can't be given an
empty table, and `nil` in a table means the key is absent. Functions
and cycles can't be encoded.

**Caveats.** `pcall` catches `slime.stop` (it is an error under the
hood). A script is never a viewer: `slime.workspace.new` needs `tabs`,
the workspace starts detached, and a script's `split`, `tab.new`, and
`move` don't take the focus (a window's own do). `subscribe`, hooks,
`wait`, timers, and `exec` are not available yet.

## Examples

Inspect, from a console:

```lua
-- slime do -e '...'
local l = assert(slime.workspace.list{})
for _, ws in ipairs(l.workspaces) do
  print(ws.id, ws.name, ws.attached and "attached" or "detached", #ws.tabs .. " tabs")
end
for _, p in ipairs(l.panes) do print("pane", p.id, p.command, p.title) end
```

Build a workspace from a layout (`slime do dev.lua file=app.log`):

```lua
local ws = assert(slime.workspace.new{
  name = "dev",
  tabs = {
    slime.layout.horizontal(0.7,
      slime.layout.pane{ command = "nvim" },
      slime.layout.vertical(0.5,
        slime.layout.pane{ command = "pwsh -c Get-Content -Wait " .. slime.args.file },
        slime.layout.pane{})),
    slime.layout.pane{ command = "pwsh", cwd = "E:\\Development", env = { EDITOR = "nvim" } },
  },
})
print("workspace", ws.id, "opens on tab", ws.active_tab)
return ws.id
```

A new window attaches the most recently detached workspace, so the next
`slime-gui` shows it; `SLIME_WORKSPACE=<id>` in the window's environment
picks one explicitly.

From inside a pane (ids default to this pane):

```lua
local me = assert(slime.pane.info{})
local below = assert(slime.pane.split{ direction = "down", share = 3000, command = "pwsh" })
assert(slime.pane.write{ id = below.pane, text = "cd " .. me.pwd .. "\r" })
assert(slime.workspace.focus{ tab = slime.tab_id, pane = below.pane })
```

Walk a tab's tree:

```lua
local function leaves(node, out)
  if node.pane then out[#out + 1] = node.pane
  else for _, c in ipairs(node.split.children) do leaves(c.node, out) end end
  return out
end
local t = assert(slime.tab.info{ id = slime.tab_id })
for _, id in ipairs(leaves(t.tree, {})) do
  print(id, assert(slime.pane.text{ id = id }).text:match("[^\n]*$"))  -- last line of each
end
```

Error handling and stopping early:

```lua
local p, err, code = slime.pane.info{ id = 999 }
if not p then slime.log("no pane:", err, code) end          -- 1000 is not found
if #assert(slime.workspace.list{}).workspaces > 0 then slime.stop("already set up") end
```

Raw access, with and without Lua:

```powershell
slime do -e 'return slime.call("host.list")'
slime call pane.text '{"id": 3}'
slime call workspace.focus '{"id": 2, "tab": 6, "pane": 3, "zoomed": 3}'
```

## Method reference

Params and results are JSON objects; the Lua tables mirror them
field for field. Ids are integers. `internal/rpc/rpc.go` is the
definition; this is the summary.

### workspace

| method | params | result |
|---|---|---|
| `workspace.list` | none | `{workspaces: [WorkspaceDesc], panes: [PaneDesc]}` |
| `workspace.new` | `{name?, tabs?: [Layout]}` | `Workspace`; a connection calling it becomes a viewer, a script must give `tabs` |
| `workspace.attach` | `{id, area?}` | `Workspace`; windows only (frames follow) |
| `workspace.detach` | `{id}` | `{}` |
| `workspace.kill` | `{id}` | `{}`; ends every pane in it |
| `workspace.rename` | `{id, name}` | `{}` |
| `workspace.resize` | `{id, area}` | `{}`; a viewer's tab area in pixels |
| `workspace.focus` | `{id, tab?, pane?, zoomed?}` | `{}`; `tab` becomes active, `pane` its focus, `zoomed` the zoomed pane (0 unzooms) |
| `workspace.info` | `{id}` | `WorkspaceDesc` |

### tab

| method | params | result |
|---|---|---|
| `tab.new` | `{workspace, name?, layout?: Layout, command?, cwd?, env?, size?}` | `Created` (`pane` is the first pane) |
| `tab.close` | `{id}` | `{}` |
| `tab.rename` | `{id, name}` | `{}` |
| `tab.layout` | `{id, tree: Node}` | `{}`; same panes, new shares (a divider drag) |
| `tab.info` | `{id}` | `{workspace, id, name, tree, focus, zoomed}` |

### pane

| method | params | result |
|---|---|---|
| `pane.split` | `{pane, direction: right\|down\|left\|up, share?: 1..9999 (basis points, 5000 default), command?, cwd?, env?}` | `Created` |
| `pane.move` | `{pane, tab?: 0 for a new tab, side?}` | `Created` naming the tab it's in now |
| `pane.kill` | `{id}` | `{}` |
| `pane.write` | `{id, text}` | `{}`; as typed, no newline added |
| `pane.text` | `{id, vt?: bool}` | `{text}`: plain, or the VT that redraws it |
| `pane.info` | `{id}` | `PaneDesc` |

### script

| method | params | result |
|---|---|---|
| `script.run` | `{source, name?, args?: object, pane?, detach?}` | `{id}` at once; output and the end arrive as events |
| `script.cancel` | `{id}` | `{}` |
| `script.list` | none | `{scripts: [{id, name, pane, started, detached}]}` |

### other

| method | params | result |
|---|---|---|
| `subscribe` | `{events: ["pane.exited", "host.*", "*"]}` | `{}`; needs a connection (not from Lua) |
| `host.connect` | `{dest}` | `Host`; prompts arrive as `host.prompt`, answered with `host.answer` |
| `host.answer` | `{host, choice: accept\|cancel\|skip, answers?}` | `{}` |
| `host.disconnect` | `{host}` | `{}` |
| `host.list` | none | `{hosts: [Host]}` |

### Shapes

```
Layout     {pane: {command?, cwd?, env?}} | {split: {axis: row|column, children: [{share?, node: Layout}]}}
           shares in basis points summing to 10000, or all absent for equal parts
Node       {pane: id} | {split: {axis, children: [{share, node: Node}]}}      (a built tab's tree)
Workspace  {id, name, active_tab, tabs: [Tab]}
Tab        {id, name?, tree: Node, focus?, zoomed?}
WorkspaceDesc  Workspace plus {attached, viewers?, detached_at?}
PaneDesc   {id, tab, workspace, command, title?, pwd?, cols, rows, created, pid, status?: [{id, state, progress}]}
Created    {workspace, tab, pane}
Host       {id, dest, state: connecting|connected|failed|lost|gone, text?}
```

`slime.layout.horizontal` builds a `row` split, `vertical` a `column`.
Times are unix milliseconds.

### Events

A window gets its workspaces' events without subscribing; a script's
owner gets `script.*` for its scripts; anyone else subscribes. Scripts
can't receive events yet.

| event | params |
|---|---|
| `workspace.created` / `destroyed` | `{id, name}` / `{id}` |
| `workspace.changed` | `Workspace` (structure and focus) |
| `workspace.detached` | `{id, reason}` |
| `workspace.viewer_joined` / `viewer_left` | `{id, viewers}` |
| `tab.created` / `closed` / `renamed` / `selected` | `{workspace, id, name?}` |
| `pane.created` | `{workspace, tab, id}` |
| `pane.attached` | `{id, command, status?}` (viewers only; frames follow) |
| `pane.exited` | `{id, status}` |
| `script.output` | `{id, stream: stdout\|stderr, data}` |
| `script.done` | `{id, ok, result?, error?}` |
| `host.changed` / `host.prompt` | `Host` / `{host, kind, title?, text?, detail?, error?, questions?}` |

### Error codes

| code | meaning |
|---|---|
| -32601 | no such method |
| -32602 | bad params |
| 1000 | no such workspace, tab, pane, host, or script |
| 1001 | unsupported on this daemon (hosts on Linux) |
| 1002 | the op ran and failed (a child didn't start) |

The CLI prints `message (code N)` and exits 1; Lua gets `nil, message, code`.

## Troubleshooting

- **`slime isn't running`**: only commands that create things start the
  daemon (`do`, `tab new`, `host connect`). Run one of those, or
  `slime serve` in another console.
- **`no such pane` right after a split**: the command exited at once
  (`cmd /c dir`); the pane is gone with it. Use a shell.
- **`hello nil`**: `slime.pane_id` is nil outside a pane; pass `-p`.
- **Script hangs on Ctrl+C**: it is inside a Go call; wait, or press
  Ctrl+C again to leave it running and `slime scripts kill` it.
- **Which daemon?** A daemon the CLI started logs to
  `%LOCALAPPDATA%\slime\slime.log` (one the window started logs to
  `slime-<instance>.log` beside it); its first line is
  `serving pipe=\\.\pipe\slime-<sid>[-<instance>] pid=<pid>`, which is
  the PID to stop when you're done with a test instance.
