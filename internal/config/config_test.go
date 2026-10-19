package config

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aldehir/slime/internal/lua"
	"github.com/aldehir/slime/internal/rpc"
)

// fakeHost answers every call with {} and keeps what was logged.
type fakeHost struct {
	calls []string
	logs  []string
}

func (h *fakeHost) Call(method string, params json.RawMessage) (json.RawMessage, error) {
	h.calls = append(h.calls, method+" "+string(params))
	if method == "pane.info" {
		return json.RawMessage(`{"id":"1.2.3","command":"pwsh"}`), nil
	}
	return json.RawMessage(`{}`), nil
}

func (h *fakeHost) Log(text string) { h.logs = append(h.logs, text) }

// write puts files in a config directory and returns init.lua's path.
func write(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(dir, "init.lua")
}

func load(t *testing.T, h *fakeHost, files map[string]string) *Config {
	t.Helper()
	var out []string
	c, errs := Load(h, write(t, files), func(stream lua.Stream, text string) { out = append(out, string(stream)+":"+text) })
	if errs != nil {
		t.Fatalf("load: %s", strings.Join(errs, "\n"))
	}
	t.Cleanup(c.Close)
	return c
}

func TestPath(t *testing.T) {
	t.Setenv("SLIME_CONFIG", `C:\elsewhere\init.lua`)
	if got := Path(); got != `C:\elsewhere\init.lua` {
		t.Errorf("Path %q", got)
	}
	t.Setenv("SLIME_CONFIG", "")
	if got := Path(); !strings.HasSuffix(got, filepath.Join("slime", "init.lua")) {
		t.Errorf("Path %q", got)
	}
}

func TestMissingFileIsEmpty(t *testing.T) {
	c, errs := Load(&fakeHost{}, filepath.Join(t.TempDir(), "init.lua"), nil)
	if errs != nil {
		t.Fatal(errs)
	}
	defer c.Close()
	d := c.Desc()
	if string(d.Settings) != "{}" || len(d.Keymap) != 0 || len(d.Actions) != 0 || c.Shell() != "" {
		t.Errorf("desc %+v", d)
	}
	b, _ := json.Marshal(d)
	if string(b) != `{"path":"`+strings.ReplaceAll(c.Path(), `\`, `\\`)+`","settings":{},"keymap":[],"actions":[]}` {
		t.Errorf("json %s", b)
	}
}

func TestSettingsAndBindings(t *testing.T) {
	h := &fakeHost{}
	c := load(t, h, map[string]string{"init.lua": `
		slime.config{ font = { family = { "Cascadia Code", "Consolas" }, size = 12 }, shell = { command = "pwsh" } }
		slime.config{ font = { size = 14, antialias = "grayscale" }, theme = "catppuccin-mocha" }
		slime.config{ font = { family = { "Consolas" } } }
		slime.bind("Ctrl + Shift + D", "new_split", { direction = "right" })
		slime.bind("ctrl+shift+t", "new_tab")
		slime.bind("ctrl+shift+t", "dev", { file = "a" })
		slime.bind("ctrl+alt+l", function(ctx, args) return ctx end)
		slime.unbind("ctrl+shift+w")
		-- A sequence is a key of its own: unbinding its first key leaves it.
		slime.bind("Ctrl+B > c", "new_tab")
		slime.unbind("ctrl+b")
		slime.action{ name = "dev", title = "Dev layout", args = { file = "string" }, run = function(ctx, args) return args end }
		slime.action{ name = "dev", title = "Dev again", run = function(ctx, args) return "again" end }
		slime.action{ name = "other", run = function() end }
		print("loaded")
	`})
	d := c.Desc()
	if string(d.Settings) != `{"font":{"antialias":"grayscale","family":["Consolas"],"size":14},"shell":{"command":"pwsh"},"theme":"catppuccin-mocha"}` {
		t.Errorf("settings %s", d.Settings)
	}
	if c.Shell() != "pwsh" {
		t.Errorf("shell %q", c.Shell())
	}
	want := []rpc.Binding{
		{Key: "ctrl+shift+d", Action: "new_split", Args: json.RawMessage(`{"direction":"right"}`)},
		{Key: "ctrl+shift+t", Action: "dev", Args: json.RawMessage(`{"file":"a"}`)},
		{Key: "ctrl+alt+l", Lua: 1},
		{Key: "ctrl+shift+w"},
		{Key: "ctrl+b>c", Action: "new_tab"},
		{Key: "ctrl+b"},
	}
	if got, _ := json.Marshal(d.Keymap); string(got) != string(mustJSON(want)) {
		t.Errorf("keymap %s", got)
	}
	if len(d.Actions) != 2 || d.Actions[0].Name != "dev" || d.Actions[0].Title != "Dev again" || d.Actions[0].Args != nil || d.Actions[1].Name != "other" {
		t.Errorf("actions %s", mustJSON(d.Actions))
	}
	if len(h.logs) != 0 {
		t.Errorf("logged %q", h.logs)
	}
	// The replaced action runs its new function.
	res, err := c.Run(context.Background(), Invocation{Name: "dev"}, nil)
	if err != nil || string(res) != `"again"` {
		t.Errorf("run dev: %s, %v", res, err)
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

func TestInvoke(t *testing.T) {
	h := &fakeHost{}
	c := load(t, h, map[string]string{"init.lua": `
		slime.action{ name = "dev", args = { file = "string", n = "number", on = "boolean" },
			run = function(ctx, args)
				print("dev", ctx.origin, ctx.pane_id, ctx.tab_id, ctx.workspace_id)
				assert(slime.pane_id == ctx.pane_id)
				local me = slime.pane.info{}
				slime.log("info", me.id)
				return { args = args, ids = { slime.workspace_id, slime.tab_id, slime.pane_id }, info = me }
			end }
		slime.action{ name = "outer", run = function(ctx, args)
			local r = assert(slime.invoke("dev", { file = "x", n = 2 }))
			return { inner = r, origin = ctx.origin }
		end }
		slime.action{ name = "fails", run = function() error("boom") end }
		slime.action{ name = "stops", run = function() slime.stop("early") error("not reached") end }
		slime.bind("ctrl+x", function(ctx, args) return { bound = true, pane = ctx.pane_id } end)
	`})
	var out []string
	collect := func(stream lua.Stream, text string) { out = append(out, string(stream)+":"+text) }

	res, err := c.Run(context.Background(), Invocation{Name: "dev", Args: json.RawMessage(`{"file":"app.log","n":"3","on":"true","extra":"x"}`), Pane: rpc.PaneID{WS: 1, Tab: 2, N: 3}, Origin: OriginCLI}, collect)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"args":{"extra":"x","file":"app.log","n":3,"on":true},"ids":[1,"1.2","1.2.3"],"info":{"command":"pwsh","id":"1.2.3"}}` {
		t.Errorf("result %s", res)
	}
	if strings.Join(out, "|") != "stdout:dev\tcli\t1.2.3\t1.2\t1\n|stderr:info\t1.2.3\n" {
		t.Errorf("output %q", out)
	}
	if len(h.calls) != 1 || h.calls[0] != `pane.info {"id":"1.2.3"}` || len(h.logs) != 1 || h.logs[0] != "info\t1.2.3" {
		t.Errorf("calls %q, logs %q", h.calls, h.logs)
	}
	// The ids were restored after.
	if ids := c.r.IDs(); ids.Pane.String() != "nil" {
		t.Errorf("pane_id after: %s", ids.Pane)
	}

	// Without a pane, and nested: the inner call sees the outer's pane
	// (none) and origin script.
	out = nil
	res, err = c.Run(context.Background(), Invocation{Name: "outer"}, collect)
	if err != nil {
		t.Fatal(err)
	}
	// (ids is a table of nils: empty, so an object.)
	if string(res) != `{"inner":{"args":{"file":"x","n":2},"ids":{},"info":{"command":"pwsh","id":"1.2.3"}},"origin":"api"}` {
		t.Errorf("nested %s", res)
	}
	if len(out) != 2 || out[0] != "stdout:dev\tscript\tnil\tnil\tnil\n" {
		t.Errorf("nested output %q", out)
	}

	// A bound function, by id.
	res, err = c.Run(context.Background(), Invocation{Lua: 1, Pane: rpc.PaneID{WS: 4, Tab: 1, N: 1}, Origin: OriginKey}, nil)
	if err != nil || string(res) != `{"bound":true,"pane":"4.1.1"}` {
		t.Errorf("binding: %s, %v", res, err)
	}

	// What can't run, and what fails.
	var rerr *rpc.Error
	if _, err := c.Run(context.Background(), Invocation{Name: "nope"}, nil); !errors.As(err, &rerr) || rerr.Code != rpc.CodeNotFound {
		t.Errorf("no action: %v", err)
	}
	if _, err := c.Run(context.Background(), Invocation{Lua: 9}, nil); !errors.As(err, &rerr) || rerr.Code != rpc.CodeNotFound {
		t.Errorf("no binding: %v", err)
	}
	if _, err := c.Run(context.Background(), Invocation{Name: "dev", Args: json.RawMessage(`{"n":"x"}`)}, nil); !errors.As(err, &rerr) || rerr.Code != rpc.CodeInvalidParams || !strings.Contains(rerr.Message, "argument n") {
		t.Errorf("bad number: %v", err)
	}
	if _, err := c.Run(context.Background(), Invocation{Name: "fails"}, nil); err == nil || !strings.HasPrefix(err.Error(), "init.lua:") || !strings.Contains(err.Error(), "boom") {
		t.Errorf("fails: %v", err)
	}
	if res, err := c.Run(context.Background(), Invocation{Name: "stops"}, nil); err != nil || string(res) != `"early"` {
		t.Errorf("stops: %s, %v", res, err)
	}
	// The state is still good after the failures.
	if res, err := c.Run(context.Background(), Invocation{Lua: 1}, nil); err != nil || string(res) != `{"bound":true}` {
		t.Errorf("after failures: %s, %v", res, err)
	}
}

func TestCancel(t *testing.T) {
	c := load(t, &fakeHost{}, map[string]string{"init.lua": `slime.action{ name = "loop", run = function() while true do end end }`})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Run(ctx, Invocation{Name: "loop"}, nil); !errors.Is(err, lua.ErrCancelled) {
		t.Errorf("err %v", err)
	}
	// Usable after.
	c2 := load(t, &fakeHost{}, map[string]string{"init.lua": `slime.action{ name = "n", run = function() return 1 end }`})
	if res, err := c2.Run(context.Background(), Invocation{Name: "n"}, nil); err != nil || string(res) != "1" {
		t.Errorf("after: %s, %v", res, err)
	}
}

func TestSiblingsAndErrors(t *testing.T) {
	h := &fakeHost{}
	c := load(t, h, map[string]string{
		"init.lua": `
			local lib = require("lib")
			slime.action{ name = "dev", run = function() return dofile("dev.lua") end }
			slime.config{ n = lib.n }
			local f, err = loadfile("missing.lua")
			assert(f == nil and err)
		`,
		"lib.lua": `return { n = 7 }`,
		"dev.lua": `return "from dev.lua"`,
	})
	if string(c.Desc().Settings) != `{"n":7}` {
		t.Errorf("settings %s", c.Desc().Settings)
	}
	if res, err := c.Run(context.Background(), Invocation{Name: "dev"}, nil); err != nil || string(res) != `"from dev.lua"` {
		t.Errorf("dofile: %s, %v", res, err)
	}

	for name, src := range map[string]string{
		"syntax":    "x = = 1",
		"runtime":   "error('no')",
		"bad bind":  "slime.bind('', 'x')",
		"bad bind2": "slime.bind('a', 1)",
		"no name":   "slime.action{ run = function() end }",
		"no run":    "slime.action{ name = 'x' }",
		"not json":  "slime.config{ f = print }",
	} {
		_, errs := Load(h, write(t, map[string]string{"init.lua": src}), nil)
		if len(errs) != 1 || !strings.Contains(errs[0], "init.lua") {
			t.Errorf("%s: errors %q", name, errs)
		}
	}
	// Binding and the rest are for the file's top level: an action
	// invoked while it runs may still, one invoked later may not.
	late := load(t, h, map[string]string{"init.lua": `
		slime.action{ name = "x", run = function() slime.bind("a", "b") end }
		slime.action{ name = "y", run = function() slime.config{ late = true } end }
		slime.invoke("x")
	`})
	if len(late.Desc().Keymap) != 1 {
		t.Errorf("bound while loading: %s", mustJSON(late.Desc().Keymap))
	}
	for _, name := range []string{"x", "y"} {
		if _, err := late.Run(context.Background(), Invocation{Name: name}, nil); err == nil || !strings.Contains(err.Error(), "top level") {
			t.Errorf("%s after loading: %v", name, err)
		}
	}
	// What a failing file printed went to the log, not nowhere.
	h = &fakeHost{}
	if _, errs := Load(h, write(t, map[string]string{"init.lua": "print('hi') error('x')"}), nil); errs == nil || len(h.logs) != 1 || h.logs[0] != "hi" {
		t.Errorf("errs %q, logs %q", errs, h.logs)
	}
}
