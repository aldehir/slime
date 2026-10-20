// Package config evaluates init.lua, the daemon's configuration: one
// Lua state (internal/lua) that lives as long as the Config does, in
// which slime.config sets the settings clients read, slime.bind the key
// bindings, and slime.action the actions, each a function the file
// leaves in the state for the daemon to call again (Run) whenever a
// window, the CLI, or a script invokes it.
//
// A Config is immutable once loaded: bind, action, and config are for
// the file's top level, so what Desc describes is settled when Load
// returns, and a reload is a new Config.
package config

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/lua"
	"github.com/aldehir/slime/internal/rpc"
)

// Path is the config file: SLIME_CONFIG, else init.lua in %APPDATA%\slime
// on Windows and in $XDG_CONFIG_HOME/slime (~/.config/slime) elsewhere.
// Empty if none of those is set.
func Path() string {
	if p := os.Getenv("SLIME_CONFIG"); p != "" {
		return p
	}
	var base string
	if runtime.GOOS == "windows" {
		base = os.Getenv("APPDATA")
	} else if base = os.Getenv("XDG_CONFIG_HOME"); base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, ".config")
		}
	}
	if base == "" {
		return ""
	}
	return filepath.Join(base, "slime", "init.lua")
}

// Host is the daemon a config runs in: the control plane and the log.
type Host interface {
	Call(method string, params json.RawMessage) (json.RawMessage, error)
	Log(text string)
}

// Output takes what an evaluation or an invocation prints: print to
// stdout, slime.log to stderr.
type Output = lua.Output

// Timeout bounds an evaluation: a file that never returns fails.
const Timeout = 30 * time.Second

// Origins of an invocation, as its ctx.origin says.
const (
	OriginKey    = "key"
	OriginCLI    = "cli"
	OriginScript = "script"
	OriginAPI    = "api"
)

// Config is one evaluation of the file: its state, and what it set.
type Config struct {
	path string
	host Host
	r    *lua.Runner
	// loading is set while the file's top level runs: when bind,
	// action, and config are allowed, and out takes what it prints
	// (nil: the daemon's log, through host).
	loading bool
	out     Output

	settings *glua.LTable
	bindings []*rpc.Binding
	actions  []*action
	byName   map[string]*action
	// funcs keeps the functions bindings run (by the id the binding is
	// known by on the wire) and actions run (by name) alive.
	funcs    *glua.LTable
	nextFunc uint32
	desc     rpc.ConfigDesc
}

// action is one slime.action: its spec as given, and run.
type action struct {
	desc rpc.ActionDesc
	spec *glua.LTable
	run  *glua.LFunction
}

// Load evaluates the file at path in a new state for host, with what
// it prints going to out (nil for the log). A file that isn't there
// loads as empty. A file that fails to load leaves no Config, only the
// reasons; Load never returns both.
func Load(host Host, path string, out Output) (*Config, []string) {
	c := &Config{path: path, host: host, out: out, byName: map[string]*action{}}
	c.r = lua.New(c, lua.Context{Persistent: true})
	L := c.r.L
	c.settings = L.NewTable()
	c.funcs = L.NewTable()
	c.install()
	source, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		c.Close()
		return nil, []string{err.Error()}
	}
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), Timeout)
		defer cancel()
		c.loading = true
		_, err = c.r.Run(ctx, filepath.Base(path), string(source))
		c.loading = false
		if err != nil {
			c.Close()
			if errors.Is(err, lua.ErrCancelled) {
				err = fmt.Errorf("%s: gave up after %s", filepath.Base(path), Timeout)
			}
			return nil, []string{err.Error()}
		}
	}
	c.out = nil
	c.describe()
	return c, nil
}

// Close ends the config: what runs in it is cancelled, its hooks and
// timers stop, the processes it started are killed, and the state is
// freed.
func (c *Config) Close() { c.r.Close() }

// Deliver gives the config's hooks an event (slime.on). It never
// blocks: the daemon calls it under its lock.
func (c *Config) Deliver(name string, params json.RawMessage) { c.r.Deliver(name, params) }

// Path is the file this came from.
func (c *Config) Path() string { return c.path }

// Desc describes what the file set, for config.get and config.changed.
func (c *Config) Desc() rpc.ConfigDesc { return c.desc }

// describe builds Desc once the file has run.
func (c *Config) describe() {
	settings, err := lua.ToJSON(c.settings)
	if err != nil || string(settings) == "null" {
		settings = json.RawMessage("{}")
	}
	d := rpc.ConfigDesc{Path: c.path, Settings: settings, Keymap: []rpc.Binding{}, Actions: []rpc.ActionDesc{}}
	for _, b := range c.bindings {
		d.Keymap = append(d.Keymap, *b)
	}
	for _, a := range c.actions {
		d.Actions = append(d.Actions, a.desc)
	}
	c.desc = d
}

// Shell is settings.shell.command: what a pane runs when nothing says.
func (c *Config) Shell() string {
	if shell, ok := c.settings.RawGetString("shell").(*glua.LTable); ok {
		if cmd, ok := shell.RawGetString("command").(glua.LString); ok {
			return string(cmd)
		}
	}
	return ""
}

// HostProxy is settings.host.proxy: whether the daemon runs a SOCKS
// proxy over each host's connection. On unless set false.
func (c *Config) HostProxy() bool {
	if host, ok := c.settings.RawGetString("host").(*glua.LTable); ok {
		return host.RawGetString("proxy") != glua.LFalse
	}
	return true
}

// Invocation says what to run: the action Name with Args (a JSON
// object), or the function binding Lua; for Pane (none if zero); from
// Origin.
type Invocation struct {
	Name   string
	Lua    uint32
	Args   json.RawMessage
	Pane   rpc.PaneID
	Origin string
}

// Run invokes an action or a bound function and returns what it
// returned, with its output going to out. Invocations are tasks of
// the config's run: one runs Lua at a time, and one that blocks
// (slime.sleep, wait, exec) lets the others run meanwhile. The error
// is an *rpc.Error for an invocation that can't start, or the Lua
// error that ended it, or lua.ErrCancelled.
func (c *Config) Run(ctx context.Context, inv Invocation, out Output) (json.RawMessage, error) {
	fn, args, err := c.prepare(inv)
	if err != nil {
		return nil, err
	}
	origin := inv.Origin
	if origin == "" {
		origin = OriginAPI
	}
	return c.r.Call(ctx, lua.CallOptions{Pane: inv.Pane, Out: out}, fn, c.ctxTable(lua.IDsOf(inv.Pane), origin), args)
}

// Check says whether inv names something to run: the *rpc.Error Run
// would fail with before running anything, or nil.
func (c *Config) Check(inv Invocation) error {
	_, _, err := c.find(inv)
	return err
}

// find is the function inv names, and its action if it's one.
func (c *Config) find(inv Invocation) (*glua.LFunction, *action, error) {
	switch {
	case inv.Name != "":
		act := c.byName[inv.Name]
		if act == nil {
			return nil, nil, rpc.Errorf(rpc.CodeNotFound, "no action %q", inv.Name)
		}
		return act.run, act, nil
	case inv.Lua != 0:
		fn, ok := c.funcs.RawGetInt(int(inv.Lua)).(*glua.LFunction)
		if !ok {
			return nil, nil, rpc.Errorf(rpc.CodeNotFound, "no function binding %d (reloaded?)", inv.Lua)
		}
		return fn, nil, nil
	}
	return nil, nil, rpc.Errorf(rpc.CodeInvalidParams, "an action's name or a binding's id is needed")
}

// prepare finds what inv names and builds its args table, converted
// by the action's spec.
func (c *Config) prepare(inv Invocation) (*glua.LFunction, *glua.LTable, error) {
	L := c.r.L
	fn, act, err := c.find(inv)
	if err != nil {
		return nil, nil, err
	}
	args := L.NewTable()
	if len(inv.Args) > 0 {
		v, err := lua.FromJSON(L, inv.Args)
		if err != nil {
			return nil, nil, rpc.Errorf(rpc.CodeInvalidParams, "args: %v", err)
		}
		if t, ok := v.(*glua.LTable); ok {
			args = t
		} else if v != glua.LNil {
			return nil, nil, rpc.Errorf(rpc.CodeInvalidParams, "args must be an object")
		}
	}
	if act != nil {
		if err := coerce(args, act.spec); err != nil {
			return nil, nil, rpc.Errorf(rpc.CodeInvalidParams, "%s: %v", inv.Name, err)
		}
	}
	return fn, args, nil
}

// ctxTable is an invocation's ctx: what it runs for, and who asked.
func (c *Config) ctxTable(ids lua.IDs, origin string) *glua.LTable {
	t := c.r.L.NewTable()
	t.RawSetString("workspace_id", ids.Workspace)
	t.RawSetString("tab_id", ids.Tab)
	t.RawSetString("pane_id", ids.Pane)
	t.RawSetString("origin", glua.LString(origin))
	return t
}

// coerce converts args that came as strings (the CLI's key=value) to
// what spec says they are: "number" or "boolean"; anything else stays.
func coerce(args, spec *glua.LTable) error {
	if spec == nil {
		return nil
	}
	var err error
	spec.ForEach(func(k, kind glua.LValue) {
		if err != nil {
			return
		}
		s, ok := args.RawGet(k).(glua.LString)
		if !ok {
			return
		}
		switch kind {
		case glua.LString("number"):
			n, e := strconv.ParseFloat(string(s), 64)
			if e != nil {
				err = fmt.Errorf("argument %s: %q isn't a number", k, s)
				return
			}
			args.RawSet(k, glua.LNumber(n))
		case glua.LString("boolean"):
			switch s {
			case "true", "yes", "1":
				args.RawSet(k, glua.LTrue)
			case "false", "no", "0":
				args.RawSet(k, glua.LFalse)
			default:
				err = fmt.Errorf("argument %s: %q isn't true or false", k, s)
			}
		}
	})
	return err
}

// The config is its runner's host: calls go to the daemon; output
// from a task with no console of its own (the file loading, a hook, a
// timer) goes to the log.

func (c *Config) Call(method string, params json.RawMessage) (json.RawMessage, error) {
	return c.host.Call(method, params)
}

func (c *Config) Output(stream lua.Stream, text string) {
	if c.loading && c.out != nil {
		c.out(stream, text)
		return
	}
	c.host.Log(strings.TrimRight(text, "\n"))
}

func (c *Config) Log(text string) { c.host.Log(text) }

// Invoke is slime.invoke from the file's own functions: the action runs
// here and now, nested in the one running, for the same pane.
func (c *Config) Invoke(name string, args json.RawMessage) (json.RawMessage, error) {
	inv := Invocation{Name: name, Args: args, Origin: OriginScript}
	fn, argsT, err := c.prepare(inv)
	if err != nil {
		return nil, err
	}
	return c.r.CallNested(fn, c.ctxTable(c.r.IDs(), inv.Origin), argsT)
}

// install adds the file's functions to the slime table, and makes
// require, dofile, and loadfile find files beside it.
func (c *Config) install() {
	L := c.r.L
	dir := filepath.Dir(c.path)
	if pkg, ok := L.GetGlobal(glua.LoadLibName).(*glua.LTable); ok {
		pkg.RawSetString("path", glua.LString(filepath.Join(dir, "?.lua")+";"+filepath.Join(dir, "?", "init.lua")))
	}
	L.SetGlobal("dofile", L.NewFunction(func(L *glua.LState) int {
		fn, err := L.LoadFile(c.resolve(L.CheckString(1)))
		if err != nil {
			L.RaiseError("%s", err.Error())
		}
		top := L.GetTop()
		L.Push(fn)
		L.Call(0, glua.MultRet)
		return L.GetTop() - top
	}))
	L.SetGlobal("loadfile", L.NewFunction(func(L *glua.LState) int {
		fn, err := L.LoadFile(c.resolve(L.CheckString(1)))
		if err != nil {
			L.Push(glua.LNil)
			L.Push(glua.LString(err.Error()))
			return 2
		}
		L.Push(fn)
		return 1
	}))
	c.r.Define("config", c.luaConfig)
	c.r.Define("bind", c.luaBind)
	c.r.Define("unbind", c.luaUnbind)
	c.r.Define("action", c.luaAction)
}

// resolve is a file named in the config, relative to its directory.
func (c *Config) resolve(name string) string {
	if filepath.IsAbs(name) {
		return name
	}
	return filepath.Join(filepath.Dir(c.path), name)
}

// topLevel raises an error unless the file's top level is running: the
// functions that shape the config are for then.
func (c *Config) topLevel(L *glua.LState, what string) {
	if !c.loading {
		L.RaiseError("slime.%s is for init.lua's top level, not an action", what)
	}
}

// luaConfig is slime.config{...}: the settings, merged over what's
// been set (a table merges into a table it replaces, key by key; a
// list replaces).
func (c *Config) luaConfig(L *glua.LState) int {
	c.topLevel(L, "config")
	t := L.CheckTable(1)
	if _, err := lua.ToJSON(t); err != nil {
		L.ArgError(1, "settings must be JSON: "+err.Error())
	}
	merge(c.settings, t)
	return 0
}

// merge puts src's entries into dst, merging tables that aren't lists.
func merge(dst, src *glua.LTable) {
	src.ForEach(func(k, v glua.LValue) {
		if nt, ok := v.(*glua.LTable); ok && nt.RawGetInt(1) == glua.LNil {
			if ot, ok := dst.RawGet(k).(*glua.LTable); ok && ot.RawGetInt(1) == glua.LNil {
				merge(ot, nt)
				return
			}
		}
		dst.RawSet(k, v)
	})
}

// luaBind is slime.bind(key, action[, args]) or slime.bind(key, fn): a
// later bind of the same key replaces the earlier. A "repeat:" prefix
// on the key makes the binding repeatable.
func (c *Config) luaBind(L *glua.LState) int {
	c.topLevel(L, "bind")
	key, repeat := bindKey(L, L.CheckString(1))
	b := &rpc.Binding{Key: key, Repeat: repeat}
	switch v := L.Get(2).(type) {
	case glua.LString:
		if v == "" {
			L.ArgError(2, "an action's name is needed")
		}
		b.Action = string(v)
		if args := L.OptTable(3, nil); args != nil {
			raw, err := lua.ToJSON(args)
			if err != nil {
				L.ArgError(3, "args must be JSON: "+err.Error())
			}
			b.Args = raw
		}
	case *glua.LFunction:
		c.nextFunc++
		c.funcs.RawSetInt(int(c.nextFunc), v)
		b.Lua = c.nextFunc
	default:
		L.ArgError(2, "an action's name or a function")
	}
	c.setBinding(b)
	return 0
}

// luaUnbind is slime.unbind(key): the key does nothing, even if the
// window binds it by default.
func (c *Config) luaUnbind(L *glua.LState) int {
	c.topLevel(L, "unbind")
	key, _ := bindKey(L, L.CheckString(1))
	c.setBinding(&rpc.Binding{Key: key})
	return 0
}

// bindKey is the key of a bind or unbind, normalized, and whether it
// was written with the "repeat:" prefix, which a sequence takes:
// a key alone repeats as it's held. A bad key is a Lua error.
func bindKey(L *glua.LState, raw string) (key string, repeat bool) {
	key = normKey(raw)
	key, repeat = strings.CutPrefix(key, "repeat:")
	if key == "" {
		L.ArgError(1, "a key is needed")
	}
	if repeat && !strings.Contains(key, ">") {
		L.ArgError(1, "repeat: needs a sequence (\"repeat:ctrl+b>h\"); a key alone repeats as it's held")
	}
	return key, repeat
}

// setBinding replaces the binding of b's key, or adds it.
func (c *Config) setBinding(b *rpc.Binding) {
	for i, old := range c.bindings {
		if old.Key == b.Key {
			c.bindings[i] = b
			return
		}
	}
	c.bindings = append(c.bindings, b)
}

// normKey is a chord as the keymap spells it: lower case, no spaces, so
// "Ctrl + Shift + D" and "ctrl+shift+d" are one key.
func normKey(key string) string {
	return strings.ToLower(strings.Join(strings.Fields(key), ""))
}

// luaAction is slime.action{name, title, args, run}: an action by
// name, replacing one of the same name.
func (c *Config) luaAction(L *glua.LState) int {
	c.topLevel(L, "action")
	t := L.CheckTable(1)
	name, ok := t.RawGetString("name").(glua.LString)
	if !ok || name == "" {
		L.ArgError(1, "an action needs a name")
	}
	run, ok := t.RawGetString("run").(*glua.LFunction)
	if !ok {
		L.ArgError(1, "an action needs run, a function")
	}
	a := &action{desc: rpc.ActionDesc{Name: string(name)}, run: run}
	if title, ok := t.RawGetString("title").(glua.LString); ok {
		a.desc.Title = string(title)
	}
	if spec, ok := t.RawGetString("args").(*glua.LTable); ok {
		raw, err := lua.ToJSON(spec)
		if err != nil {
			L.ArgError(1, "args must be JSON: "+err.Error())
		}
		a.spec = spec
		a.desc.Args = raw
	}
	// The function lives as long as the action's name is bound to it.
	c.funcs.RawSetString(string(name), run)
	if old := c.byName[string(name)]; old != nil {
		*old = *a
		return 0
	}
	c.byName[string(name)] = a
	c.actions = append(c.actions, a)
	return 0
}
