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
the script. One state per run, cancelled between instructions, so a
blocking call finishes before a cancel lands.

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

Calls return the result table, or nil, message, code (see slime help
methods for the codes). Wrap in assert(...) when failure should end the
script. The namespaces are metatables: any method the daemon has works,
including ones added later, without a Lua-side list.

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
focus (a window's own do). subscribe, hooks, wait, timers, and exec are
not available yet.

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
  if #assert(slime.workspace.list{}).workspaces > 0 then slime.stop("already set up") end`

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
	if !ctx.Pane.IsZero() {
		slime.RawSetString("workspace_id", glua.LNumber(ctx.Pane.WS))
		slime.RawSetString("tab_id", glua.LString(ctx.Pane.TabID().String()))
		slime.RawSetString("pane_id", glua.LString(ctx.Pane.String()))
	}
	slime.RawSetString("call", L.NewFunction(r.luaCall))
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
	L.SetGlobal("slime", slime)
	L.SetGlobal("print", L.NewFunction(r.luaPrint))
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
	if err != nil {
		var rerr *rpc.Error
		if errors.As(err, &rerr) {
			return pushError(L, rerr.Message, rerr.Code)
		}
		return pushError(L, err.Error(), 0)
	}
	v, err := fromJSON(L, result)
	if err != nil {
		return pushError(L, fmt.Sprintf("%s: result: %v", method, err), 0)
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
	r.host.Output(Stdout, line(L)+"\n")
	return 0
}

// luaLog is slime.log(...): a line for the daemon's log.
func (r *Runner) luaLog(L *glua.LState) int {
	r.host.Log(line(L))
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
		r.stopResult = L.Get(1)
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
