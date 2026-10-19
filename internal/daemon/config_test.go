package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
)

// newConfigHarness is newHarness with init.lua holding source.
func newConfigHarness(t *testing.T, source string) (*harness, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "init.lua")
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t}
	srv, err := NewServer(runtime(t), Options{Config: path, Spawn: func(o pty.Options) (pty.Pty, error) {
		p := newFakePty(o)
		h.mu.Lock()
		h.ptys = append(h.ptys, p)
		h.opts = append(h.opts, o)
		h.mu.Unlock()
		return p, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	h.srv = srv
	t.Cleanup(srv.Close)
	return h, path
}

func configGet(t *testing.T, c *Client) rpc.ConfigDesc {
	t.Helper()
	var d rpc.ConfigDesc
	if err := c.Call(rpc.ConfigGet, nil, &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestConfigLoadsAtStart(t *testing.T) {
	h, path := newConfigHarness(t, `
		slime.config{ shell = { command = "pwsh -NoLogo" }, font = { size = 13 } }
		slime.bind("ctrl+shift+d", "new_split", { direction = "right" })
		slime.action{ name = "hello", title = "Say hello", args = { who = "string" },
			run = function(ctx, args)
				print("hello " .. (args.who or "nobody") .. " from " .. ctx.origin)
				local t = assert(slime.tab.new{ workspace = slime.workspace_id or 1 })
				return { pane = t.pane, ws = slime.workspace_id }
			end }
	`)
	c := h.connect()
	d := configGet(t, c)
	if d.Path != path || string(d.Settings) != `{"font":{"size":13},"shell":{"command":"pwsh -NoLogo"}}` || len(d.Keymap) != 1 || len(d.Actions) != 1 || d.Errors != nil {
		t.Errorf("config %s", mustJSON(d))
	}
	if d.Actions[0].Name != "hello" || d.Actions[0].Title != "Say hello" || string(d.Actions[0].Args) != `{"who":"string"}` {
		t.Errorf("action %+v", d.Actions[0])
	}

	// The configured shell is what a pane without a command runs, and
	// what it's described as.
	w := h.window()
	pane := w.newWorkspace()
	if got := h.spawned(0).Command; got != "pwsh -NoLogo" {
		t.Errorf("spawned %q", got)
	}
	var info rpc.PaneDesc
	if err := c.Call(rpc.PaneInfo, rpc.PaneParams{ID: pane}, &info); err != nil || info.Command != "pwsh -NoLogo" {
		t.Errorf("info %+v, %v", info, err)
	}

	// The action runs as a script would, for the pane it's invoked for.
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "hello", Args: json.RawMessage(`{"who":"you"}`), Pane: pane, Origin: "cli"}, &started); err != nil {
		t.Fatal(err)
	}
	out, done := followScript(t, c, started.ID)
	if !done.OK {
		t.Fatalf("action failed: %s", done.Error)
	}
	var res struct {
		Pane string
		Ws   uint32
	}
	json.Unmarshal(done.Result, &res)
	if res.Ws != w.ws.ID || !strings.HasPrefix(res.Pane, strconv.Itoa(int(pane.WS))+".") {
		t.Errorf("result %s", done.Result)
	}
	if len(out) != 1 || out[0].Data != "hello you from cli\n" {
		t.Errorf("output %+v", out)
	}
	if got := h.spawned(1).Command; got != "pwsh -NoLogo" {
		t.Errorf("action's tab spawned %q", got)
	}

	// What can't be invoked.
	for _, p := range []rpc.ActionInvokeParams{{}, {Name: "nope"}, {Lua: 7}, {Name: "hello", Args: json.RawMessage(`[1]`)}, {Name: "hello", Pane: PaneID{WS: 9, Tab: 1, N: 1}}} {
		if err := c.Call(rpc.ActionInvoke, p, nil); err == nil {
			t.Errorf("%+v: no error", p)
		}
	}
	waitScripts(t, c, 0)
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func TestConfigReloadAndCheck(t *testing.T) {
	h, path := newConfigHarness(t, `
		slime.config{ shell = { command = "one" } }
		slime.action{ name = "which", run = function() return "one" end }
	`)
	c := h.connect()
	sub := h.connect()
	if err := sub.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"config.*"}}, nil); err != nil {
		t.Fatal(err)
	}

	// A broken file: the reply and config.changed carry the error, and
	// the old config stays.
	if err := os.WriteFile(path, []byte("slime.config{ shell = { command = \"two\" } }\nerror(\"nope\")"), 0o600); err != nil {
		t.Fatal(err)
	}
	var d rpc.ConfigDesc
	if err := c.Call(rpc.ConfigReload, nil, &d); err != nil {
		t.Fatal(err)
	}
	if len(d.Errors) != 1 || !strings.Contains(d.Errors[0], "init.lua:") || string(d.Settings) != `{"shell":{"command":"one"}}` {
		t.Errorf("failed reload: %s", mustJSON(d))
	}
	var changed rpc.ConfigDesc
	json.Unmarshal(nextNotification(t, sub, rpc.EvConfigChanged), &changed)
	if len(changed.Errors) != 1 || string(changed.Settings) != string(d.Settings) {
		t.Errorf("config.changed %s", mustJSON(changed))
	}
	if got := configGet(t, c); len(got.Errors) != 1 || string(got.Settings) != string(d.Settings) {
		t.Errorf("get after failure: %s", mustJSON(got))
	}
	_, done := invoke(t, c, rpc.ActionInvokeParams{Name: "which"})
	if !done.OK || string(done.Result) != `"one"` {
		t.Errorf("old action: %+v", done)
	}

	// A good file replaces it, and the errors clear.
	good := `slime.config{ shell = { command = "two" } }
		slime.action{ name = "which", run = function() return "two" end }
		slime.bind("ctrl+a", function() end)`
	if err := os.WriteFile(path, []byte(good), 0o600); err != nil {
		t.Fatal(err)
	}
	d = rpc.ConfigDesc{}
	if err := c.Call(rpc.ConfigReload, nil, &d); err != nil {
		t.Fatal(err)
	}
	if d.Errors != nil || string(d.Settings) != `{"shell":{"command":"two"}}` || len(d.Keymap) != 1 || d.Keymap[0].Lua != 1 {
		t.Errorf("reload: %s", mustJSON(d))
	}
	changed = rpc.ConfigDesc{}
	json.Unmarshal(nextNotification(t, sub, rpc.EvConfigChanged), &changed)
	if changed.Errors != nil || string(changed.Settings) != string(d.Settings) {
		t.Errorf("config.changed %s", mustJSON(changed))
	}
	_, done = invoke(t, c, rpc.ActionInvokeParams{Name: "which"})
	if !done.OK || string(done.Result) != `"two"` {
		t.Errorf("new action: %+v", done)
	}
	w := h.window()
	w.newWorkspace()
	if got := h.spawned(0).Command; got != "two" {
		t.Errorf("spawned %q", got)
	}

	// check evaluates another file without keeping it.
	other := filepath.Join(filepath.Dir(path), "other.lua")
	os.WriteFile(other, []byte(`slime.config{ shell = { command = "three" } } slime.action{ name = "x", run = print }`), 0o600)
	d = rpc.ConfigDesc{}
	if err := c.Call(rpc.ConfigCheck, rpc.ConfigCheckParams{Path: other}, &d); err != nil {
		t.Fatal(err)
	}
	if d.Path != other || d.Errors != nil || string(d.Settings) != `{"shell":{"command":"three"}}` || len(d.Actions) != 1 {
		t.Errorf("check: %s", mustJSON(d))
	}
	if got := configGet(t, c); string(got.Settings) != `{"shell":{"command":"two"}}` {
		t.Errorf("check applied? %s", mustJSON(got))
	}
	os.WriteFile(other, []byte(`x = = 1`), 0o600)
	if err := c.Call(rpc.ConfigCheck, rpc.ConfigCheckParams{Path: other}, &d); err != nil || len(d.Errors) != 1 {
		t.Errorf("check bad: %s, %v", mustJSON(d), err)
	}
}

// invoke runs an action over c and follows it to its end.
func invoke(t *testing.T, c *Client, p rpc.ActionInvokeParams) ([]rpc.ScriptOutputParams, rpc.ScriptDoneParams) {
	t.Helper()
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ActionInvoke, p, &started); err != nil {
		t.Fatal(err)
	}
	return followScript(t, c, started.ID)
}

func TestScriptInvokesAction(t *testing.T) {
	h, _ := newConfigHarness(t, `
		slime.action{ name = "where", args = { n = "number" }, run = function(ctx, args)
			print("in action", ctx.origin, ctx.pane_id)
			return { pane = slime.pane_id, n = args.n * 2 }
		end }
	`)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	out, done := runScript(t, c, rpc.ScriptRunParams{Pane: pane, Source: `
		local r = assert(slime.invoke("where", { n = "21" }))
		local _, err, code = slime.invoke("nope")
		return { r = r, code = code, err = err }
	`})
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	want := `{"code":1000,"err":"no action \"nope\"","r":{"n":42,"pane":"` + pane.String() + `"}}`
	if string(done.Result) != want {
		t.Errorf("result %s", done.Result)
	}
	// The action's output came as the script's.
	if len(out) != 1 || out[0].Data != "in action\tscript\t"+pane.String()+"\n" {
		t.Errorf("output %+v", out)
	}

	// With no config loaded at all, there are no actions.
	h2 := newHarness(t)
	c2 := h2.connect()
	if err := c2.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "where"}, nil); err == nil {
		t.Error("no config: no error")
	}
	if d := configGet(t, c2); d.Path != "" || string(d.Settings) != "{}" || len(d.Keymap) != 0 {
		t.Errorf("no config: %s", mustJSON(d))
	}
	if err := c2.Call(rpc.ConfigReload, nil, nil); err != nil {
		t.Errorf("reload with no path: %v", err)
	}
}

func TestConfigCancelOnHangup(t *testing.T) {
	h, _ := newConfigHarness(t, `slime.action{ name = "loop", run = function() while true do end end }`)
	other := h.connect()
	c := h.connect()
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "loop"}, &started); err != nil {
		t.Fatal(err)
	}
	if l := scripts(t, other); len(l) != 1 || l[0].Name != "loop" {
		t.Errorf("list %+v", l)
	}
	c.Close()
	waitScripts(t, other, 0)
	// The state is good after a cancel: a second run is cancelled too,
	// by the method this time.
	if err := other.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "loop"}, &started); err != nil {
		t.Fatal(err)
	}
	if err := other.Call(rpc.ScriptCancel, rpc.ScriptParams{ID: started.ID}, nil); err != nil {
		t.Fatal(err)
	}
	if _, done := followScript(t, other, started.ID); done.OK || done.Error != "cancelled" {
		t.Errorf("done %+v", done)
	}
}

// TestConfigWatch: a change to init.lua, or to a module beside it, is
// reloaded by itself once the files hold still, config.changed and all;
// a broken file reports its errors and keeps the config.
func TestConfigWatch(t *testing.T) {
	h, path := newConfigHarness(t, `slime.config{ shell = { command = "one" } }`)
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	h.srv.watchConfig(10*time.Millisecond, stop)
	sub := h.connect()
	if err := sub.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"config.*"}}, nil); err != nil {
		t.Fatal(err)
	}

	mod := filepath.Join(filepath.Dir(path), "mod.lua")
	if err := os.WriteFile(mod, []byte(`return "two"`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`slime.config{ shell = { command = require("mod") } }`), 0o600); err != nil {
		t.Fatal(err)
	}
	var changed rpc.ConfigDesc
	json.Unmarshal(nextNotification(t, sub, rpc.EvConfigChanged), &changed)
	if changed.Errors != nil || string(changed.Settings) != `{"shell":{"command":"two"}}` {
		t.Errorf("after editing init.lua: %s", mustJSON(changed))
	}

	// The module alone.
	if err := os.WriteFile(mod, []byte(`return "three"`), 0o600); err != nil {
		t.Fatal(err)
	}
	changed = rpc.ConfigDesc{}
	json.Unmarshal(nextNotification(t, sub, rpc.EvConfigChanged), &changed)
	if changed.Errors != nil || string(changed.Settings) != `{"shell":{"command":"three"}}` {
		t.Errorf("after editing mod.lua: %s", mustJSON(changed))
	}

	// A broken file: the errors go out, and the config stays.
	if err := os.WriteFile(path, []byte(`error("nope")`), 0o600); err != nil {
		t.Fatal(err)
	}
	changed = rpc.ConfigDesc{}
	json.Unmarshal(nextNotification(t, sub, rpc.EvConfigChanged), &changed)
	if len(changed.Errors) != 1 || !strings.Contains(changed.Errors[0], "nope") || string(changed.Settings) != `{"shell":{"command":"three"}}` {
		t.Errorf("after breaking init.lua: %s", mustJSON(changed))
	}
}
