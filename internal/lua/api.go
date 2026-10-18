package lua

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// The slime table. Its shape is Rex's with the nouns renamed:
//
//	slime.args                       the script's arguments
//	slime.workspace_id, tab_id, pane_id   what it runs for, or nil
//	slime.call(method, params)       any method, by its wire name
//	slime.workspace.<m>{...}         "workspace.<m>", id filled in;
//	                                 new's attach too (false: detached)
//	slime.tab.<m>{...}               "tab.<m>", id or workspace filled in
//	slime.pane.<m>{...}              "pane.<m>", id or pane filled in
//	slime.layout.pane{...}, horizontal(ratio, a, b, ...), vertical
//	slime.json.encode(v), decode(s)
//	slime.log(...)                   to the daemon's log
//	slime.stop([result])             ends the run, successfully
//
// A call returns its result, or nil, the error's message, and its
// code, as Rex's do. An uncaught error ends the run with status 1.

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
	for name, id := range map[string]uint32{"workspace_id": ctx.Workspace, "tab_id": ctx.Tab, "pane_id": ctx.Pane} {
		if id != 0 {
			slime.RawSetString(name, glua.LNumber(id))
		}
	}
	slime.RawSetString("call", L.NewFunction(r.luaCall))
	for _, group := range []string{"workspace", "tab", "pane"} {
		slime.RawSetString(group, r.namespace(group))
	}
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
// default), tab.new's workspace, a pane method's id, and the pane a
// split or move starts from.
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
