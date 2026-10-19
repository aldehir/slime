package lua

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// syncHost is a fakeHost safe for hooks, which print from goroutines
// of their own.
type syncHost struct {
	mu sync.Mutex
	fakeHost
}

func (h *syncHost) Output(stream Stream, text string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fakeHost.Output(stream, text)
}

func (h *syncHost) Log(text string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fakeHost.Log(text)
}

func (h *syncHost) output() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return strings.Join(h.out, "")
}

// deliver sends events to r once it's running, from another goroutine.
func deliver(r *Runner, events ...string) {
	go func() {
		for _, e := range events {
			time.Sleep(20 * time.Millisecond)
			name, params, _ := strings.Cut(e, " ")
			r.Deliver(name, json.RawMessage(params))
		}
	}()
}

func TestSleepAndTimers(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	start := time.Now()
	res, err := r.Run(context.Background(), "t", `
		slime.after(0.05, function(ctx) print("fired", ctx.origin, ctx.pane_id) end)
		local no = slime.after(10, function() print("never") end)
		assert(no:active())
		no:cancel()
		assert(not no:active())
		no:cancel()
		slime.sleep(0.02)
		print("slept")
		local n = 0
		local tick
		tick = slime.every(0.01, function()
			n = n + 1
			if n == 3 then tick:cancel() end
		end)
		return "main"
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `"main"` {
		t.Errorf("result %s", res)
	}
	if d := time.Since(start); d < 50*time.Millisecond || d > 2*time.Second {
		t.Errorf("took %s", d)
	}
	if got := h.output(); got != "stdout:slept\nstdout:fired\ttimer\tnil\n" {
		t.Errorf("output %q", got)
	}
}

func TestHooks(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{Pane: rpc.PaneID{WS: 1, Tab: 2, N: 3}})
	defer r.Close()
	deliver(r, `tab.created {"id":"1.4"}`, `pane.exited {"id":"1.2.9","status":7}`, `pane.exited {"id":"1.2.3","status":0}`)
	res, err := r.Run(context.Background(), "t", `
		-- The first hook blocks; the second runs meanwhile.
		slime.on("pane.*", function(ctx, ev)
			slime.sleep(0.01)
			print("a", ctx.event, ctx.pane_id, ctx.tab_id, ctx.workspace_id, ev.status, slime.pane_id)
		end)
		slime.on("pane.exited", function(ctx, ev)
			print("b", ev.id)
			if ev.id == "1.2.3" then slime.stop({ done = ev.status }) end
		end)
		slime.on("tab.created", function(ctx, ev) print("tab", ev.id, ctx.tab_id, ctx.pane_id) end)
		return "main"
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"done":0}` {
		t.Errorf("result %s", res)
	}
	want := "stdout:tab\t1.4\t1.4\tnil\n" +
		"stdout:b\t1.2.9\n" +
		"stdout:a\tpane.exited\t1.2.9\t1.2\t1\t7\t1.2.3\n" +
		"stdout:b\t1.2.3\n"
	if got := h.output(); got != want {
		t.Errorf("output %q\nwant   %q", got, want)
	}
}

func TestHookCancelEndsRun(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	deliver(r, `x {}`, `x {}`)
	start := time.Now()
	res, err := r.Run(context.Background(), "t", `
		local n = 0
		local hook
		hook = slime.on("x", function() n = n + 1 print("x", n) hook:cancel() end)
		return "main"
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `"main"` || h.output() != "stdout:x\t1\n" {
		t.Errorf("result %s, output %q", res, h.output())
	}
	if time.Since(start) > 2*time.Second {
		t.Error("the run didn't end when its hook was cancelled")
	}
}

func TestHookErrorFailsRun(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	deliver(r, `x {}`)
	_, err := r.Run(context.Background(), "t", `
		slime.on("x", function() error("boom") end)
		slime.every(1, function() end)
	`)
	if err == nil || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), "traceback") {
		t.Errorf("err %v", err)
	}
}

func TestWait(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	deliver(r, `pane.exited {"id":"1.2.9","status":7}`, `pane.exited {"id":"1.2.3","status":4}`, `tab.closed {"id":"1.2"}`)
	res, err := r.Run(context.Background(), "t", `
		local ev, why = slime.wait("pane.exited", { pane_id = "1.2.3" }, 0.001)
		assert(ev == nil and why == "timeout", why)
		ev = assert(slime.wait("pane.exited", { pane_id = "1.2.3" }, 5))
		local tab = assert(slime.wait("tab.*", nil, 5))
		local none, why2 = slime.wait("pane.exited", { status = 99 }, 0.05)
		return { status = ev.status, id = ev.id, tab = tab.id, none = none, why = why2 }
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"id":"1.2.3","status":4,"tab":"1.2","why":"timeout"}` {
		t.Errorf("result %s", res)
	}
}

func TestCancelWhileBlocked(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	_, err := r.Run(ctx, "t", `
		slime.on("x", function() end)
		slime.every(0.001, function() end)
		slime.sleep(30)
	`)
	if !errors.Is(err, ErrCancelled) {
		t.Errorf("err %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Error("cancel didn't end the sleep")
	}
}

func TestPersistent(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{Persistent: true})
	defer r.Close()
	res, err := r.Run(context.Background(), "init", `
		slime.on("pane.exited", function(ctx, ev) print("exited", ev.id, slime.pane_id) end)
		slime.on("boom", function() error("bad hook") end)
		function twice(ctx, n)
			slime.sleep(0.01)
			return { n = n * 2, pane = ctx.pane_id, mine = slime.pane_id }
		end
		return "loaded"
	`)
	if err != nil || string(res) != `"loaded"` {
		t.Fatalf("load: %s, %v", res, err)
	}
	// Hooks and timers live on; a failing one is logged.
	r.Deliver("boom", json.RawMessage(`{}`))
	r.Deliver("pane.exited", json.RawMessage(`{"id":"1.2.3","status":0}`))
	deadline := time.Now().Add(5 * time.Second)
	for h.output() != "stdout:exited\t1.2.3\tnil\n" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := h.output(); got != "stdout:exited\t1.2.3\tnil\n" {
		t.Errorf("hook output %q", got)
	}
	h.mu.Lock()
	logs := strings.Join(h.logs, "|")
	h.mu.Unlock()
	if !strings.Contains(logs, "handler failed") || !strings.Contains(logs, "bad hook") {
		t.Errorf("logs %q", logs)
	}

	// Calls run one at a time in Lua but overlap while blocked, each
	// for its own pane, with its own output.
	fn := r.L.GetGlobal("twice")
	var wg sync.WaitGroup
	results := make([]string, 2)
	outs := make([]string, 2)
	for i, pane := range []rpc.PaneID{{WS: 1, Tab: 1, N: 1}, {WS: 2, Tab: 2, N: 2}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ids := IDsOf(pane)
			ctxT := r.L.NewTable()
			ctxT.RawSetString("pane_id", ids.Pane)
			out := func(stream Stream, text string) { outs[i] += text }
			res, err := r.Call(context.Background(), CallOptions{Pane: pane, Out: out}, fn, ctxT, glua.LNumber(i+1))
			if err != nil {
				results[i] = err.Error()
				return
			}
			results[i] = string(res)
		}()
	}
	wg.Wait()
	if results[0] != `{"mine":"1.1.1","n":2,"pane":"1.1.1"}` || results[1] != `{"mine":"2.2.2","n":4,"pane":"2.2.2"}` {
		t.Errorf("calls %q", results)
	}
}

func TestCloseCancelsCalls(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{Persistent: true})
	if _, err := r.Run(context.Background(), "init", `function nap() slime.sleep(30) end`); err != nil {
		t.Fatal(err)
	}
	errc := make(chan error, 1)
	go func(r *Runner, nap glua.LValue) {
		_, err := r.Call(context.Background(), CallOptions{}, nap)
		errc <- err
	}(r, r.L.GetGlobal("nap"))
	time.Sleep(20 * time.Millisecond)
	start := time.Now()
	r.Close()
	if err := <-errc; !errors.Is(err, ErrCancelled) {
		t.Errorf("err %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Error("Close waited for the sleep")
	}
}

func TestStopFromMainThenHooksEnd(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	res, err := r.Run(context.Background(), "t", `
		slime.every(1, function() end)
		slime.stop("early")
	`)
	if err != nil || string(res) != `"early"` {
		t.Errorf("result %s, %v", res, err)
	}
}

// TestHelperProcess is the program the exec tests run: this test
// binary, told what to be by the arguments after "--" (a Go trick, so
// the tests depend on no program of the machine's).
func TestHelperProcess(t *testing.T) {
	if os.Getenv("SLIME_HELPER") == "" {
		return
	}
	args := os.Args
	for i, a := range args {
		if a == "--" {
			args = args[i+1:]
			break
		}
	}
	switch args[0] {
	case "echo":
		// What it's given, "err" on stderr, status 3.
		fmt.Println(strings.Join(args[1:], " "))
		fmt.Fprintln(os.Stderr, "err")
		os.Exit(3)
	case "cat":
		// Stdin to stdout, as it comes.
		buf := make([]byte, 1024)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				os.Stdout.Write(buf[:n])
			}
			if err != nil {
				break
			}
		}
	case "env":
		fmt.Println(os.Getenv("SLIME_T"))
	case "pwd":
		dir, _ := os.Getwd()
		fmt.Println(dir)
	case "sleep":
		time.Sleep(10 * time.Second)
	}
	os.Exit(0)
}

// helper is a Lua argv list running TestHelperProcess as what.
func helper(what ...string) string {
	exe, _ := os.Executable()
	return `{ [[` + exe + `]], "-test.run=^TestHelperProcess$", "--", "` + strings.Join(what, `", "`) + `" }`
}

func TestExec(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	dir := t.TempDir()
	res, err := r.Run(context.Background(), "t", `
		local env = { SLIME_HELPER = "1", SLIME_T = "yes" }
		local function clean(s) return (s:gsub("\r", "")) end
		local r = assert(slime.exec(`+helper("echo", "hi", "there")+`, { env = env }))
		local nothing, why = slime.exec({ "no-such-program-slime" })
		local cat = assert(slime.exec(`+helper("cat")+`, { stdin = "b\na\n", env = env }))
		local e = assert(slime.exec(`+helper("env")+`, { env = env }))
		local pwd = assert(slime.exec(`+helper("pwd")+`, { env = env, cwd = [[`+dir+`]] }))
		local bad, why2 = slime.exec("")
		return { status = r.status, ok = r.ok, out = clean(r.stdout), err = clean(r.stderr),
			nothing = nothing, why = why ~= nil, cat = clean(cat.stdout), env = clean(e.stdout),
			pwd = clean(pwd.stdout), why2 = why2 }
	`)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Status  int
		OK      bool
		Out     string
		Err     string
		Nothing any
		Why     bool
		Cat     string
		Env     string
		Pwd     string
		Why2    string
	}
	if err := json.Unmarshal(res, &got); err != nil {
		t.Fatal(err)
	}
	if got.Status != 3 || got.OK || strings.TrimSpace(got.Out) != "hi there" || strings.TrimSpace(got.Err) != "err" || !got.Why || got.Nothing != nil {
		t.Errorf("exec %+v", got)
	}
	if got.Cat != "b\na\n" || strings.TrimSpace(got.Env) != "yes" || strings.TrimSpace(got.Pwd) != dir || !strings.Contains(got.Why2, "argv") {
		t.Errorf("stdin/env/cwd %+v", got)
	}
}

func TestExecStart(t *testing.T) {
	h := &syncHost{}
	r := New(h, Context{})
	defer r.Close()
	res, err := r.Run(context.Background(), "t", `
		local env = { SLIME_HELPER = "1" }
		local pieces = {}
		local p = assert(slime.exec.start(`+helper("cat")+`, { env = env, stdin = true,
			stdout = function(d) pieces[#pieces + 1] = (d:gsub("\r", "")) end }))
		assert(p:running() and p.pid > 0)
		assert(p:write("z\n"))
		assert(p:write("y\n"))
		local early, why = p:wait(0.01)
		assert(early == nil and why == "timeout")
		p:close_stdin()
		local r = assert(p:wait(5))
		assert(not p:running())
		local long = assert(slime.exec.start(`+helper("sleep")+`, { env = env }))
		assert(long:running())
		long:kill()
		local k = assert(long:wait(5))
		local to, why2 = slime.exec(`+helper("sleep")+`, { env = env, timeout = 0.05 })
		return { status = r.status, out = table.concat(pieces), buffered = r.stdout, killed = k.status ~= 0, to = to, why2 = why2 }
	`)
	if err != nil {
		t.Fatal(err)
	}
	if string(res) != `{"buffered":"","killed":true,"out":"z\ny\n","status":0,"why2":"timed out after 0.05s"}` {
		t.Errorf("result %s", res)
	}
}
