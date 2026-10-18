package lua

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/rpc"
)

// fakeHost records calls and output, answering each call from answers
// by method, or with an rpc error.
type fakeHost struct {
	calls   []call
	answers map[string]string
	errs    map[string]*rpc.Error
	out     []string
	logs    []string
}

type call struct {
	method string
	params string
}

func (h *fakeHost) Call(method string, params json.RawMessage) (json.RawMessage, error) {
	h.calls = append(h.calls, call{method, string(params)})
	if e := h.errs[method]; e != nil {
		return nil, e
	}
	if a, ok := h.answers[method]; ok {
		return json.RawMessage(a), nil
	}
	return json.RawMessage(`{}`), nil
}

func (h *fakeHost) Output(stream Stream, text string) { h.out = append(h.out, string(stream)+":"+text) }
func (h *fakeHost) Log(text string)                   { h.logs = append(h.logs, text) }

func run(t *testing.T, h *fakeHost, ctx Context, src string) (json.RawMessage, error) {
	t.Helper()
	r := New(h, ctx)
	defer r.Close()
	return r.Run(context.Background(), "test.lua", src)
}

func TestReturnsAndPrints(t *testing.T) {
	h := &fakeHost{}
	res, err := run(t, h, Context{}, `print("a", 1, true) return { n = 2, list = { "x", "y" } }`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"list":["x","y"],"n":2}` {
		t.Errorf("result %s", res)
	}
	if len(h.out) != 1 || h.out[0] != "stdout:a\t1\ttrue\n" {
		t.Errorf("output %q", h.out)
	}
}

func TestErrorHasTrace(t *testing.T) {
	h := &fakeHost{}
	_, err := run(t, h, Context{}, "local function f()\n error('boom')\nend\nf()")
	if err == nil {
		t.Fatal("no error")
	}
	msg := err.Error()
	if !strings.HasPrefix(msg, "test.lua:2: boom") || !strings.Contains(msg, "stack traceback") || !strings.Contains(msg, "in function 'f'") {
		t.Errorf("error %q", msg)
	}
	_, err = run(t, h, Context{}, "x = = 1")
	if err == nil || !strings.Contains(err.Error(), "test.lua") {
		t.Errorf("syntax error %v", err)
	}
}

func TestStop(t *testing.T) {
	h := &fakeHost{}
	res, err := run(t, h, Context{}, `slime.stop("early") print("not reached")`)
	if err != nil || string(res) != `"early"` {
		t.Errorf("stop: %s, %v", res, err)
	}
	if len(h.out) != 0 {
		t.Errorf("ran on after stop: %q", h.out)
	}
	res, err = run(t, h, Context{}, `slime.stop()`)
	if err != nil || res != nil {
		t.Errorf("bare stop: %s, %v", res, err)
	}
}

func TestCancel(t *testing.T) {
	r := New(&fakeHost{}, Context{})
	defer r.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	_, err := r.Run(ctx, "loop.lua", `while true do end`)
	if !errors.Is(err, ErrCancelled) {
		t.Errorf("err %v", err)
	}
}

func TestContextAndNamespaces(t *testing.T) {
	h := &fakeHost{answers: map[string]string{
		"pane.split": `{"pane":"1.2.9"}`,
		"pane.text":  `{"text":"hello"}`,
	}}
	ctx := Context{Pane: rpc.PaneID{WS: 1, Tab: 2, N: 3}, Args: json.RawMessage(`{"file":"app.log","n":2}`)}
	res, err := run(t, h, ctx, `
		assert(slime.workspace_id == 1 and slime.tab_id == "1.2" and slime.pane_id == "1.2.3")
		assert(slime.args.file == "app.log" and slime.args.n == 2)
		local p = slime.pane.split{ direction = "down", ratio = 0.3, command = "htop" }
		assert(p.pane == "1.2.9")
		local t = slime.pane.text{ id = p.pane }
		slime.pane.kill{}
		slime.tab.new{ name = "x" }
		slime.tab.rename{ name = "y" }
		slime.workspace.info{}
		slime.workspace.list{}
		slime.workspace.new{ name = "z" }
		slime.workspace.new{ name = "d", attach = false }
		slime.workspace.new{ name = "t", attach = true }
		slime.workspace.new{ name = "e", attach = 5 }
		slime.workspace.focus{}
		slime.workspace.focus{ tab = "1.4" }
		slime.pane_id = "1.2.7"
		slime.pane.info()
		slime.call("host.list")
		slime.call("workspace.focus", { tab = 2 })
		return t.text
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `"hello"` {
		t.Errorf("result %s", res)
	}
	want := []call{
		{"pane.split", `{"command":"htop","direction":"down","pane":"1.2.3","ratio":0.3}`},
		{"pane.text", `{"id":"1.2.9"}`},
		{"pane.kill", `{"id":"1.2.3"}`},
		{"tab.new", `{"name":"x","workspace":1}`},
		{"tab.rename", `{"id":"1.2","name":"y"}`},
		{"workspace.info", `{"id":1}`},
		{"workspace.list", `{}`},
		{"workspace.new", `{"attach":1,"name":"z"}`},
		{"workspace.new", `{"name":"d"}`},
		{"workspace.new", `{"attach":1,"name":"t"}`},
		{"workspace.new", `{"attach":5,"name":"e"}`},
		{"workspace.focus", `{"pane":"1.2.3"}`},
		{"workspace.focus", `{"tab":"1.4"}`},
		{"pane.info", `{"id":"1.2.7"}`},
		{"host.list", ``},
		{"workspace.focus", `{"tab":2}`},
	}
	if len(h.calls) != len(want) {
		t.Fatalf("calls %v", h.calls)
	}
	for i, c := range want {
		if h.calls[i] != c {
			t.Errorf("call %d: %v, want %v", i, h.calls[i], c)
		}
	}
}

// Ids come apart with slime.id.parse and together with slime.id.tab
// and slime.id.pane.
func TestIDs(t *testing.T) {
	res, err := run(t, &fakeHost{}, Context{}, `
		assert(slime.pane_id == nil and slime.tab_id == nil and slime.workspace_id == nil)
		local p = slime.id.parse("1.2.3")
		assert(p.workspace == 1 and p.tab == 2 and p.pane == 3)
		local t = slime.id.parse("4.5")
		assert(t.workspace == 4 and t.tab == 5 and t.pane == nil)
		local w = slime.id.parse(6)
		assert(w.workspace == 6 and w.tab == nil)
		assert(slime.id.tab(1, 2) == "1.2" and slime.id.pane(1, 2, 3) == "1.2.3")
		assert(slime.id.pane(p.workspace, p.tab, p.pane) == "1.2.3")
		for _, bad in ipairs({ "", "0.1.1", "1.2.3.4", "a.b", "1..2", true }) do
			local v, err = slime.id.parse(bad)
			assert(v == nil and err, tostring(bad))
		end
		assert(not pcall(slime.id.pane, 0, 1, 1))
		assert(not pcall(slime.id.tab, 1.5, 1))
		return slime.id.tab(p.workspace, p.tab)
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `"1.2"` {
		t.Errorf("result %s", res)
	}
}

func TestCallErrors(t *testing.T) {
	h := &fakeHost{errs: map[string]*rpc.Error{"pane.kill": rpc.Errorf(rpc.CodeNotFound, "no such pane")}}
	res, err := run(t, h, Context{}, `
		local r, err, code = slime.pane.kill{ id = 5 }
		assert(r == nil and err == "no such pane" and code == 1000)
		local r2, err2 = slime.call("x.y", { f = print })
		return { err2 }
	`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res), "x.y: params: a function can't be JSON") {
		t.Errorf("result %s", res)
	}
}

func TestLayout(t *testing.T) {
	h := &fakeHost{}
	res, err := run(t, h, Context{}, `
		return slime.layout.horizontal(0.7,
			slime.layout.pane{ command = "nvim" },
			slime.layout.vertical(
				slime.layout.pane{ command = "tail", cwd = "/tmp", env = { A = "1" } },
				slime.layout.pane{},
				slime.layout.pane()))
	`)
	if err != nil {
		t.Fatal(err)
	}
	var l rpc.Layout
	if err := json.Unmarshal(res, &l); err != nil {
		t.Fatalf("%v: %s", err, res)
	}
	if err := l.Validate(); err != nil {
		t.Fatal(err)
	}
	if l.Axis != rpc.Row || len(l.Children) != 2 || l.Children[0].Share != 7000 || l.Children[1].Share != 3000 {
		t.Errorf("outer: %+v", l)
	}
	if l.Children[0].Node.Pane.Command != "nvim" {
		t.Errorf("first leaf: %+v", l.Children[0].Node.Pane)
	}
	inner := l.Children[1].Node
	if inner.Axis != rpc.Column || len(inner.Children) != 3 {
		t.Fatalf("inner: %+v", inner)
	}
	for _, c := range inner.Children {
		if c.Share != rpc.Whole/3 && c.Share != rpc.Whole-2*(rpc.Whole/3) {
			t.Errorf("inner share %d", c.Share)
		}
	}
	if p := inner.Children[0].Node.Pane; p.Cwd != "/tmp" || p.Env["A"] != "1" {
		t.Errorf("tail leaf: %+v", p)
	}
	_, err = run(t, h, Context{}, `slime.layout.horizontal(slime.layout.pane{})`)
	if err == nil || !strings.Contains(err.Error(), "at least two children") {
		t.Errorf("one child: %v", err)
	}
	_, err = run(t, h, Context{}, `slime.layout.vertical(1.5, slime.layout.pane{}, slime.layout.pane{})`)
	if err == nil || !strings.Contains(err.Error(), "between 0 and 1") {
		t.Errorf("bad ratio: %v", err)
	}
}

func TestJSON(t *testing.T) {
	h := &fakeHost{}
	res, err := run(t, h, Context{}, `
		local s = slime.json.encode({ a = { 1, 2.5, "x" }, b = {}, c = true, d = { [1] = "one", k = "v" } })
		local v = slime.json.decode('{"n":null,"l":[1,{"x":2}],"s":"t"}')
		assert(v.n == nil and v.l[2].x == 2 and v.s == "t")
		local bad, err = slime.json.decode("{")
		assert(bad == nil and err)
		local cyc = {}
		cyc.self = cyc
		local _, err2 = slime.json.encode(cyc)
		return { s, err2 }
	`)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	if err := json.Unmarshal(res, &out); err != nil {
		t.Fatal(err)
	}
	if out[0] != `{"a":[1,2.5,"x"],"b":{},"c":true,"d":{"1":"one","k":"v"}}` {
		t.Errorf("encode %s", out[0])
	}
	if !strings.Contains(out[1], "contains itself") {
		t.Errorf("cycle %s", out[1])
	}
}

func TestLogAndNoExit(t *testing.T) {
	h := &fakeHost{}
	_, err := run(t, h, Context{}, `slime.log("hi", 2) assert(os.exit == nil) assert(io == nil)`)
	if err != nil {
		t.Fatal(err)
	}
	if len(h.logs) != 1 || h.logs[0] != "hi\t2" {
		t.Errorf("logs %q", h.logs)
	}
}
