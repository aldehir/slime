package daemon

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/rpc"
)

// runScript starts a script over c and follows it to its end,
// collecting its output.
func runScript(t *testing.T, c *Client, p rpc.ScriptRunParams) ([]rpc.ScriptOutputParams, rpc.ScriptDoneParams) {
	t.Helper()
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ScriptRun, p, &started); err != nil {
		t.Fatal(err)
	}
	return followScript(t, c, started.ID)
}

func followScript(t *testing.T, c *Client, id uint32) ([]rpc.ScriptOutputParams, rpc.ScriptDoneParams) {
	t.Helper()
	var out []rpc.ScriptOutputParams
	for {
		_, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		name, params, ok := Notification(m)
		if !ok {
			continue
		}
		switch name {
		case rpc.EvScriptOutput:
			var o rpc.ScriptOutputParams
			json.Unmarshal(params, &o)
			if o.ID == id {
				out = append(out, o)
			}
		case rpc.EvScriptDone:
			var d rpc.ScriptDoneParams
			json.Unmarshal(params, &d)
			if d.ID == id {
				return out, d
			}
		}
	}
}

func scripts(t *testing.T, c *Client) []rpc.ScriptDesc {
	t.Helper()
	var l rpc.ScriptListResult
	if err := c.Call(rpc.ScriptList, nil, &l); err != nil {
		t.Fatal(err)
	}
	return l.Scripts
}

// waitScripts waits until c lists n scripts.
func waitScripts(t *testing.T, c *Client, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if l := scripts(t, c); len(l) == n {
			return
		} else if time.Now().After(deadline) {
			t.Fatalf("still %d scripts, want %d", len(l), n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestScriptBuildsWorkspace(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	out, done := runScript(t, c, rpc.ScriptRunParams{Name: "dev.lua", Args: json.RawMessage(`{"file":"app.log"}`), Source: `
		local ws, err = slime.workspace.new{
			name = "dev",
			tabs = {
				slime.layout.horizontal(0.7,
					slime.layout.pane{ command = "nvim" },
					slime.layout.vertical(0.5,
						slime.layout.pane{ command = "tail -f " .. slime.args.file },
						slime.layout.pane{})),
			},
		}
		assert(ws, err)
		assert(ws.name == "dev" and #ws.tabs == 1 and ws.active_tab == ws.tabs[1].id, slime.json.encode(ws))
		local first = ws.tabs[1].tree.split.children[1].node.pane
		local p = assert(slime.pane.split{ pane = first, direction = "down", share = 3000, command = "htop" })
		assert(slime.pane.write{ id = p.pane, text = "q" })
		print("made", p.pane)
		local info = assert(slime.pane.info{ id = p.pane })
		return { workspace = ws.id, pane = p.pane, command = info.command, tab = info.tab == ws.tabs[1].id }
	`})
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	var res struct {
		Workspace, Pane uint32
		Command         string
		Tab             bool
	}
	if err := json.Unmarshal(done.Result, &res); err != nil {
		t.Fatal(err)
	}
	if res.Command != "htop" || !res.Tab {
		t.Errorf("result %s", done.Result)
	}
	var commands []string
	h.mu.Lock()
	for _, o := range h.opts {
		commands = append(commands, o.Command)
	}
	h.mu.Unlock()
	if strings.Join(commands, ",") != "nvim,tail -f app.log,,htop" {
		t.Errorf("spawned %q", commands)
	}
	if got := h.pty(3).inputString(); got != "q" {
		t.Errorf("htop pane got %q", got)
	}
	if len(out) != 1 || out[0].Stream != "stdout" || out[0].Data != fmt.Sprintf("made\t%d\n", res.Pane) {
		t.Errorf("output %+v", out)
	}
	// The script wasn't a viewer: the workspace is detached, with its
	// panes alive.
	var l rpc.WorkspaceListResult
	if err := c.Call(rpc.WorkspaceList, nil, &l); err != nil {
		t.Fatal(err)
	}
	if len(l.Workspaces) != 1 || l.Workspaces[0].Attached || len(l.Panes) != 4 {
		t.Errorf("after: %+v", l)
	}
}

// nextNotification reads c until a notification named name comes, and
// returns its params.
func nextNotification(t *testing.T, c *Client, name string) json.RawMessage {
	t.Helper()
	for {
		_, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if got, params, ok := Notification(m); ok && got == name {
			return params
		}
	}
}

// TestScriptOpensWorkspaceInWindow: a script run from a pane makes
// workspaces for the window showing that pane, unless it says
// otherwise; its tabs and splits land in the pane's own workspace.
func TestScriptOpensWorkspaceInWindow(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	_, done := runScript(t, c, rpc.ScriptRunParams{Pane: pane, Source: `
		local shown = assert(slime.workspace.new{ name = "shown", tabs = { slime.layout.pane{} } })
		local quiet = assert(slime.workspace.new{ name = "quiet", tabs = { slime.layout.pane{} }, attach = false })
		local _, err, code = slime.workspace.new{ name = "nowhere", tabs = { slime.layout.pane{} }, attach = 999 }
		assert(code == 1000, err)
		local again = assert(slime.workspace.new{ name = "again", tabs = { slime.layout.pane{} } })
		local tab = assert(slime.tab.new{})
		local split = assert(slime.pane.split{ direction = "down" })
		return { shown = shown.id, quiet = quiet.id, again = again.id, tab = tab.workspace, split = split.workspace }
	`})
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	var res struct{ Shown, Quiet, Again, Tab, Split uint32 }
	if err := json.Unmarshal(done.Result, &res); err != nil {
		t.Fatal(err)
	}
	if res.Tab != w.ws.ID || res.Split != w.ws.ID {
		t.Errorf("tab in %d, split in %d, want %d", res.Tab, res.Split, w.ws.ID)
	}
	// The window is told of the first and third, in order; the second
	// stays detached, and the script's own connection, no viewer, hears
	// nothing.
	for _, want := range []uint32{res.Shown, res.Again} {
		var open rpc.WorkspaceOpenParams
		if err := json.Unmarshal(nextNotification(t, w.c, rpc.EvWorkspaceOpen), &open); err != nil {
			t.Fatal(err)
		}
		if open.ID != want {
			t.Errorf("told to open %d (%s), want %d", open.ID, open.Name, want)
		}
	}
	home := w.ws.ID
	w.attach(res.Shown, Area{})
	l := h.list()
	for _, ws := range l.Workspaces {
		if ws.Attached != (ws.ID == home || ws.ID == res.Shown) {
			t.Errorf("workspace %d (%s) attached: %v", ws.ID, ws.Name, ws.Attached)
		}
	}
	if len(l.Workspaces) != 4 {
		t.Errorf("%d workspaces", len(l.Workspaces))
	}
}

func TestScriptErrorsAndLog(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	out, done := runScript(t, c, rpc.ScriptRunParams{Name: "bad.lua", Source: "slime.log('about to fail')\nlocal r, err, code = slime.pane.kill{ id = 99 }\nerror(err .. ' ' .. code)"})
	if done.OK {
		t.Fatal("ok?")
	}
	if !strings.HasPrefix(done.Error, "bad.lua:3: no such pane 1000") || !strings.Contains(done.Error, "stack traceback") {
		t.Errorf("error %q", done.Error)
	}
	if len(out) != 1 || out[0].Stream != "stderr" || out[0].Data != "about to fail\n" {
		t.Errorf("output %+v", out)
	}
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{}, nil); err == nil {
		t.Error("no source: no error")
	}
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Source: "x", Args: json.RawMessage(`[1]`)}, nil); err == nil {
		t.Error("array args: no error")
	}
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Source: "x", Pane: 42}, nil); err == nil {
		t.Error("no such pane: no error")
	}
}

func TestScriptCancel(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	other := h.connect()
	if err := other.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"script.*"}}, nil); err != nil {
		t.Fatal(err)
	}
	var started rpc.ScriptRunResult
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Name: "loop.lua", Source: "while true do end"}, &started); err != nil {
		t.Fatal(err)
	}
	l := scripts(t, c)
	if len(l) != 1 || l[0].ID != started.ID || l[0].Name != "loop.lua" || l[0].Detached {
		t.Fatalf("list %+v", l)
	}
	if err := other.Call(rpc.ScriptCancel, rpc.ScriptParams{ID: started.ID}, nil); err != nil {
		t.Fatal(err)
	}
	_, done := followScript(t, c, started.ID)
	if done.OK || done.Error != "cancelled" {
		t.Errorf("done %+v", done)
	}
	// The subscriber heard too.
	_, done = followScript(t, other, started.ID)
	if done.OK {
		t.Errorf("subscriber: %+v", done)
	}
	if err := other.Call(rpc.ScriptCancel, rpc.ScriptParams{ID: started.ID}, nil); err == nil {
		t.Error("cancelling a finished script: no error")
	}
	waitScripts(t, other, 0)
}

func TestScriptHangupCancelsUnlessDetached(t *testing.T) {
	h := newHarness(t)
	other := h.connect()
	c := h.connect()
	var attached, detached rpc.ScriptRunResult
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Source: "while true do end"}, &attached); err != nil {
		t.Fatal(err)
	}
	if err := c.Call(rpc.ScriptRun, rpc.ScriptRunParams{Source: "while true do end", Detach: true}, &detached); err != nil {
		t.Fatal(err)
	}
	if l := scripts(t, other); len(l) != 2 || l[0].Detached || !l[1].Detached {
		t.Fatalf("list %+v", l)
	}
	c.Close()
	waitScripts(t, other, 1)
	if l := scripts(t, other); l[0].ID != detached.ID {
		t.Errorf("left: %+v", l)
	}
	if err := other.Call(rpc.ScriptCancel, rpc.ScriptParams{ID: detached.ID}, nil); err != nil {
		t.Fatal(err)
	}
	waitScripts(t, other, 0)
}

func TestScriptPaneContext(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	_, done := runScript(t, c, rpc.ScriptRunParams{Pane: pane, Source: `
		local info = assert(slime.pane.info{})
		assert(info.id == slime.pane_id and info.tab == slime.tab_id and info.workspace == slime.workspace_id)
		local p = assert(slime.pane.split{ direction = "down" })
		local tab = assert(slime.tab.info{})
		assert(tab.id == slime.tab_id)
		local ws = assert(slime.workspace.info{})
		return { split = p.pane, focus = tab.focus, ws = ws.id }
	`})
	if !done.OK {
		t.Fatalf("script failed: %s", done.Error)
	}
	var res struct{ Split, Focus, Ws uint32 }
	if err := json.Unmarshal(done.Result, &res); err != nil {
		t.Fatal(err)
	}
	// A script's split doesn't take the focus; a viewer's would.
	if res.Split == 0 || res.Focus != pane || res.Ws != w.ws.ID {
		t.Errorf("result %s (pane %d)", done.Result, pane)
	}
}
