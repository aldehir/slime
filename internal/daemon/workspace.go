package daemon

import (
	"errors"
	"time"

	"github.com/aldehir/slime/internal/rpc"
)

// workspace is a named, ordered set of tabs, attached by at most one
// window (its owner) at a time.
type workspace struct {
	id    uint32
	name  string
	tabs  []*tab
	owner *conn
	// When it was last detached, to pick the most recent for a new
	// window.
	detachedAt time.Time
	// The tab area the owner last gave, in pixels, for estimating pane
	// sizes. Before any window has (a script built it), grid is the tab's
	// size in cells instead.
	area Area
	grid Size
	// Killed: it goes once its panes have.
	killed bool
}

// tab is a layout tree of panes.
type tab struct {
	id   uint32
	ws   *workspace
	name string
	root *Node
}

var (
	errNoWorkspace = errors.New("no such workspace")
	errNoTab       = errors.New("no such tab")
	errNoPane      = errors.New("no such pane")
	errNoHost      = errors.New("no such host")
)

func (ws *workspace) tabInfos() []rpc.Tab {
	infos := make([]rpc.Tab, len(ws.tabs))
	for i, t := range ws.tabs {
		infos[i] = rpc.Tab{ID: t.id, Name: t.name, Tree: t.root.Clone()}
	}
	return infos
}

// structure is the workspace as workspace.changed carries it.
func (ws *workspace) structure() *rpc.Workspace {
	return &rpc.Workspace{ID: ws.id, Name: ws.name, Tabs: ws.tabInfos()}
}

func (ws *workspace) desc() rpc.WorkspaceDesc {
	d := rpc.WorkspaceDesc{ID: ws.id, Name: ws.name, Attached: ws.owner != nil, Tabs: ws.tabInfos()}
	if !ws.detachedAt.IsZero() && ws.owner == nil {
		d.DetachedAt = ws.detachedAt.UnixMilli()
	}
	return d
}

// changedLocked sends the owner, if any, and the subscribers the
// workspace's structure.
func (s *Server) changedLocked(ws *workspace) {
	s.emitLocked(rpc.EvWorkspaceChanged, ws.structure(), ws, nil)
}

// retileLocked sizes a tab's panes from its layout, while no window
// shows it to size them exactly.
func (s *Server) retileLocked(t *tab) {
	if t.ws.owner != nil || t.root == nil {
		return
	}
	for id, size := range s.measureLocked(t.ws, t.root, nil) {
		if p := s.panes[id]; p != nil {
			p.resize(nil, size)
		}
	}
}

// measureLocked estimates the panes of a tree in ws's tab area: the
// shares divide its pixels and each pane divides its part by its own
// cell size, so panes with different fonts get different grids. A pane
// that hasn't reported a cell size uses the area's; extra gives cells
// for panes not made yet. With no pixel area (no window has attached),
// the shares divide the tab's grid in cells.
func (s *Server) measureLocked(ws *workspace, root *Node, extra map[uint32]Size) map[uint32]Size {
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
	if a := ws.area; a.Width != 0 && a.Height != 0 && a.CellW != 0 && a.CellH != 0 {
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

// workspaceNew creates an empty workspace attached to the caller, and
// answers with its structure before anything can change it.
func (s *Server) workspaceNew(cl *callCtx, p rpc.WorkspaceNewParams) (*rpc.Workspace, error) {
	if cl.c == nil {
		return nil, rpc.Errorf(rpc.CodeInvalidRequest, "workspace.new needs a connection to attach to")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := &workspace{id: s.newIDLocked(), name: p.Name, owner: cl.c}
	if ws.name == "" {
		ws.name = "default"
	}
	s.workspaces[ws.id] = ws
	cl.c.owned[ws.id] = ws
	s.checkIdleLocked()
	s.log.Info("workspace created", "workspace", ws.id, "name", ws.name)
	s.emitLocked(rpc.EvWorkspaceCreated, rpc.WorkspaceCreatedParams{ID: ws.id, Name: ws.name}, nil, nil)
	cl.reply(ws.structure())
	return nil, nil
}

// workspaceAttach gives a workspace to the caller: each pane, sized to
// the window's tab area, then the structure, replied under the lock so
// nothing comes between.
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
	if old := ws.owner; old != nil && old != c {
		s.releaseLocked(ws, "attached elsewhere")
	}
	ws.owner = c
	c.owned[ws.id] = ws
	given := validArea(p.Area)
	if given {
		ws.area = p.Area
	}
	for _, t := range ws.tabs {
		var sizes map[uint32]Size
		if given {
			sizes = s.measureLocked(ws, t.root, nil)
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
	s.log.Info("workspace attached", "workspace", ws.id)
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
	if ws.owner == cl.c {
		s.releaseLocked(ws, "")
	}
	return rpc.Empty{}, nil
}

// releaseLocked detaches a workspace from its owner. reason, if set,
// tells the owner why it lost a workspace it didn't let go of. An empty
// workspace has nothing to come back to, and goes.
func (s *Server) releaseLocked(ws *workspace, reason string) {
	c := ws.owner
	if c == nil {
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
		s.emitLocked(rpc.EvWorkspaceDetached, rpc.WorkspaceDetachedParams{ID: ws.id, Reason: reason}, ws, nil)
	}
	delete(c.owned, ws.id)
	ws.owner = nil
	ws.detachedAt = time.Now()
	s.log.Info("workspace detached", "workspace", ws.id, "reason", reason)
	if len(ws.tabs) == 0 {
		s.removeWorkspaceLocked(ws)
		return
	}
	// Sizing is the daemon's now: an owner that never sized its panes (a
	// script) left them as they started.
	for _, t := range ws.tabs {
		s.retileLocked(t)
	}
}

func (s *Server) removeWorkspaceLocked(ws *workspace) {
	delete(s.workspaces, ws.id)
	if ws.owner != nil {
		delete(ws.owner.owned, ws.id)
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
// its owner.
func (s *Server) killedLocked(ws *workspace) {
	if ws.owner != nil {
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
	s.changedLocked(ws)
	return rpc.Empty{}, nil
}

func (s *Server) workspaceResize(cl *callCtx, p rpc.WorkspaceResizeParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	if ws.owner != cl.c {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeFailed, "workspace %d isn't attached here", p.ID)
	}
	if !validArea(p.Area) {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "an area needs a width, height, and cell size")
	}
	ws.area = p.Area
	return rpc.Empty{}, nil
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

// tabNew starts a tab with one pane. Its owner gets the pane's
// pane.attached, then the structure; the caller gets what was made.
func (s *Server) tabNew(_ *callCtx, m rpc.TabNewParams) (*rpc.Created, error) {
	s.mu.Lock()
	ws := s.workspaces[m.Workspace]
	size := m.Size
	if ws != nil && (size.Cols == 0 || size.Rows == 0) {
		// The whole tab area, in the area's cells.
		size = s.measureLocked(ws, leaf(^uint32(0)), nil)[^uint32(0)]
	}
	s.mu.Unlock()
	if ws == nil || ws.killed {
		return nil, errNoWorkspace
	}

	pt, term, err := s.startPane(m.Command, m.Cwd, size)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workspaces[m.Workspace] != ws || ws.killed {
		pt.Close()
		term.Close()
		return nil, errNoWorkspace
	}
	if size.Cols == 0 || size.Rows == 0 {
		size = Size{Cols: defaultSize.Cols, Rows: defaultSize.Rows, CellW: size.CellW, CellH: size.CellH}
	}
	// A size from a window says what its tab area is, if nothing has.
	if !validArea(ws.area) {
		if size.CellW != 0 && size.CellH != 0 {
			ws.area = Area{
				Width:  uint32(size.Cols) * size.CellW,
				Height: uint32(size.Rows) * size.CellH,
				CellW:  size.CellW,
				CellH:  size.CellH,
			}
		} else if ws.grid.Cols == 0 {
			ws.grid = size
		}
	}
	p := newPane(s, s.newIDLocked(), m.Command, size, pt, term)
	t := &tab{id: s.newIDLocked(), ws: ws, root: leaf(p.id)}
	p.tab = t
	s.panes[p.id] = p
	s.tabs[t.id] = t
	ws.tabs = append(ws.tabs, t)
	s.checkIdleLocked()
	s.log.Info("tab started", "workspace", ws.id, "tab", t.id, "pane", p.id, "command", m.Command, "pid", pt.PID())
	s.emitLocked(rpc.EvTabCreated, rpc.TabEventParams{Workspace: ws.id, ID: t.id}, nil, nil)
	s.emitLocked(rpc.EvPaneCreated, rpc.PaneCreatedParams{Workspace: ws.id, Tab: t.id, ID: p.id}, nil, nil)
	if ws.owner != nil {
		p.attach(ws.owner, Size{})
	}
	s.changedLocked(ws)
	go p.run()
	return &rpc.Created{Workspace: ws.id, Tab: t.id, Pane: p.id}, nil
}

// paneSplit starts a pane beside another. Replies as tabNew does.
func (s *Server) paneSplit(_ *callCtx, m rpc.PaneSplitParams) (*rpc.Created, error) {
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
	trial, err := splitNode(t.root.Clone(), m.Pane, ^uint32(0), m.Direction, m.Share)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	// The new pane takes its neighbour's cell size, as a split takes its
	// font.
	size := s.measureLocked(t.ws, trial, map[uint32]Size{^uint32(0): target.cell()})[^uint32(0)]
	s.mu.Unlock()

	pt, term, err := s.startPane(m.Command, m.Cwd, size)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// The tree may have changed while the child started.
	if s.panes[m.Pane] != target || target.tab != t || s.tabs[t.id] != t {
		pt.Close()
		term.Close()
		return nil, errNoPane
	}
	id := s.newIDLocked()
	root, err := splitNode(t.root, m.Pane, id, m.Direction, m.Share)
	if err != nil {
		pt.Close()
		term.Close()
		return nil, err
	}
	t.root = root
	p := newPane(s, id, m.Command, size, pt, term)
	p.tab = t
	s.panes[id] = p
	s.log.Info("pane split", "tab", t.id, "pane", id, "beside", m.Pane, "command", m.Command, "pid", pt.PID())
	ws := t.ws
	s.emitLocked(rpc.EvPaneCreated, rpc.PaneCreatedParams{Workspace: ws.id, Tab: t.id, ID: id}, nil, nil)
	if ws.owner != nil {
		p.attach(ws.owner, Size{})
	}
	s.retileLocked(t)
	s.changedLocked(ws)
	go p.run()
	return &rpc.Created{Workspace: ws.id, Tab: t.id, Pane: id}, nil
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
	s.changedLocked(t.ws)
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
	s.removeTabLocked(t)
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
	s.changedLocked(t.ws)
	return rpc.Empty{}, nil
}

func (s *Server) tabInfo(_ *callCtx, p rpc.TabParams) (*rpc.TabInfoResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return nil, errNoTab
	}
	return &rpc.TabInfoResult{Workspace: t.ws.id, Tab: rpc.Tab{ID: t.id, Name: t.name, Tree: t.root.Clone()}}, nil
}

func (s *Server) removeTabLocked(t *tab) {
	delete(s.tabs, t.id)
	ws := t.ws
	for i, x := range ws.tabs {
		if x == t {
			ws.tabs = append(ws.tabs[:i], ws.tabs[i+1:]...)
			break
		}
	}
	s.emitLocked(rpc.EvTabClosed, rpc.TabEventParams{Workspace: ws.id, ID: t.id}, nil, nil)
	s.changedLocked(ws)
	switch {
	case len(ws.tabs) > 0:
	case ws.killed:
		s.killedLocked(ws)
	case ws.owner == nil:
		// Nothing left to come back to.
		s.removeWorkspaceLocked(ws)
	}
}

// paneExited takes a pane whose child is gone out of its tab: the tree
// closes over it, an empty tab goes, and the owner hears. viewer is the
// client the pane told itself, if any; the subscribers hear here.
func (s *Server) paneExited(p *Pane, status uint32, viewer *conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.panes, p.id)
	defer s.checkIdleLocked()
	s.emitLocked(rpc.EvPaneExited, rpc.PaneExitedParams{ID: p.id, Status: status}, nil, viewer)
	t := p.tab
	if t == nil || s.tabs[t.id] != t {
		return
	}
	t.root = removeNode(t.root, p.id)
	if t.root == nil {
		s.removeTabLocked(t)
		return
	}
	s.retileLocked(t)
	s.changedLocked(t.ws)
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
