package daemon

import (
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/rpc"
)

// Stage 8: scripts and the config see the daemon's events (slime.on,
// slime.wait), including the ones a pane's terminal gives rise to, and
// ask the windows to act (slime.client.queue).

func TestScriptHooksAndWait(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Name: "watch.lua", Pane: pane, Source: `
		local seen = {}
		slime.on("pane.title", function(ctx, ev)
			seen[#seen + 1] = "title " .. ev.title .. " for " .. ctx.pane_id
		end)
		slime.on("pane.bell", function(ctx, ev) seen[#seen + 1] = "bell " .. ev.id end)
		-- A hook for the exit keeps one that comes before the wait below
		-- is registered (the test ends the child as soon as it sees it).
		slime.on("pane.exited", function() end)
		local p = assert(slime.pane.split{ direction = "down", command = "child" })
		local ev = assert(slime.wait("pane.exited", { pane_id = p.pane }, 10))
		seen[#seen + 1] = "exited " .. ev.id .. " " .. ev.status
		-- The pwd event too, then stop with what was seen: the hooks are
		-- live, so a return wouldn't end the script.
		assert(slime.wait("pane.pwd", { pane_id = slime.pane_id }, 10))
		-- One pane's exit and another's title come from different
		-- goroutines: any order.
		table.sort(seen)
		slime.stop(seen)
	`}, &started); err != nil {
		t.Fatal(err)
	}
	// The window sees the split; the script waits for its exit.
	created := nextEvent[rpc.PaneAttachedParams](w, rpc.EvPaneAttached)
	eventually(t, "the child pty", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.ptys) == 2
	})
	h.pty(0).emit("\x1b]0;hello\x07\x07")
	h.pty(1).exit(3)
	// An event nothing waits for yet is dropped: the shell reports its
	// directory again until the script is done with it.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			h.pty(0).emit("\x1b]7;file:///tmp\x07")
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	_, done := followScript(t, c, started.ID)
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	want := `["bell ` + pane.String() + `","exited ` + created.ID.String() + ` 3","title hello for ` + pane.String() + `"]`
	if string(done.Result) != want {
		t.Errorf("seen %s, want %s", done.Result, want)
	}
}

func TestPaneEventsReachSubscribers(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	if err := c.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"pane.*"}}, nil); err != nil {
		t.Fatal(err)
	}
	h.pty(0).emit("\x1b]2;titled\x07\x1b]7;file:///home\x07\x07\x1b]7501;id=a:state=working:progress=40\x07")
	var mu sync.Mutex
	var got []string
	go func() {
		for {
			_, m, err := c.Recv()
			if err != nil {
				return
			}
			if name, params, ok := Notification(m); ok {
				mu.Lock()
				got = append(got, name+" "+string(params))
				mu.Unlock()
			}
		}
	}()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(got)
		mu.Unlock()
		if n >= 4 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	id := pane.String()
	want := []string{
		`pane.title {"id":"` + id + `","title":"titled"}`,
		`pane.pwd {"id":"` + id + `","pwd":"file:///home"}`,
		`pane.bell {"id":"` + id + `"}`,
		`pane.status {"id":"` + id + `","status":[{"id":"a","state":1,"progress":40}]}`,
	}
	// The terminal reports the title and pwd at the end of a write, the
	// bell and status as they come: any order.
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("events:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestClientQueue(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	// From a script, for its pane's workspace; and the method itself.
	_, done := runScript(t, c, rpc.ScriptRunParams{Pane: pane, Source: `
		assert(slime.client.queue("new_split", { direction = "down" }))
		local ok, err = slime.client.queue("")
		assert(not ok and err:find("name"), err)
		return "queued"
	`})
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	got := nextEvent[rpc.ClientActionParams](w, rpc.EvClientAction)
	if got.Workspace != w.ws.ID || got.Name != "new_split" || string(got.Args) != `{"direction":"down"}` {
		t.Errorf("client.action %+v", got)
	}
	if err := c.Call(rpc.ClientQueue, rpc.ClientQueueParams{Workspace: w.ws.ID, Name: "new_tab"}, nil); err != nil {
		t.Fatal(err)
	}
	got = nextEvent[rpc.ClientActionParams](w, rpc.EvClientAction)
	if got.Name != "new_tab" || got.Args != nil {
		t.Errorf("client.action %+v", got)
	}
	// No workspace: not from a script run for none, nor for one that
	// doesn't exist.
	_, done = runScript(t, c, rpc.ScriptRunParams{Source: `
		local ok, err = slime.client.queue("new_tab")
		return err
	`})
	if !done.OK || !strings.Contains(string(done.Result), "no workspace") {
		t.Errorf("without a pane: %s %s", done.Result, done.Error)
	}
	if err := c.Call(rpc.ClientQueue, rpc.ClientQueueParams{Workspace: 99, Name: "new_tab"}, nil); err == nil {
		t.Error("queued to a workspace that doesn't exist")
	}
}

func TestConfigHooksAndTimers(t *testing.T) {
	h, _ := newConfigHarness(t, `
		local exits = 0
		slime.on("pane.exited", function(ctx, ev)
			exits = exits + 1
			slime.log("exited " .. ev.id .. " " .. ev.status .. " origin " .. ctx.origin)
		end)
		slime.action{ name = "exits", run = function() return exits end }
		slime.action{ name = "slow", args = { n = "number" }, run = function(ctx, args)
			slime.sleep(0.05)
			return args.n
		end }
		slime.action{ name = "later", run = function(ctx, args)
			slime.after(0.01, function(ctx) slime.log("later ran for " .. tostring(ctx.pane_id)) end)
			return "scheduled"
		end }
	`)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	// Two slow actions overlap: both end within one sleep, not two.
	start := time.Now()
	var a, b rpc.ScriptRunResult
	if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "slow", Args: json.RawMessage(`{"n":"1"}`)}, &a); err != nil {
		t.Fatal(err)
	}
	if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "slow", Args: json.RawMessage(`{"n":"2"}`)}, &b); err != nil {
		t.Fatal(err)
	}
	dones := followScripts(t, c, a.ID, b.ID)
	if doneA, doneB := dones[a.ID], dones[b.ID]; !doneA.OK || !doneB.OK || string(doneA.Result) != "1" || string(doneB.Result) != "2" {
		t.Errorf("slow: %+v %+v", doneA, doneB)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("slow actions took %s", d)
	}
	// A hook in init.lua sees the daemon's events.
	_, created := w.split(pane, Right, 5000, "child")
	eventually(t, "the child pty", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.ptys) == 2
	})
	h.pty(1).exit(0)
	nextEvent[rpc.PaneExitedParams](w, rpc.EvPaneExited)
	_ = created
	eventually(t, "the hook", func() bool {
		var r rpc.ScriptRunResult
		if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "exits"}, &r); err != nil {
			t.Fatal(err)
		}
		_, done := followScript(t, c, r.ID)
		return string(done.Result) == "1"
	})
	// A timer an action set runs after the action returned.
	var later rpc.ScriptRunResult
	if err := c.Call(rpc.ActionInvoke, rpc.ActionInvokeParams{Name: "later", Pane: pane}, &later); err != nil {
		t.Fatal(err)
	}
	if _, done := followScript(t, c, later.ID); string(done.Result) != `"scheduled"` {
		t.Errorf("later: %+v", done)
	}
	// Its log line can't be read here; a reload must not hang on it.
	time.Sleep(30 * time.Millisecond)
	if err := c.Call(rpc.ConfigReload, nil, nil); err != nil {
		t.Fatal(err)
	}
}

// followScripts reads until every script in ids is done, in whatever
// order they end.
func followScripts(t *testing.T, c *Client, ids ...uint32) map[uint32]rpc.ScriptDoneParams {
	t.Helper()
	dones := map[uint32]rpc.ScriptDoneParams{}
	for len(dones) < len(ids) {
		_, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		name, params, ok := Notification(m)
		if !ok || name != rpc.EvScriptDone {
			continue
		}
		var d rpc.ScriptDoneParams
		json.Unmarshal(params, &d)
		for _, id := range ids {
			if d.ID == id {
				dones[id] = d
			}
		}
	}
	return dones
}
