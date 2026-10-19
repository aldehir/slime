package lua

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// The slime table, as Doc says; its shape is Rex's with the nouns
// renamed. Doc is `slime help lua`, kept here with what it describes.
const Doc = `Scripts run in the daemon (slime do) with gopher-lua, a Lua 5.1. The
libraries are base, package, table, string, math, coroutine, debug, and
os without exit; there is no io, and print goes to the console that ran
the script. One state per run. The chunk, and each call of a hook,
timer, or process callback, is a task: one runs Lua at a time, and a
task that blocks (sleep, wait, exec, a process's wait) lets the others
run meanwhile, so Lua never runs concurrently with itself. A script
ends when its chunk has returned and no hook or timer is live, when it
calls slime.stop, or when it's cancelled (its tasks end at their next
instruction or blocking call).

THE SLIME TABLE

  slime.args                 table of the key=value arguments (empty if none)
  slime.workspace_id         what the script runs for, or nil: a number,
  slime.tab_id, slime.pane_id    "w.t", and "w.t.p"; read at call time, so a
                             script may set them to retarget
  slime.call(method, params) any method by wire name; params a table or nil
  slime.workspace.<m>{...}   workspace.<m> with id filled from workspace_id
                             (not for list); new gets attach from it instead,
                             so the windows on the script's workspace open the
                             new one (attach = false leaves it detached; another
                             id names another workspace's windows); focus with
                             neither tab nor pane gets pane from pane_id
  slime.tab.<m>{...}         tab.<m>; tab.new gets workspace, the rest id
                             from tab_id
  slime.pane.<m>{...}        pane.<m>; split and move get pane, the rest id
                             from pane_id
  slime.id.parse(id)         {workspace, tab, pane} from 1, "1.2", or "1.2.3"
                             (the parts it has); nil, err for anything else
  slime.id.tab(w, t)         "w.t" and "w.t.p" from numbers
  slime.id.pane(w, t, p)
  slime.layout.pane{command, cwd, env}
                             a leaf for tabs in workspace.new or layout in tab.new
  slime.layout.horizontal([ratio,] a, b, ...)
                             side by side (a row split); ratio is a's share (0 to
                             1), the rest share what's left equally; no ratio
                             divides equally
  slime.layout.vertical([ratio,] a, b, ...)
                             stacked (a column split); same rule
  slime.json.encode(v)       JSON; return nil, err on failure
  slime.json.decode(s)
  slime.log(...)             a line to the daemon's log and the script's stderr;
                             arguments joined by tabs like print
  slime.stop([result])       ends the run successfully, with result as its
                             return value
  slime.invoke(name, args)   runs an action init.lua defined (below), for this
                             script's pane, and returns what it returned, or
                             nil, message, code; its output is the script's

Calls return the result table, or nil, message, code (see slime help
methods for the codes). Wrap in assert(...) when failure should end the
script. The namespaces are metatables: any method the daemon has works,
including ones added later, without a Lua-side list.

EVENTS, WAITING, TIMERS, PROCESSES

  slime.on(event, fn)        fn(ctx, ev) runs for each event (a name from slime
                             help events, "pane.*" for a group, or "*"), in a
                             task of its own; ev is the event's params. Returns
                             a handle: h:cancel() ends it, h:active() says. A
                             live hook keeps a script running after its chunk
                             returns; cancel it or call slime.stop to end.
  slime.wait(event, filter, timeout)
                             blocks until the next such event whose fields
                             equal filter's (a table, or nil for any): a key
                             names a field of ev, except workspace_id, tab_id,
                             and pane_id, which name what the event is about
                             (a pane's names its tab and workspace too).
                             Returns ev, or nil, "timeout" after timeout
                             seconds (none waits as long as the run lasts).
  slime.sleep(seconds)       blocks for that long
  slime.after(seconds, fn)   fn(ctx) runs once after the delay; a handle as on
  slime.every(seconds, fn)   and again after each delay until cancelled
  slime.exec(argv, opts)     runs a program on the daemon's host to its end:
                             argv a list of strings (the program first), opts
                             {cwd, env = {VAR = "value"}, stdin = "text",
                             timeout = seconds}. Returns {status, ok, stdout,
                             stderr}, or nil, err if it couldn't start or timed
                             out (it's killed then).
  slime.exec.start(argv, opts)
                             starts one and returns a handle: p.pid, p:running(),
                             p:wait([timeout]) (the result above, or nil,
                             "timeout"), p:kill(), and with opts.stdin = true,
                             p:write(text) and p:close_stdin(). opts.stdout and
                             opts.stderr may be functions that get each piece of
                             output as it comes (then wait's are empty). A run
                             ending kills the processes it started.
  slime.client.queue(name, args)
                             asks the windows on this script's workspace to
                             perform window action name (new_tab, new_split
                             {direction = "down"}, toggle_split_zoom, ...) with
                             args, as if its key were pressed there; each
                             window showing the workspace does, on its own focus

ctx for a hook is {workspace_id, tab_id, pane_id, origin = "event", event}:
what the event is about, as filter sees it; for a timer, what the
script runs for and origin = "timer". Hooks and timers run for the ids
the script had when they were set. An error in a hook ends the script
(in init.lua, it's logged). An event nobody is waiting for yet isn't
kept: set the hook, or start the wait, before causing the event where
it matters.

INIT.LUA

The daemon evaluates init.lua (slime config path; SLIME_CONFIG overrides)
when it starts and on slime config reload, in a state of its own that
lives as long as the config: the functions the file hands to bind and
action are called again from it for every key press and slime do. It
has the slime table above (ids are nil at the top level) and these,
which are for the top level only:

  slime.config{...}          the settings, one table, merged over earlier
                             calls key by key (lists replace). The daemon takes
                             shell.command (what a pane runs when nothing says);
                             each window takes what it understands and ignores
                             the rest (slime-gui: font, theme, colors, window,
                             chrome, selection, clipboard, ssh). Values must be
                             JSON: no functions.
  slime.bind(key, action[, args])
                             key (a chord: "ctrl+shift+d"; modifiers ctrl,
                             shift, alt, super/win, then a key name) runs a
                             window action by name with args (slime-gui's:
                             new_tab, new_split {direction}, close_surface,
                             next_tab, previous_tab, goto_split {direction},
                             resize_split {direction, amount}, equalize_splits,
                             toggle_split_zoom, copy_to_clipboard,
                             paste_from_clipboard, increase_font_size {amount},
                             decrease_font_size {amount}, reset_font_size), or
                             else an action of this file by name. A later bind
                             of the key replaces the earlier, and the window's
                             default for it.
  slime.bind(key, fn)        key runs fn(ctx, args) in the daemon; a function
                             binding always consumes its key
  slime.unbind(key)          key does nothing, even if the window binds it
  slime.action{name, title, args, run}
                             an action: slime do <name> key=value..., a bound
                             key, and slime.invoke run run(ctx, args), and print
                             what it returns. args is a spec for listing and
                             for converting the CLI's strings: {n = "number",
                             on = "boolean", file = "string"}.

ctx is {workspace_id, tab_id, pane_id, origin}: the pane the action runs
for (a window's focused pane, slime do's SLIME_PANE, a script's own),
also filled into slime.pane_id and the rest while it runs; origin is key,
cli, script, or api. require, dofile, and loadfile find files beside
init.lua. A file that fails leaves the last good config in place (the
daemon's log and slime config show say why); slime config check tries
one without applying it.

  slime.config{
    font = { family = { "Cascadia Code", "Consolas" }, size = 12, antialias = "grayscale" },
    theme = "Catppuccin Mocha",      -- a Ghostty theme file under themes/ (its file name)
    colors = { background = "#282c34", cursor = "#ffcc00" },
    window = { padding = { x = 3, y = 3 } },
    chrome = { scale = 1 },
    shell = { command = "pwsh -NoLogo" },
  }
  slime.bind("ctrl+shift+d", "new_split", { direction = "right" })
  slime.bind("ctrl+shift+t", "new_tab")
  slime.bind("ctrl+alt+l", function(ctx, args) slime.invoke("dev", { file = "app.log" }) end)
  slime.action{ name = "dev", title = "Dev layout", args = { file = "string" },
    run = function(ctx, args) return dofile("dev.lua") end }

Values cross as JSON. Numbers are doubles; workspace ids are numbers,
tab and pane ids strings, compared with ==. A table whose keys are
exactly 1..n is an array; any other table, including an empty one, is
an object. So a method that takes a list can't be given an empty table,
and nil in a table means the key is absent. Functions and cycles can't
be encoded.

Caveats: pcall catches slime.stop (it is an error under the hood). A
script is never a viewer: slime.workspace.new needs tabs; run from a
pane, the windows on that pane's workspace open the new one, otherwise
it starts detached. A script's split, tab.new, and move don't take the
focus (a window's own do). subscribe is the wire's; slime.on is a
script's. slime.config, bind, unbind, and action are init.lua's. In
init.lua, hooks and timers set at the top level live as long as that
config does (a reload ends them, and what the old config was running),
and an action may sleep, wait, and exec: another key's action runs
meanwhile.

EXAMPLES

Inspect (slime do -e '...'):

  local l = assert(slime.workspace.list{})
  for _, ws in ipairs(l.workspaces) do
    print(ws.id, ws.name, ws.attached and "attached" or "detached", #ws.tabs .. " tabs")
  end
  for _, p in ipairs(l.panes) do print("pane", p.id, p.command, p.title) end

Build a workspace from a layout (slime do dev.lua file=app.log):

  local ws = assert(slime.workspace.new{
    name = "dev",
    tabs = {
      slime.layout.horizontal(0.7,
        slime.layout.pane{ command = "nvim" },
        slime.layout.vertical(0.5,
          slime.layout.pane{ command = "tail -f " .. slime.args.file },
          slime.layout.pane{})),
      slime.layout.pane{ command = "bash", cwd = "/src", env = { EDITOR = "nvim" } },
    },
  })
  print("workspace", ws.id, "opens on tab", ws.active_tab)
  return ws.id

From inside a pane (ids default to this pane):

  local me = assert(slime.pane.info{})
  local below = assert(slime.pane.split{ direction = "down", share = 3000 })
  assert(slime.pane.write{ id = below.pane, text = "cd " .. me.pwd .. "\r" })
  assert(slime.workspace.focus{ pane = below.pane })   -- its tab comes with it

Walk a tab's tree:

  local function leaves(node, out)
    if node.pane then out[#out + 1] = node.pane
    else for _, c in ipairs(node.split.children) do leaves(c.node, out) end end
    return out
  end
  local t = assert(slime.tab.info{ id = slime.tab_id })
  for _, id in ipairs(leaves(t.tree, {})) do
    print(id, assert(slime.pane.text{ id = id }).text:match("[^\n]*$"))  -- last line of each
  end

Errors and stopping early:

  local p, err, code = slime.pane.info{ id = "1.1.999" }
  if not p then slime.log("no pane:", err, code) end          -- 1000 is not found
  if #assert(slime.workspace.list{}).workspaces > 0 then slime.stop("already set up") end

Run a command below and wait for it (slime do build.lua):

  local p = assert(slime.pane.split{ direction = "down", share = 3000, command = "go build ./..." })
  local ev = slime.wait("pane.exited", { pane_id = p.pane }, 600)
  if not ev then slime.stop("still building") end
  if ev.status ~= 0 then slime.client.queue("toggle_split_zoom") end
  return "exit " .. ev.status

Watch for bells until stopped (slime do --detach watch.lua; slime scripts kill <id>):

  slime.on("pane.bell", function(ctx, ev)
    local info = assert(slime.pane.info{ id = ev.id })
    slime.log("bell in", ev.id, info.title or "")
  end)
  slime.every(60, function() slime.log("still watching") end)

Shell out (on the daemon's host):

  local r = assert(slime.exec({ "git", "status", "--short" }, { cwd = slime.args.dir }))
  for line in r.stdout:gmatch("[^\n]+") do print(line) end`

// install sets the script's globals: the slime table, and print.
func (r *Runner) install(ctx Context) {
	L := r.L
	slime := L.NewTable()
	r.slime = slime
	args := glua.LValue(L.NewTable())
	if len(ctx.Args) > 0 {
		if v, err := fromJSON(L, ctx.Args); err == nil && v != glua.LNil {
			args = v
		}
	}
	slime.RawSetString("args", args)
	r.setIDs(idsOf(ctx.Pane))
	slime.RawSetString("call", L.NewFunction(r.luaCall))
	slime.RawSetString("invoke", L.NewFunction(r.luaInvoke))
	for _, group := range []string{"workspace", "tab", "pane"} {
		slime.RawSetString(group, r.namespace(group))
	}
	ids := L.NewTable()
	L.SetFuncs(ids, map[string]glua.LGFunction{"parse": idParse, "tab": idTab, "pane": idPane})
	slime.RawSetString("id", ids)
	layout := L.NewTable()
	L.SetFuncs(layout, map[string]glua.LGFunction{
		"pane":       layoutPane,
		"horizontal": func(L *glua.LState) int { return layoutSplit(L, rpc.Row) },
		"vertical":   func(L *glua.LState) int { return layoutSplit(L, rpc.Column) },
	})
	slime.RawSetString("layout", layout)
	jsonT := L.NewTable()
	L.SetFuncs(jsonT, map[string]glua.LGFunction{"encode": jsonEncode, "decode": jsonDecode})
	slime.RawSetString("json", jsonT)
	slime.RawSetString("log", L.NewFunction(r.luaLog))
	slime.RawSetString("stop", L.NewFunction(r.luaStop))
	slime.RawSetString("on", L.NewFunction(r.luaOn))
	slime.RawSetString("wait", L.NewFunction(r.luaWait))
	slime.RawSetString("sleep", L.NewFunction(r.luaSleep))
	slime.RawSetString("after", L.NewFunction(r.luaAfter))
	slime.RawSetString("every", L.NewFunction(r.luaEvery))
	r.installHandles()
	r.installExec()
	client := L.NewTable()
	client.RawSetString("queue", L.NewFunction(r.luaClientQueue))
	slime.RawSetString("client", client)
	L.SetGlobal("slime", slime)
	L.SetGlobal("print", L.NewFunction(r.luaPrint))
}

// luaClientQueue is slime.client.queue(name, args): the windows on the
// script's workspace perform window action name with args
// (client.queue, which sends them client.action).
func (r *Runner) luaClientQueue(L *glua.LState) int {
	name := L.CheckString(1)
	params := L.NewTable()
	params.RawSetString("name", glua.LString(name))
	if args := L.OptTable(2, nil); args != nil {
		params.RawSetString("args", args)
	}
	ws := r.slime.RawGetString("workspace_id")
	if ws == glua.LNil {
		return pushError(L, "client.queue: no workspace: the script runs for no pane", 0)
	}
	params.RawSetString("workspace", ws)
	return r.call(L, rpc.ClientQueue, params)
}

// namespace is slime.<group>: a table whose missing keys become the
// methods "<group>.<key>", made on first use.
func (r *Runner) namespace(group string) *glua.LTable {
	L := r.L
	t := L.NewTable()
	mt := L.NewTable()
	mt.RawSetString("__index", L.NewFunction(func(L *glua.LState) int {
		key := L.CheckString(2)
		method := group + "." + key
		fn := L.NewFunction(func(L *glua.LState) int {
			params := L.OptTable(1, L.NewTable())
			r.fillContext(method, params)
			return r.call(L, method, params)
		})
		t.RawSetString(key, fn)
		L.Push(fn)
		return 1
	}))
	L.SetMetatable(t, mt)
	return t
}

// fillContext puts the script's ids into the params a method takes
// them in, where the script left them out: a workspace method's id,
// workspace.new's attach (so the windows on the script's workspace open
// the new one; attach = false leaves it detached, true asks for the
// default), workspace.focus's pane (or tab, with no pane to fill),
// tab.new's workspace, a pane method's id, and the pane a split or move
// starts from.
func (r *Runner) fillContext(method string, params *glua.LTable) {
	var field, from string
	group, name, _ := strings.Cut(method, ".")
	switch group {
	case "workspace":
		switch name {
		case "list":
			return
		case "new":
			field, from = "attach", "workspace_id"
			switch params.RawGetString(field) {
			case glua.LFalse:
				params.RawSetString(field, glua.LNil)
				return
			case glua.LTrue:
				params.RawSetString(field, glua.LNil)
			}
		case "focus":
			if params.RawGetString("tab") != glua.LNil || params.RawGetString("pane") != glua.LNil {
				return
			}
			field, from = "pane", "pane_id"
			if r.slime.RawGetString(from) == glua.LNil {
				field, from = "tab", "tab_id"
			}
		default:
			field, from = "id", "workspace_id"
		}
	case "tab":
		if name == "new" {
			field, from = "workspace", "workspace_id"
		} else {
			field, from = "id", "tab_id"
		}
	case "pane":
		if name == "split" || name == "move" {
			field, from = "pane", "pane_id"
		} else {
			field, from = "id", "pane_id"
		}
	default:
		return
	}
	if params.RawGetString(field) != glua.LNil {
		return
	}
	if id := r.slime.RawGetString(from); id != glua.LNil {
		params.RawSetString(field, id)
	}
}

// luaCall is slime.call(method, params).
func (r *Runner) luaCall(L *glua.LState) int {
	method := L.CheckString(1)
	return r.call(L, method, L.OptTable(2, nil))
}

// call runs method with params and pushes its result, or nil, the
// error's message, and its code.
func (r *Runner) call(L *glua.LState, method string, params *glua.LTable) int {
	var raw json.RawMessage
	if params != nil {
		b, err := toJSON(params)
		if err != nil {
			return pushError(L, fmt.Sprintf("%s: params: %v", method, err), 0)
		}
		raw = b
	}
	result, err := r.host.Call(method, raw)
	return pushResult(L, method, result, err)
}

// luaInvoke is slime.invoke(name, args): an action of the config file,
// run by the daemon, with what it returned.
func (r *Runner) luaInvoke(L *glua.LState) int {
	name := L.CheckString(1)
	var raw json.RawMessage
	if args := L.OptTable(2, nil); args != nil {
		b, err := toJSON(args)
		if err != nil {
			return pushError(L, fmt.Sprintf("invoke %s: args: %v", name, err), 0)
		}
		raw = b
	}
	// A nested call (the config's own) runs in the state this was
	// called from, which may be a coroutine of the task's.
	t := r.current
	saved := t.callL
	t.callL = L
	result, err := r.host.Invoke(name, raw)
	t.callL = saved
	return pushResult(L, "invoke "+name, result, err)
}

// pushResult pushes what a call to the host returned: its result as a
// Lua value, or nil, the error's message, and its code.
func pushResult(L *glua.LState, what string, result json.RawMessage, err error) int {
	if err != nil {
		var rerr *rpc.Error
		if errors.As(err, &rerr) {
			return pushError(L, rerr.Message, rerr.Code)
		}
		return pushError(L, err.Error(), 0)
	}
	if len(result) == 0 {
		L.Push(glua.LNil)
		return 1
	}
	v, err := fromJSON(L, result)
	if err != nil {
		return pushError(L, fmt.Sprintf("%s: result: %v", what, err), 0)
	}
	L.Push(v)
	return 1
}

func pushError(L *glua.LState, msg string, code int) int {
	L.Push(glua.LNil)
	L.Push(glua.LString(msg))
	if code != 0 {
		L.Push(glua.LNumber(code))
		return 3
	}
	return 2
}

// luaPrint is print: a line on stdout.
func (r *Runner) luaPrint(L *glua.LState) int {
	r.output(Stdout, line(L)+"\n")
	return 0
}

// luaLog is slime.log(...): a line for the daemon's log, and on the
// task's own stderr if it has one.
func (r *Runner) luaLog(L *glua.LState) int {
	text := line(L)
	r.host.Log(text)
	if t := r.current; t != nil && t.out != nil {
		t.out(Stderr, text+"\n")
	}
	return 0
}

// line joins the arguments as print does, with tabs.
func line(L *glua.LState) string {
	var b strings.Builder
	for i := 1; i <= L.GetTop(); i++ {
		if i > 1 {
			b.WriteByte('\t')
		}
		b.WriteString(L.ToStringMeta(L.Get(i)).String())
	}
	return b.String()
}

// luaStop is slime.stop([result]): the run ends, successfully, with
// result as what it returned.
func (r *Runner) luaStop(L *glua.LState) int {
	if L.GetTop() > 0 {
		r.current.stopResult = L.Get(1)
	}
	L.Error(r.stop, 0)
	return 0
}

// idParse is slime.id.parse(id): the parts of a workspace, tab, or
// pane id as {workspace, tab, pane}, the ones it has; or nil and why
// not.
func idParse(L *glua.LState) int {
	var text string
	switch v := L.Get(1).(type) {
	case glua.LNumber:
		text = numberString(float64(v))
	case glua.LString:
		text = string(v)
	default:
		return pushError(L, "an id is a number or a string", 0)
	}
	parts := strings.Split(text, ".")
	if len(parts) > 3 {
		return pushError(L, fmt.Sprintf("%q isn't an id", text), 0)
	}
	out := L.NewTable()
	for i, name := range []string{"workspace", "tab", "pane"} {
		if i >= len(parts) {
			break
		}
		n, err := strconv.ParseUint(parts[i], 10, 32)
		if err != nil || n == 0 {
			return pushError(L, fmt.Sprintf("%q isn't an id", text), 0)
		}
		out.RawSetString(name, glua.LNumber(n))
	}
	L.Push(out)
	return 1
}

// idTab is slime.id.tab(workspace, tab): "w.t".
func idTab(L *glua.LState) int {
	id := rpc.TabID{WS: idPart(L, 1), N: idPart(L, 2)}
	L.Push(glua.LString(id.String()))
	return 1
}

// idPane is slime.id.pane(workspace, tab, pane): "w.t.p".
func idPane(L *glua.LState) int {
	id := rpc.PaneID{WS: idPart(L, 1), Tab: idPart(L, 2), N: idPart(L, 3)}
	L.Push(glua.LString(id.String()))
	return 1
}

// idPart is argument i of an id: a positive integer.
func idPart(L *glua.LState, i int) uint32 {
	n := L.CheckNumber(i)
	if n <= 0 || n != glua.LNumber(uint32(n)) {
		L.ArgError(i, "an id's parts are positive integers")
	}
	return uint32(n)
}

// layoutPane is slime.layout.pane{command, cwd, env}: a leaf of a
// layout tree, in the form tab.new and workspace.new take.
func layoutPane(L *glua.LState) int {
	spec := L.OptTable(1, L.NewTable())
	leaf := L.NewTable()
	leaf.RawSetString("pane", spec)
	L.Push(leaf)
	return 1
}

// layoutSplit is slime.layout.horizontal(ratio, a, b, ...) or vertical:
// a split along axis whose first child takes ratio of it and the rest
// share what's left equally; with no ratio, all share equally.
// horizontal lays its children side by side (a row), vertical stacks
// them (a column).
func layoutSplit(L *glua.LState, axis rpc.Axis) int {
	first := 1
	ratio := -1.0
	if n, ok := L.Get(1).(glua.LNumber); ok {
		ratio = float64(n)
		first = 2
		if ratio <= 0 || ratio >= 1 {
			L.ArgError(1, "ratio is between 0 and 1")
			return 0
		}
	}
	n := L.GetTop() - first + 1
	if n < 2 {
		L.RaiseError("a split needs at least two children")
		return 0
	}
	shares := make([]int, n)
	if ratio >= 0 {
		shares[0] = int(math.Round(ratio * rpc.Whole))
		left := rpc.Whole - shares[0]
		for i := 1; i < n; i++ {
			shares[i] = left / (n - 1)
		}
		shares[n-1] += left - shares[n-1]*(n-1)
	}
	children := L.NewTable()
	for i := 0; i < n; i++ {
		child := L.NewTable()
		if shares[i] != 0 {
			child.RawSetString("share", glua.LNumber(shares[i]))
		}
		child.RawSetString("node", L.CheckTable(first+i))
		children.Append(child)
	}
	split := L.NewTable()
	split.RawSetString("axis", glua.LString(axis.String()))
	split.RawSetString("children", children)
	node := L.NewTable()
	node.RawSetString("split", split)
	L.Push(node)
	return 1
}

// jsonEncode is slime.json.encode(v): v as JSON, or nil and why not.
func jsonEncode(L *glua.LState) int {
	b, err := toJSON(L.Get(1))
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	L.Push(glua.LString(b))
	return 1
}

// jsonDecode is slime.json.decode(s): the value s holds, or nil and
// why not.
func jsonDecode(L *glua.LState) int {
	v, err := fromJSON(L, []byte(L.CheckString(1)))
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	L.Push(v)
	return 1
}
