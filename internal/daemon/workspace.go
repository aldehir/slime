package daemon

import (
	"errors"
	"os"
	"strconv"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// workspace is a named, ordered set of tabs, shown by any number of
// viewers at once. Focus is the workspace's, shared by its viewers: the
// active tab, and in each tab the pane with input and the one zoomed.
type workspace struct {
	id      uint32
	name    string
	tabs    []*tab
	viewers map[*conn]*viewer
	// The tab shown; nil while there are none.
	active *tab
	// When its last viewer left, to pick the most recent for a new
	// window.
	detachedAt time.Time
	// The tab area to estimate pane sizes in, in pixels: the smallest
	// viewer's, or the last one's once they've gone. Before any window
	// has sized it (a script built it), grid is the tab's size in cells
	// instead.
	area Area
	grid Size
	// Killed: it goes once its panes have.
	killed bool
}

// viewer is one connection's hold on a workspace.
type viewer struct {
	// The tab area it gave, if any (validArea).
	area Area
}

// tab is a layout tree of panes, one of them focused.
type tab struct {
	id   uint32
	ws   *workspace
	name string
	root *Node
	// The pane that gets input, and the one filling the tab (0 for
	// none).
	focus uint32
	zoom  uint32
}

var (
	errNoWorkspace = errors.New("no such workspace")
	errNoTab       = errors.New("no such tab")
	errNoPane      = errors.New("no such pane")
	errNoHost      = errors.New("no such host")
)

func (ws *workspace) attached() bool { return len(ws.viewers) > 0 }

func (ws *workspace) activeID() uint32 {
	if ws.active == nil {
		return 0
	}
	return ws.active.id
}

func (t *tab) info() rpc.Tab {
	return rpc.Tab{ID: t.id, Name: t.name, Tree: t.root.Clone(), Focus: t.focus, Zoomed: t.zoom}
}

func (ws *workspace) tabInfos() []rpc.Tab {
	infos := make([]rpc.Tab, len(ws.tabs))
	for i, t := range ws.tabs {
		infos[i] = t.info()
	}
	return infos
}

// structure is the workspace as workspace.changed carries it.
func (ws *workspace) structure() *rpc.Workspace {
	return &rpc.Workspace{ID: ws.id, Name: ws.name, ActiveTab: ws.activeID(), Tabs: ws.tabInfos()}
}

func (ws *workspace) desc() rpc.WorkspaceDesc {
	d := rpc.WorkspaceDesc{ID: ws.id, Name: ws.name, Attached: ws.attached(), Viewers: len(ws.viewers), ActiveTab: ws.activeID(), Tabs: ws.tabInfos()}
	if !ws.detachedAt.IsZero() && !ws.attached() {
		d.DetachedAt = ws.detachedAt.UnixMilli()
	}
	return d
}

// changedLocked sends the viewers and the subscribers the workspace's
// structure, except skip, which made the change.
func (s *Server) changedLocked(ws *workspace, skip *conn) {
	s.emitLocked(rpc.EvWorkspaceChanged, ws.structure(), ws, skip)
}

// areaLocked recomputes the workspace's tab area from its viewers: the
// smallest, by width and by height, with the cell size of the viewer
// with the least room. Viewers that gave none don't count, and with
// none left the last area stays.
func (ws *workspace) areaLocked() {
	var a Area
	var least uint64
	for _, v := range ws.viewers {
		if !validArea(v.area) {
			continue
		}
		room := uint64(v.area.Width) * uint64(v.area.Height)
		if a.Width == 0 || room < least {
			least = room
			a.CellW, a.CellH = v.area.CellW, v.area.CellH
		}
		if a.Width == 0 || v.area.Width < a.Width {
			a.Width = v.area.Width
		}
		if a.Height == 0 || v.area.Height < a.Height {
			a.Height = v.area.Height
		}
	}
	if a.Width != 0 {
		ws.area = a
	}
}

// retileLocked sizes a tab's panes from its layout, while no window
// shows it to size them exactly.
func (s *Server) retileLocked(t *tab) {
	if t.ws.attached() || t.root == nil {
		return
	}
	for id, size := range s.measureLocked(t.ws, t.ws.area, t.root, nil) {
		if p := s.panes[id]; p != nil {
			p.resize(nil, size)
		}
	}
}

// measureLocked estimates the panes of a tree in a tab area a: the
// shares divide its pixels and each pane divides its part by its own
// cell size, so panes with different fonts get different grids. A pane
// that hasn't reported a cell size uses the area's; extra gives cells
// for panes not made yet. With no pixel area (no window has given one),
// the shares divide the workspace's grid in cells.
func (s *Server) measureLocked(ws *workspace, a Area, root *Node, extra map[uint32]Size) map[uint32]Size {
	cellOf := func(id uint32) Size {
		if c, ok := extra[id]; ok {
			return c
		}
		if p := s.panes[id]; p != nil {
			return p.cell()
		}
		return Size{}
	}
	out := map[uint32]Size{}
	if validArea(a) {
		grids := Measure(root, a.Width, a.Height, func(id uint32) (uint32, uint32) {
			if c := cellOf(id); c.CellW != 0 && c.CellH != 0 {
				return c.CellW, c.CellH
			}
			return a.CellW, a.CellH
		})
		for id, g := range grids {
			c := cellOf(id)
			if c.CellW == 0 || c.CellH == 0 {
				c.CellW, c.CellH = a.CellW, a.CellH
			}
			out[id] = Size{Cols: g[0], Rows: g[1], CellW: c.CellW, CellH: c.CellH}
		}
		return out
	}
	grid := ws.grid
	if grid.Cols == 0 || grid.Rows == 0 {
		grid = defaultSize
	}
	for id, g := range Measure(root, uint32(grid.Cols), uint32(grid.Rows), func(uint32) (uint32, uint32) { return 1, 1 }) {
		c := cellOf(id)
		out[id] = Size{Cols: g[0], Rows: g[1], CellW: c.CellW, CellH: c.CellH}
	}
	return out
}

// workspaceNew creates a workspace with the tabs asked for, the caller
// a viewer of it, and answers with its structure before anything can
// change it. With attach, the viewers of that workspace are told to
// open the new one once its tabs are up.
func (s *Server) workspaceNew(cl *callCtx, p rpc.WorkspaceNewParams) (*rpc.Workspace, error) {
	if cl.c == nil && len(p.Tabs) == 0 {
		return nil, rpc.Errorf(rpc.CodeInvalidRequest, "workspace.new needs a connection to attach to, or tabs")
	}
	for _, l := range p.Tabs {
		if err := l.Validate(); err != nil {
			return nil, rpc.Errorf(rpc.CodeInvalidParams, "%v", err)
		}
	}
	s.mu.Lock()
	var beside *workspace
	if p.Attach != 0 {
		if beside = s.workspaces[p.Attach]; beside == nil || beside.killed {
			s.mu.Unlock()
			return nil, errNoWorkspace
		}
	}
	ws := &workspace{id: s.newIDLocked(), name: p.Name, viewers: map[*conn]*viewer{}}
	if ws.name == "" {
		ws.name = "default"
	}
	s.workspaces[ws.id] = ws
	if cl.c != nil {
		ws.viewers[cl.c] = &viewer{}
		cl.c.viewing[ws.id] = ws
	}
	s.checkIdleLocked()
	s.log.Info("workspace created", "workspace", ws.id, "name", ws.name)
	s.emitLocked(rpc.EvWorkspaceCreated, rpc.WorkspaceCreatedParams{ID: ws.id, Name: ws.name}, nil, nil)
	if len(p.Tabs) == 0 {
		defer s.mu.Unlock()
		s.openBesideLocked(ws, beside, cl.c)
		cl.reply(ws.structure())
		return nil, nil
	}
	s.mu.Unlock()

	for _, l := range p.Tabs {
		if _, err := s.addTab(cl, ws, "", l, Size{}); err != nil {
			return nil, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workspaces[ws.id] != ws {
		return nil, errNoWorkspace
	}
	// It opens on its first tab, whoever asked.
	if len(ws.tabs) > 0 && s.selectTabLocked(ws, ws.tabs[0]) {
		s.changedLocked(ws, nil)
	}
	s.openBesideLocked(ws, beside, cl.c)
	cl.reply(ws.structure())
	return nil, nil
}

// openBesideLocked tells beside's viewers to open ws too, except the
// caller, which is a viewer already if it has a connection. Nothing
// happens if beside has gone meanwhile.
func (s *Server) openBesideLocked(ws, beside *workspace, caller *conn) {
	if beside == nil || s.workspaces[beside.id] != beside {
		return
	}
	s.emitLocked(rpc.EvWorkspaceOpen, rpc.WorkspaceOpenParams{ID: ws.id, Name: ws.name}, beside, caller)
}

// workspaceAttach adds the caller to a workspace's viewers: each pane,
// sized to the caller's tab area, then the structure, replied under the
// lock so nothing comes between.
func (s *Server) workspaceAttach(cl *callCtx, p rpc.WorkspaceAttachParams) (*rpc.Workspace, error) {
	c := cl.c
	if c == nil {
		return nil, rpc.Errorf(rpc.CodeInvalidRequest, "workspace.attach needs a connection to attach to")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil || ws.killed {
		return nil, errNoWorkspace
	}
	v := &viewer{}
	if validArea(p.Area) {
		v.area = p.Area
	}
	joined := ws.viewers[c] == nil
	ws.viewers[c] = v
	c.viewing[ws.id] = ws
	ws.areaLocked()
	for _, t := range ws.tabs {
		var sizes map[uint32]Size
		if validArea(v.area) {
			sizes = s.measureLocked(ws, v.area, t.root, nil)
		}
		for _, id := range t.root.Panes() {
			pn := s.panes[id]
			if pn == nil {
				continue
			}
			// Without an area, as they are.
			if err := pn.attach(c, sizes[id]); err != nil {
				s.log.Error("attaching pane", "pane", id, "err", err)
			}
		}
	}
	s.log.Info("workspace attached", "workspace", ws.id, "viewers", len(ws.viewers))
	if joined {
		s.emitLocked(rpc.EvWorkspaceViewerJoined, rpc.WorkspaceViewerParams{ID: ws.id, Viewers: len(ws.viewers)}, ws, c)
	}
	cl.reply(ws.structure())
	return nil, nil
}

func (s *Server) workspaceDetach(cl *callCtx, p rpc.WorkspaceParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	s.releaseLocked(ws, cl.c, "")
	return rpc.Empty{}, nil
}

// releaseLocked takes viewer c off a workspace. reason, if set, tells c
// why it lost a workspace it didn't let go of. Once the last viewer is
// gone the daemon sizes the panes, and an empty workspace, with nothing
// to come back to, goes.
func (s *Server) releaseLocked(ws *workspace, c *conn, reason string) {
	if c == nil || ws.viewers[c] == nil {
		return
	}
	for _, t := range ws.tabs {
		for _, id := range t.root.Panes() {
			if p := s.panes[id]; p != nil {
				p.detach(c)
			}
		}
	}
	if reason != "" {
		c.sendForce(0, notify(rpc.EvWorkspaceDetached, rpc.WorkspaceDetachedParams{ID: ws.id, Reason: reason}))
	}
	delete(ws.viewers, c)
	delete(c.viewing, ws.id)
	ws.areaLocked()
	s.log.Info("workspace detached", "workspace", ws.id, "viewers", len(ws.viewers), "reason", reason)
	s.emitLocked(rpc.EvWorkspaceViewerLeft, rpc.WorkspaceViewerParams{ID: ws.id, Viewers: len(ws.viewers)}, ws, c)
	if ws.attached() {
		return
	}
	ws.detachedAt = time.Now()
	if len(ws.tabs) == 0 {
		s.removeWorkspaceLocked(ws)
		return
	}
	// Sizing is the daemon's now: a viewer that never sized its panes (a
	// script) left them as they started.
	for _, t := range ws.tabs {
		s.retileLocked(t)
	}
}

func (s *Server) removeWorkspaceLocked(ws *workspace) {
	delete(s.workspaces, ws.id)
	for c := range ws.viewers {
		delete(c.viewing, ws.id)
	}
	s.checkIdleLocked()
	s.log.Info("workspace removed", "workspace", ws.id)
	s.emitLocked(rpc.EvWorkspaceDestroyed, rpc.WorkspaceDestroyedParams{ID: ws.id}, nil, nil)
}

func (s *Server) workspaceKill(_ *callCtx, p rpc.WorkspaceParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	ws.killed = true
	if len(ws.tabs) == 0 {
		s.killedLocked(ws)
		return rpc.Empty{}, nil
	}
	for _, t := range ws.tabs {
		for _, pid := range t.root.Panes() {
			if pn := s.panes[pid]; pn != nil {
				pn.kill()
			}
		}
	}
	return rpc.Empty{}, nil
}

// killedLocked removes a killed workspace whose panes are gone, telling
// its viewers.
func (s *Server) killedLocked(ws *workspace) {
	if ws.attached() {
		s.emitLocked(rpc.EvWorkspaceDetached, rpc.WorkspaceDetachedParams{ID: ws.id, Reason: "killed"}, ws, nil)
	}
	s.removeWorkspaceLocked(ws)
}

func (s *Server) workspaceRename(_ *callCtx, p rpc.WorkspaceRenameParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	ws.name = p.Name
	s.changedLocked(ws, nil)
	return rpc.Empty{}, nil
}

func (s *Server) workspaceResize(cl *callCtx, p rpc.WorkspaceResizeParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	v := ws.viewers[cl.c]
	if v == nil {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeFailed, "workspace %d isn't attached here", p.ID)
	}
	if !validArea(p.Area) {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "an area needs a width, height, and cell size")
	}
	v.area = p.Area
	ws.areaLocked()
	return rpc.Empty{}, nil
}

// workspaceFocus moves the workspace's focus for every viewer: the
// active tab, a tab's focused pane, and what's zoomed in it.
func (s *Server) workspaceFocus(cl *callCtx, p rpc.WorkspaceFocusParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	var t *tab
	if p.Tab != 0 {
		t = s.tabs[p.Tab]
		if t == nil || t.ws != ws {
			return rpc.Empty{}, errNoTab
		}
	}
	if p.Pane != 0 {
		pn := s.panes[p.Pane]
		if pn == nil || pn.tab == nil || pn.tab.ws != ws {
			return rpc.Empty{}, errNoPane
		}
		if t == nil {
			t = pn.tab
		} else if pn.tab != t {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "pane %d isn't in tab %d", p.Pane, p.Tab)
		}
	}
	if t == nil {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "workspace.focus needs a tab or a pane")
	}
	changed := s.selectTabLocked(ws, t)
	if p.Pane != 0 && t.focus != p.Pane {
		t.focus = p.Pane
		changed = true
	}
	if p.Zoomed != nil && t.zoom != *p.Zoomed {
		if z := *p.Zoomed; z != 0 {
			pn := s.panes[z]
			if pn == nil || pn.tab != t {
				return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "pane %d isn't in tab %d", z, t.id)
			}
		}
		t.zoom = *p.Zoomed
		changed = true
	}
	if changed {
		s.changedLocked(ws, cl.c)
	}
	return rpc.Empty{}, nil
}

// selectTabLocked makes t the workspace's active tab, reporting whether
// that's a change.
func (s *Server) selectTabLocked(ws *workspace, t *tab) bool {
	if ws.active == t {
		return false
	}
	ws.active = t
	if t != nil {
		s.emitLocked(rpc.EvTabSelected, rpc.TabEventParams{Workspace: ws.id, ID: t.id}, nil, nil)
	}
	return true
}

// focusNewLocked gives a pane a viewer just made the focus: its tab is
// shown, unzoomed, with the pane focused. A script's pane takes no
// focus from the user.
func (s *Server) focusNewLocked(cl *callCtx, t *tab, pane uint32) {
	if cl.c == nil || t.ws.viewers[cl.c] == nil {
		return
	}
	s.selectTabLocked(t.ws, t)
	t.focus = pane
	t.zoom = 0
}

func (s *Server) workspaceInfo(_ *callCtx, p rpc.WorkspaceParams) (*rpc.WorkspaceDesc, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return nil, errNoWorkspace
	}
	d := ws.desc()
	return &d, nil
}

// validArea says whether a has the pixels and cell size to measure by.
func validArea(a Area) bool {
	return a.Width != 0 && a.Height != 0 && a.CellW != 0 && a.CellH != 0
}

// tabNew starts a tab: a layout's panes, or one. The viewers get each
// pane's pane.attached, then the structure; the caller gets what was
// made.
func (s *Server) tabNew(cl *callCtx, m rpc.TabNewParams) (*rpc.Created, error) {
	l := m.Layout
	if l == nil {
		l = &rpc.Layout{Pane: &rpc.PaneSpec{Command: m.Command, Cwd: m.Cwd, Env: m.Env}}
	}
	if err := l.Validate(); err != nil {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "%v", err)
	}
	s.mu.Lock()
	ws := s.workspaces[m.Workspace]
	s.mu.Unlock()
	if ws == nil || ws.killed {
		return nil, errNoWorkspace
	}
	return s.addTab(cl, ws, m.Name, l, m.Size)
}

// started is a pane's child and terminal, running before the pane is
// made, in case what it was for is gone by then.
type started struct {
	id   uint32
	spec *rpc.PaneSpec
	size Size
	pty  pty.Pty
	term *vt.Terminal
}

func (st *started) close() {
	st.pty.Close()
	st.term.Close()
}

// addTab starts l's panes, outside the lock, and adds them to ws as a
// tab. size, if given, is a single pane's; else the panes are measured
// in the workspace's tab area.
func (s *Server) addTab(cl *callCtx, ws *workspace, name string, l *rpc.Layout, size Size) (*rpc.Created, error) {
	s.mu.Lock()
	// Ids first: a pane's environment names it.
	root, specs := s.layoutTreeLocked(l)
	sizes := s.measureLocked(ws, ws.area, root, nil)
	if l.IsLeaf() && size.Cols != 0 && size.Rows != 0 {
		sizes[root.Pane] = size
	}
	s.mu.Unlock()

	var panes []*started
	for _, id := range root.Panes() {
		st, err := s.startPane(id, ws.id, specs[id], sizes[id])
		if err != nil {
			for _, p := range panes {
				p.close()
			}
			return nil, err
		}
		panes = append(panes, st)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workspaces[ws.id] != ws || ws.killed {
		for _, p := range panes {
			p.close()
		}
		return nil, errNoWorkspace
	}
	// A size from a window says what its tab area is, if nothing has.
	if l.IsLeaf() && !validArea(ws.area) {
		if size.CellW != 0 && size.CellH != 0 {
			ws.area = Area{
				Width:  uint32(size.Cols) * size.CellW,
				Height: uint32(size.Rows) * size.CellH,
				CellW:  size.CellW,
				CellH:  size.CellH,
			}
		} else if ws.grid.Cols == 0 && size.Cols != 0 {
			ws.grid = size
		}
	}
	t := &tab{id: s.newIDLocked(), ws: ws, name: name, root: root, focus: root.Panes()[0]}
	s.tabs[t.id] = t
	ws.tabs = append(ws.tabs, t)
	if ws.active == nil {
		ws.active = t
	}
	s.emitLocked(rpc.EvTabCreated, rpc.TabEventParams{Workspace: ws.id, ID: t.id, Name: t.name}, nil, nil)
	for _, st := range panes {
		s.addPaneLocked(t, st)
	}
	s.checkIdleLocked()
	s.log.Info("tab started", "workspace", ws.id, "tab", t.id, "panes", root.Panes())
	s.focusNewLocked(cl, t, t.focus)
	s.changedLocked(ws, nil)
	return &rpc.Created{Workspace: ws.id, Tab: t.id, Pane: t.focus}, nil
}

// layoutTreeLocked gives each of l's leaves a pane id, returning the
// tree of ids and what each runs.
func (s *Server) layoutTreeLocked(l *rpc.Layout) (*Node, map[uint32]*rpc.PaneSpec) {
	specs := map[uint32]*rpc.PaneSpec{}
	var build func(l *rpc.Layout) *Node
	build = func(l *rpc.Layout) *Node {
		if l.IsLeaf() {
			id := s.newIDLocked()
			specs[id] = l.Pane
			return leaf(id)
		}
		n := &Node{Axis: l.Axis}
		for _, c := range l.Children {
			n.Children = append(n.Children, Child{Share: c.Share, Node: build(c.Node)})
		}
		return n
	}
	return build(l), specs
}

// addPaneLocked makes the pane of a started child in tab t, attaches
// it to the tab's viewers, and starts it running.
func (s *Server) addPaneLocked(t *tab, st *started) *Pane {
	p := newPane(s, st.id, st.spec.Command, st.size, st.pty, st.term)
	p.tab = t
	s.panes[p.id] = p
	ws := t.ws
	s.log.Info("pane started", "workspace", ws.id, "tab", t.id, "pane", p.id, "command", st.spec.Command, "pid", st.pty.PID())
	s.emitLocked(rpc.EvPaneCreated, rpc.PaneCreatedParams{Workspace: ws.id, Tab: t.id, ID: p.id}, nil, nil)
	for c := range ws.viewers {
		p.attach(c, Size{})
	}
	go p.run()
	return p
}

// paneEnv is what every pane's environment says about itself: the pane
// it is, the workspace it's in, and the daemon it belongs to
// (SLIME_INSTANCE, when the daemon is one), so the CLI and scripts run
// in it act on them by default.
func paneEnv(id, ws uint32, spec *rpc.PaneSpec) map[string]string {
	env := make(map[string]string, len(spec.Env)+3)
	for k, v := range spec.Env {
		env[k] = v
	}
	env["SLIME_PANE"] = strconv.FormatUint(uint64(id), 10)
	env["SLIME_WORKSPACE"] = strconv.FormatUint(uint64(ws), 10)
	if inst := os.Getenv("SLIME_INSTANCE"); inst != "" {
		env["SLIME_INSTANCE"] = inst
	}
	return env
}

// paneSplit starts a pane beside another. Replies as tabNew does.
func (s *Server) paneSplit(cl *callCtx, m rpc.PaneSplitParams) (*rpc.Created, error) {
	if m.Direction < Right || m.Direction > Up {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "direction is right, down, left, or up")
	}
	if m.Share == 0 || m.Share >= Whole {
		m.Share = Whole / 2
	}
	// Estimate the new pane's size from the tree as it would be.
	s.mu.Lock()
	target := s.panes[m.Pane]
	if target == nil || target.tab == nil {
		s.mu.Unlock()
		return nil, errNoPane
	}
	t := target.tab
	id := s.newIDLocked()
	trial, err := splitNode(t.root.Clone(), m.Pane, id, m.Direction, m.Share)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	// The new pane takes its neighbour's cell size, as a split takes its
	// font.
	size := s.measureLocked(t.ws, t.ws.area, trial, map[uint32]Size{id: target.cell()})[id]
	s.mu.Unlock()

	st, err := s.startPane(id, t.ws.id, &rpc.PaneSpec{Command: m.Command, Cwd: m.Cwd, Env: m.Env}, size)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// The tree may have changed while the child started.
	if s.panes[m.Pane] != target || target.tab != t || s.tabs[t.id] != t {
		st.close()
		return nil, errNoPane
	}
	root, err := splitNode(t.root, m.Pane, id, m.Direction, m.Share)
	if err != nil {
		st.close()
		return nil, err
	}
	t.root = root
	s.addPaneLocked(t, st)
	s.log.Info("pane split", "tab", t.id, "pane", id, "beside", m.Pane)
	ws := t.ws
	s.focusNewLocked(cl, t, id)
	s.retileLocked(t)
	s.changedLocked(ws, nil)
	return &rpc.Created{Workspace: ws.id, Tab: t.id, Pane: id}, nil
}

// paneMove takes a pane out of its tab and puts it along a side of
// another, or of a new tab after its own.
func (s *Server) paneMove(cl *callCtx, m rpc.PaneMoveParams) (*rpc.Created, error) {
	if m.Side == 0 {
		m.Side = Right
	}
	if m.Side < Right || m.Side > Up {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "side is right, down, left, or up")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	pn := s.panes[m.Pane]
	if pn == nil || pn.tab == nil {
		return nil, errNoPane
	}
	src := pn.tab
	ws := src.ws
	var dst *tab
	if m.Tab != 0 {
		dst = s.tabs[m.Tab]
		if dst == nil {
			return nil, errNoTab
		}
		if dst.ws != ws {
			return nil, rpc.Errorf(rpc.CodeInvalidParams, "tab %d is in another workspace", m.Tab)
		}
	}
	if dst == src && src.root.IsLeaf() {
		// Alone in its tab already.
		return &rpc.Created{Workspace: ws.id, Tab: src.id, Pane: pn.id}, nil
	}
	if dst == nil {
		if src.root.IsLeaf() {
			return &rpc.Created{Workspace: ws.id, Tab: src.id, Pane: pn.id}, nil
		}
		dst = &tab{id: s.newIDLocked(), ws: ws}
		s.tabs[dst.id] = dst
		at := len(ws.tabs)
		for i, t := range ws.tabs {
			if t == src {
				at = i + 1
				break
			}
		}
		ws.tabs = append(ws.tabs[:at], append([]*tab{dst}, ws.tabs[at:]...)...)
		s.emitLocked(rpc.EvTabCreated, rpc.TabEventParams{Workspace: ws.id, ID: dst.id}, nil, nil)
	}

	s.takePaneLocked(src, pn.id)
	if dst.root == nil {
		dst.root = leaf(pn.id)
	} else {
		dst.root = joinEdge(dst.root, pn.id, m.Side)
	}
	pn.tab = dst
	if dst.focus == 0 {
		dst.focus = pn.id
	}
	s.log.Info("pane moved", "pane", pn.id, "from", src.id, "to", dst.id)
	if src.root == nil {
		s.removeTabLocked(src)
	} else {
		s.retileLocked(src)
	}
	s.focusNewLocked(cl, dst, pn.id)
	s.retileLocked(dst)
	s.changedLocked(ws, nil)
	return &rpc.Created{Workspace: ws.id, Tab: dst.id, Pane: pn.id}, nil
}

// takePaneLocked removes pane from t's tree, moving the tab's focus
// and zoom off it: to the pane before it in layout order, or the one
// after. The tree is nil once its last pane goes.
func (s *Server) takePaneLocked(t *tab, pane uint32) {
	panes := t.root.Panes()
	t.root = removeNode(t.root, pane)
	if t.zoom == pane {
		t.zoom = 0
	}
	if t.focus != pane || t.root == nil {
		return
	}
	for i, id := range panes {
		if id != pane {
			continue
		}
		if i > 0 {
			t.focus = panes[i-1]
		} else {
			t.focus = panes[i+1]
		}
		return
	}
}

// tabLayout replaces a tab's proportions: a divider was dragged.
func (s *Server) tabLayout(_ *callCtx, m rpc.TabLayoutParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[m.ID]
	if t == nil {
		return rpc.Empty{}, errNoTab
	}
	if err := Validate(m.Tree, t.root.Panes()); err != nil {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "%v", err)
	}
	t.root = m.Tree
	s.retileLocked(t)
	s.changedLocked(t.ws, nil)
	return rpc.Empty{}, nil
}

// tabClose ends a tab's panes. The tab goes now; their exits follow.
func (s *Server) tabClose(_ *callCtx, p rpc.TabParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return rpc.Empty{}, errNoTab
	}
	for _, pid := range t.root.Panes() {
		if pn := s.panes[pid]; pn != nil {
			pn.tab = nil
			pn.kill()
		}
	}
	ws := t.ws
	if s.removeTabLocked(t) {
		s.changedLocked(ws, nil)
	}
	return rpc.Empty{}, nil
}

func (s *Server) tabRename(_ *callCtx, p rpc.TabRenameParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return rpc.Empty{}, errNoTab
	}
	t.name = p.Name
	s.emitLocked(rpc.EvTabRenamed, rpc.TabEventParams{Workspace: t.ws.id, ID: t.id, Name: t.name}, nil, nil)
	s.changedLocked(t.ws, nil)
	return rpc.Empty{}, nil
}

func (s *Server) tabInfo(_ *callCtx, p rpc.TabParams) (*rpc.TabInfoResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return nil, errNoTab
	}
	return &rpc.TabInfoResult{Workspace: t.ws.id, Tab: t.info()}, nil
}

// removeTabLocked takes a tab out of its workspace, moving the active
// tab to the one in its place (or the last). It reports whether the
// workspace is still there to send a structure of: a killed or
// unviewed workspace left with no tabs goes with it.
func (s *Server) removeTabLocked(t *tab) bool {
	delete(s.tabs, t.id)
	ws := t.ws
	for i, x := range ws.tabs {
		if x == t {
			ws.tabs = append(ws.tabs[:i], ws.tabs[i+1:]...)
			if ws.active == t {
				var next *tab
				if len(ws.tabs) > 0 {
					next = ws.tabs[min(i, len(ws.tabs)-1)]
				}
				s.selectTabLocked(ws, next)
			}
			break
		}
	}
	s.emitLocked(rpc.EvTabClosed, rpc.TabEventParams{Workspace: ws.id, ID: t.id}, nil, nil)
	switch {
	case len(ws.tabs) > 0:
		return true
	case ws.killed:
		s.killedLocked(ws)
	case !ws.attached():
		// Nothing left to come back to.
		s.removeWorkspaceLocked(ws)
	default:
		return true
	}
	return false
}

// paneExited takes a pane whose child is gone out of its tab: the tree
// closes over it, an empty tab goes, and the viewers hear. told are
// the viewers the pane told itself; the subscribers hear here.
func (s *Server) paneExited(p *Pane, status uint32, told []*conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.panes, p.id)
	defer s.checkIdleLocked()
	s.emitLocked(rpc.EvPaneExited, rpc.PaneExitedParams{ID: p.id, Status: status}, nil, told...)
	t := p.tab
	if t == nil || s.tabs[t.id] != t {
		return
	}
	s.takePaneLocked(t, p.id)
	if t.root == nil {
		if s.removeTabLocked(t) {
			s.changedLocked(t.ws, nil)
		}
		return
	}
	s.retileLocked(t)
	s.changedLocked(t.ws, nil)
}

func (s *Server) paneKill(_ *callCtx, p rpc.PaneParams) (rpc.Empty, error) {
	pn := s.pane(p.ID)
	if pn == nil {
		return rpc.Empty{}, errNoPane
	}
	pn.kill()
	return rpc.Empty{}, nil
}

func (s *Server) paneWrite(_ *callCtx, p rpc.PaneWriteParams) (rpc.Empty, error) {
	pn := s.pane(p.ID)
	if pn == nil {
		return rpc.Empty{}, errNoPane
	}
	return rpc.Empty{}, pn.write([]byte(p.Text))
}

func (s *Server) paneText(_ *callCtx, p rpc.PaneTextParams) (*rpc.PaneTextResult, error) {
	pn := s.pane(p.ID)
	if pn == nil {
		return nil, errNoPane
	}
	text, err := pn.text(p.VT)
	if err != nil {
		return nil, err
	}
	return &rpc.PaneTextResult{Text: text}, nil
}

func (s *Server) paneInfo(_ *callCtx, p rpc.PaneParams) (*rpc.PaneDesc, error) {
	s.mu.Lock()
	pn := s.panes[p.ID]
	var t *tab
	if pn != nil {
		t = pn.tab
	}
	s.mu.Unlock()
	if pn == nil {
		return nil, errNoPane
	}
	d := pn.desc(t)
	return &d, nil
}
