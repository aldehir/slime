package daemon

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/aldehir/slime/internal/rpc"
)

// Browser panes: a pane a window's browser fills, of which the daemon
// keeps the url and title, relaying them between viewers.

// browserSplit starts a browser pane beside another and returns what
// came with it.
func browserSplit(w *window, beside PaneID, url string) (*Attachment, rpc.Created) {
	w.t.Helper()
	var created rpc.Created
	a, err := w.call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: beside, Direction: Right, Kind: rpc.PaneBrowser, URL: url}, &created)
	if err != nil {
		w.t.Fatal(err)
	}
	if a.Workspace != nil {
		w.ws = a.Workspace
	}
	return a, created
}

// notified lists the params of the notifications name that c set aside
// before its last reply, leaving them there.
func notified(c *Client, name string) []json.RawMessage {
	var out []json.RawMessage
	for _, p := range c.backlog {
		if got, params, ok := Notification(p.m); ok && got == name {
			out = append(out, params)
		}
	}
	return out
}

// nextNotify reads c's next notification.
func nextNotify(t *testing.T, c *Client) (string, json.RawMessage) {
	t.Helper()
	for {
		_, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if name, params, ok := Notification(m); ok {
			return name, params
		}
	}
}

func (h *harness) spawnedCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.ptys)
}

func paneInfo(t *testing.T, c *Client, id PaneID) rpc.PaneDesc {
	t.Helper()
	var d rpc.PaneDesc
	if err := c.Call(rpc.PaneInfo, rpc.PaneParams{ID: id}, &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func wantCode(t *testing.T, what string, err error, code int) {
	t.Helper()
	var rerr *rpc.Error
	if !errors.As(err, &rerr) || rerr.Code != code {
		t.Errorf("%s: %v, want code %d", what, err, code)
	}
}

// TestBrowserSplit: a browser pane joins the tree with no child; its
// viewers get pane.attached with its kind and url and nothing after,
// and a layout measures it with the tab's cell size.
func TestBrowserSplit(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	a, created := browserSplit(w, first, "https://example.com")
	ps := a.Panes[created.Pane]
	if ps == nil || ps.Attached.Kind != rpc.PaneBrowser || ps.Attached.URL != "https://example.com" {
		t.Fatalf("attached %+v", ps)
	}
	if len(ps.Draws) != 0 || len(ps.Notices) != 0 {
		t.Errorf("a browser pane sent %d frames and %d notices", len(ps.Draws), len(ps.Notices))
	}
	if got := show(w.ws.Tabs[0].Tree); got != "r(5000:1 5000:2)" {
		t.Errorf("tree %s", got)
	}
	if n := h.spawnedCount(); n != 1 {
		t.Errorf("%d children spawned", n)
	}
	d := paneInfo(t, w.c, created.Pane)
	if d.Kind != rpc.PaneBrowser || d.URL != "https://example.com" || d.PID != 0 || d.Cols != 0 || d.Command != "" {
		t.Errorf("info %+v", d)
	}

	// A second window gets it as the first did, and sizes the terminal
	// beside it to half the tab.
	w2 := h.window()
	var s rpc.Workspace
	if err := w2.c.Call(rpc.WorkspaceAttach, rpc.WorkspaceAttachParams{ID: w.ws.ID, Area: Area{Width: 800, Height: 600, CellW: 10, CellH: 20}}, &s); err != nil {
		t.Fatal(err)
	}
	a2 := collect(w2.c)
	if ps := a2.Panes[created.Pane]; ps == nil || ps.Attached.Kind != rpc.PaneBrowser || ps.Attached.URL != "https://example.com" || len(ps.Draws) != 0 {
		t.Errorf("second window's attach %+v", ps)
	}
	if ps := a2.Panes[first]; ps == nil || ps.Attached.Kind != rpc.PaneTerminal {
		t.Errorf("terminal's attach %+v", ps)
	}
	if got := h.pty(0).getSize(); got != [2]uint16{40, 30} {
		t.Errorf("terminal beside the browser is %v, want 40x30", got)
	}
}

// TestBrowserNavigate: pane.navigate reaches every viewer as pane.url,
// the caller's too when it is one.
func TestBrowserNavigate(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	first := w1.newWorkspace()
	_, created := browserSplit(w1, first, "https://a.example")
	w2 := h.window()
	w2.attach(w1.ws.ID, Area{})

	cli := h.connect()
	if err := cli.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: created.Pane, URL: "https://b.example"}, nil); err != nil {
		t.Fatal(err)
	}
	for i, w := range []*window{w1, w2} {
		if u := nextEvent[rpc.PaneURLParams](w, rpc.EvPaneURL); u.ID != created.Pane || u.URL != "https://b.example" {
			t.Errorf("window %d got %+v", i+1, u)
		}
	}
	if n := notified(cli, rpc.EvPaneURL); len(n) != 0 {
		t.Errorf("a caller that views nothing got %s", n)
	}

	if err := w1.c.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: created.Pane, URL: "https://c.example"}, nil); err != nil {
		t.Fatal(err)
	}
	if n := notified(w1.c, rpc.EvPaneURL); len(n) != 1 {
		t.Errorf("the viewer that navigated got %s", n)
	}
	if u := nextEvent[rpc.PaneURLParams](w2, rpc.EvPaneURL); u.URL != "https://c.example" {
		t.Errorf("second window got %+v", u)
	}
	if d := paneInfo(t, cli, created.Pane); d.URL != "https://c.example" {
		t.Errorf("info %+v", d)
	}
}

// TestBrowserVisited: a viewer's report reaches the other viewers, not
// itself, and the subscribers as pane.url and pane.title.
func TestBrowserVisited(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	first := w1.newWorkspace()
	_, created := browserSplit(w1, first, "https://a.example")
	w2 := h.window()
	w2.attach(w1.ws.ID, Area{})
	sub := h.connect()
	if err := sub.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"pane.url", "pane.title"}}, nil); err != nil {
		t.Fatal(err)
	}

	if err := w1.c.Call(rpc.PaneVisited, rpc.PaneVisitedParams{Pane: created.Pane, URL: "https://a.example/next", Title: "Next"}, nil); err != nil {
		t.Fatal(err)
	}
	if n := notified(w1.c, rpc.EvPaneURL); len(n) != 0 {
		t.Errorf("the reporter got its own url back: %s", n)
	}
	if u := nextEvent[rpc.PaneURLParams](w2, rpc.EvPaneURL); u.ID != created.Pane || u.URL != "https://a.example/next" {
		t.Errorf("second window got %+v", u)
	}
	if n := nextEvent[rpc.PaneTitleParams](w2, rpc.EvPaneTitle); n.ID != created.Pane || n.Title != "Next" {
		t.Errorf("second window got %+v", n)
	}
	if n := notified(w1.c, rpc.EvPaneTitle); len(n) != 0 {
		t.Errorf("the reporter got its own title back: %s", n)
	}
	id := created.Pane.String()
	for _, want := range []string{
		`pane.url {"id":"` + id + `","url":"https://a.example/next"}`,
		`pane.title {"id":"` + id + `","title":"Next"}`,
	} {
		if name, params := nextNotify(t, sub); name+" "+string(params) != want {
			t.Errorf("subscriber got %s %s, want %s", name, params, want)
		}
	}
	if d := paneInfo(t, sub, created.Pane); d.URL != "https://a.example/next" || d.Title != "Next" {
		t.Errorf("info %+v", d)
	}

	// Retitled where it is: only the title goes out.
	if err := w1.c.Call(rpc.PaneVisited, rpc.PaneVisitedParams{Pane: created.Pane, URL: "https://a.example/next", Title: "Renamed"}, nil); err != nil {
		t.Fatal(err)
	}
	if n := nextEvent[rpc.PaneTitleParams](w2, rpc.EvPaneTitle); n.Title != "Renamed" {
		t.Errorf("second window got %+v", n)
	}
	if name, params := nextNotify(t, sub); name != rpc.EvPaneTitle || string(params) != `{"id":"`+id+`","title":"Renamed"}` {
		t.Errorf("subscriber got %s %s", name, params)
	}
	// The second window's next pane.url is a later navigation's: none
	// came between.
	if err := sub.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: created.Pane, URL: "https://z.example"}, nil); err != nil {
		t.Fatal(err)
	}
	if u := nextEvent[rpc.PaneURLParams](w2, rpc.EvPaneURL); u.URL != "https://z.example" {
		t.Errorf("second window got %+v", u)
	}
	// The last page's title went with it.
	if n := nextEvent[rpc.PaneTitleParams](w2, rpc.EvPaneTitle); n.Title != "" {
		t.Errorf("second window got %+v", n)
	}
	if d := paneInfo(t, sub, created.Pane); d.Title != "" {
		t.Errorf("info %+v", d)
	}
}

// TestBrowserNotTerminal: a terminal's methods fail on a browser pane,
// a browser's on a terminal, and wire input to a browser goes nowhere.
func TestBrowserNotTerminal(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	_, created := browserSplit(w, first, "https://a.example")
	wantCode(t, "write", w.c.Call(rpc.PaneWrite, rpc.PaneWriteParams{ID: created.Pane, Text: "x"}, nil), rpc.CodeInvalidParams)
	wantCode(t, "text", w.c.Call(rpc.PaneText, rpc.PaneTextParams{ID: created.Pane}, nil), rpc.CodeInvalidParams)
	wantCode(t, "navigate a terminal", w.c.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: first, URL: "https://a.example"}, nil), rpc.CodeInvalidParams)
	wantCode(t, "visited a terminal", w.c.Call(rpc.PaneVisited, rpc.PaneVisitedParams{Pane: first, URL: "https://a.example"}, nil), rpc.CodeInvalidParams)
	wantCode(t, "navigate nowhere", w.c.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: created.Pane}, nil), rpc.CodeInvalidParams)
	wantCode(t, "navigate no pane", w.c.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: PaneID{WS: 9, Tab: 1, N: 1}, URL: "https://a.example"}, nil), rpc.CodeNotFound)
	w.c.Send(created.Pane, &Event{Data: evText("typed")})
	w.c.Send(created.Pane, &Ack{Seq: 1})
	w.c.Send(created.Pane, &Resize{Size: Size{Cols: 10, Rows: 10}})
	if d := paneInfo(t, w.c, created.Pane); d.URL != "https://a.example" {
		t.Errorf("info %+v", d)
	}
}

// TestBrowserKill: killing a browser pane ends it as a child's exit
// does, status 0; closing its tab and killing its workspace finish.
func TestBrowserKill(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	_, created := browserSplit(w, first, "https://a.example")
	sub := h.connect()
	if err := sub.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"pane.exited"}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.PaneKill, rpc.PaneParams{ID: created.Pane}, nil); err != nil {
		t.Fatal(err)
	}
	if e := nextEvent[rpc.PaneExitedParams](w, rpc.EvPaneExited); e.ID != created.Pane || e.Status != 0 {
		t.Errorf("exit %+v", e)
	}
	nextEvent[rpc.Workspace](w, rpc.EvWorkspaceChanged)
	if tree := w.ws.Tabs[0].Tree; !tree.IsLeaf() || tree.Pane != first {
		t.Errorf("after the kill: %s", show(tree))
	}
	if name, params := nextNotify(t, sub); name != rpc.EvPaneExited || string(params) != `{"id":"`+created.Pane.String()+`","status":0}` {
		t.Errorf("subscriber got %s %s", name, params)
	}
	wantCode(t, "info after kill", w.c.Call(rpc.PaneInfo, rpc.PaneParams{ID: created.Pane}, nil), rpc.CodeNotFound)

	// A tab of a browser alone, closed.
	var tab rpc.Created
	if err := w.c.Call(rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Kind: rpc.PaneBrowser, URL: "https://b.example"}, &tab); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.TabClose, rpc.TabParams{ID: tab.Pane.TabID()}, nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the closed tab's pane", func() bool { return len(h.list().Panes) == 1 })

	// A workspace of browsers, killed.
	script := h.connect()
	var ws rpc.Workspace
	tabs := []*rpc.Layout{{Pane: &rpc.PaneSpec{Kind: rpc.PaneBrowser, URL: "https://c.example"}}}
	if err := script.Call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{Tabs: tabs}, &ws); err != nil {
		t.Fatal(err)
	}
	if err := script.Call(rpc.WorkspaceKill, rpc.WorkspaceParams{ID: ws.ID}, nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the killed workspace", func() bool { return len(h.list().Workspaces) == 1 })
}

// TestBrowserLayout: tab.new builds a tree with a browser leaf, which
// starts no child; and makes a tab of one browser without a layout.
func TestBrowserLayout(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.c.Call(rpc.WorkspaceResize, rpc.WorkspaceResizeParams{ID: w.ws.ID, Area: Area{Width: 1000, Height: 800, CellW: 10, CellH: 20}}, nil)
	layout := &rpc.Layout{Axis: Row, Children: []rpc.LayoutChild{
		{Share: 7000, Node: &rpc.Layout{Pane: &rpc.PaneSpec{Command: "nvim"}}},
		{Share: 3000, Node: &rpc.Layout{Pane: &rpc.PaneSpec{Kind: rpc.PaneBrowser, URL: "https://a.example"}}},
	}}
	var created rpc.Created
	a, err := w.call(rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Layout: layout}, &created)
	if err != nil {
		t.Fatal(err)
	}
	w.ws = a.Workspace
	panes := w.ws.Tabs[1].Tree.Panes()
	if len(panes) != 2 || len(a.Panes) != 2 {
		t.Fatalf("tree %s, %d attached", show(w.ws.Tabs[1].Tree), len(a.Panes))
	}
	if b := a.Panes[panes[1]]; b.Attached.Kind != rpc.PaneBrowser || b.Attached.URL != "https://a.example" {
		t.Errorf("browser leaf attached %+v", b.Attached)
	}
	if n := h.spawnedCount(); n != 2 {
		t.Errorf("%d children spawned", n)
	}
	if got := h.pty(1).getSize(); got != [2]uint16{70, 40} {
		t.Errorf("nvim's size %v, want 70x40", got)
	}

	var one rpc.Created
	a, err = w.call(rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Kind: rpc.PaneBrowser, URL: "https://b.example"}, &one)
	if err != nil {
		t.Fatal(err)
	}
	if b := a.Panes[one.Pane]; b == nil || b.Attached.URL != "https://b.example" {
		t.Errorf("one browser's attach %+v", b)
	}
	if n := h.spawnedCount(); n != 2 {
		t.Errorf("%d children spawned", n)
	}
}

// TestBrowserBadSpecs: a browser needs a url and runs no command, and
// a kind must be known; none of these start anything.
func TestBrowserBadSpecs(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	leaf := func(spec rpc.PaneSpec) *rpc.Layout { return &rpc.Layout{Pane: &spec} }
	for _, call := range []struct {
		what   string
		method string
		params any
	}{
		{"split without url", rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Right, Kind: rpc.PaneBrowser}},
		{"split with command", rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Right, Kind: rpc.PaneBrowser, URL: "https://a.example", Command: "sh"}},
		{"split of no kind", rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Right, Kind: "editor"}},
		{"tab without url", rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Kind: rpc.PaneBrowser}},
		{"tab with command", rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Kind: rpc.PaneBrowser, URL: "https://a.example", Command: "sh"}},
		{"layout leaf without url", rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Layout: &rpc.Layout{Axis: Row, Children: []rpc.LayoutChild{
			{Node: leaf(rpc.PaneSpec{})}, {Node: leaf(rpc.PaneSpec{Kind: rpc.PaneBrowser})},
		}}}},
		{"workspace tab without url", rpc.WorkspaceNew, rpc.WorkspaceNewParams{Tabs: []*rpc.Layout{leaf(rpc.PaneSpec{Kind: rpc.PaneBrowser})}}},
	} {
		wantCode(t, call.what, w.c.Call(call.method, call.params, nil), rpc.CodeInvalidParams)
	}
	if n := h.spawnedCount(); n != 1 {
		t.Errorf("%d children spawned", n)
	}
	if l := h.list(); len(l.Panes) != 1 || len(l.Workspaces) != 1 {
		t.Errorf("list %+v", l)
	}
}

// TestBrowserMove: a browser pane moved to another tab attaches again
// under its new id with its url, and its old id still finds it.
func TestBrowserMove(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	_, created := browserSplit(w, first, "https://a.example")
	var moved rpc.Created
	a, err := w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: created.Pane}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	at := a.Panes[moved.Pane]
	if at == nil || at.Attached.MovedFrom != created.Pane || at.Attached.Kind != rpc.PaneBrowser || at.Attached.URL != "https://a.example" {
		t.Fatalf("attached %+v", at)
	}
	if err := w.c.Call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: created.Pane, URL: "https://b.example"}, nil); err != nil {
		t.Fatal(err)
	}
	if u := nextEvent[rpc.PaneURLParams](w, rpc.EvPaneURL); u.ID != moved.Pane || u.URL != "https://b.example" {
		t.Errorf("pane.url %+v", u)
	}
}

// TestBrowserScript: Lua builds browser panes (slime.layout.browser,
// kind on a split) and navigates them (slime.pane.navigate, the pane
// from pane_id when left out).
func TestBrowserScript(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	c := h.connect()
	_, done := runScript(t, c, rpc.ScriptRunParams{Pane: first, Source: `
		local p = assert(slime.pane.split{ direction = "down", kind = "browser", url = "https://a.example" })
		local t = assert(slime.tab.new{ layout = slime.layout.horizontal(slime.layout.pane{}, slime.layout.browser{ url = "https://b.example" }) })
		assert(slime.pane.navigate{ pane = p.pane, url = "https://c.example" })
		slime.pane_id = p.pane
		assert(slime.pane.navigate{ url = "https://d.example" })
		local info = assert(slime.pane.info{})
		return { info.kind, info.url }
	`})
	if !done.OK || string(done.Result) != `["browser","https://d.example"]` {
		t.Fatalf("script: ok %v, result %s, error %s", done.OK, done.Result, done.Error)
	}
	for _, want := range []string{"https://c.example", "https://d.example"} {
		if u := nextEvent[rpc.PaneURLParams](w, rpc.EvPaneURL); u.URL != want {
			t.Errorf("pane.url %+v, want %s", u, want)
		}
	}
	var urls []string
	for _, p := range h.list().Panes {
		if p.Kind == rpc.PaneBrowser {
			urls = append(urls, p.URL)
		}
	}
	if len(urls) != 2 || urls[1] != "https://b.example" {
		t.Errorf("browser panes at %v", urls)
	}
	if n := h.spawnedCount(); n != 2 {
		t.Errorf("%d children spawned", n)
	}
}
