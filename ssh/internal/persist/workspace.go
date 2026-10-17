package persist

import (
	"errors"
	"time"
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
)

func (ws *workspace) tabInfos() []TabInfo {
	infos := make([]TabInfo, len(ws.tabs))
	for i, t := range ws.tabs {
		infos[i] = TabInfo{ID: t.id, Name: t.name, Tree: t.root.Clone()}
	}
	return infos
}

func (ws *workspace) message(tag uint32) *Workspace {
	return &Workspace{Tag: tag, ID: ws.id, Name: ws.name, Tabs: ws.tabInfos()}
}

// notifyLocked sends the owner, if any, the workspace's structure.
func (s *Server) notifyLocked(ws *workspace, tag uint32) {
	if ws.owner != nil {
		ws.owner.sendForce(0, ws.message(tag))
	}
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

func (s *Server) workspaceNew(c *conn, m *WorkspaceNew) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := &workspace{id: s.newIDLocked(), name: m.Name, owner: c}
	if ws.name == "" {
		ws.name = "default"
	}
	s.workspaces[ws.id] = ws
	c.owned[ws.id] = ws
	s.checkIdleLocked()
	s.log.Info("workspace created", "workspace", ws.id, "name", ws.name)
	c.sendForce(0, ws.message(m.Tag))
	c.sendForce(0, &Created{Tag: m.Tag, WS: ws.id})
}

// workspaceAttach gives a workspace to c: each pane's snapshot, sized to
// the window's tab area, then the structure.
func (s *Server) workspaceAttach(c *conn, m *WorkspaceAttach) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[m.WS]
	if ws == nil || ws.killed {
		return errNoWorkspace
	}
	if old := ws.owner; old != nil && old != c {
		s.releaseLocked(ws, "attached elsewhere")
	}
	ws.owner = c
	c.owned[ws.id] = ws
	given := validArea(m.Area)
	if given {
		ws.area = m.Area
	}
	for _, t := range ws.tabs {
		var sizes map[uint32]Size
		if given {
			sizes = s.measureLocked(ws, t.root, nil)
		}
		for _, id := range t.root.Panes() {
			p := s.panes[id]
			if p == nil {
				continue
			}
			// Without an area, as they are.
			if err := p.attach(c, sizes[id]); err != nil {
				s.log.Error("attaching pane", "pane", id, "err", err)
			}
		}
	}
	s.log.Info("workspace attached", "workspace", ws.id)
	c.sendForce(0, ws.message(m.Tag))
	return nil
}

func (s *Server) workspaceDetach(c *conn, id uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ws := s.workspaces[id]; ws != nil && ws.owner == c {
		s.releaseLocked(ws, "")
	}
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
		c.sendForce(0, &Detached{WS: ws.id, Reason: reason})
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
}

func (s *Server) workspaceKill(id uint32) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[id]
	if ws == nil {
		return errNoWorkspace
	}
	ws.killed = true
	if len(ws.tabs) == 0 {
		if ws.owner != nil {
			ws.owner.sendForce(0, &Detached{WS: ws.id, Reason: "killed"})
		}
		s.removeWorkspaceLocked(ws)
		return nil
	}
	for _, t := range ws.tabs {
		for _, pid := range t.root.Panes() {
			if p := s.panes[pid]; p != nil {
				p.kill()
			}
		}
	}
	return nil
}

func (s *Server) workspaceRename(id uint32, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[id]
	if ws == nil {
		return errNoWorkspace
	}
	ws.name = name
	s.notifyLocked(ws, 0)
	return nil
}

func (s *Server) workspaceResize(c *conn, m *WorkspaceResize) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ws := s.workspaces[m.WS]; ws != nil && ws.owner == c && validArea(m.Area) {
		ws.area = m.Area
	}
}

// validArea says whether a has the pixels and cell size to measure by.
func validArea(a Area) bool {
	return a.Width != 0 && a.Height != 0 && a.CellW != 0 && a.CellH != 0
}

// tabNew starts a tab with one pane. Its owner gets the pane's snapshot,
// then the structure; the sender gets Created.
func (s *Server) tabNew(c *conn, m *TabNew) error {
	s.mu.Lock()
	ws := s.workspaces[m.WS]
	size := m.Size
	if ws != nil && (size.Cols == 0 || size.Rows == 0) {
		// The whole tab area, in the area's cells.
		size = s.measureLocked(ws, leaf(^uint32(0)), nil)[^uint32(0)]
	}
	s.mu.Unlock()
	if ws == nil || ws.killed {
		return errNoWorkspace
	}

	pt, term, err := s.startPane(m.Command, m.Cwd, size)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workspaces[m.WS] != ws || ws.killed {
		pt.Close()
		term.Close()
		return errNoWorkspace
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
	if ws.owner != nil {
		p.attach(ws.owner, Size{})
	}
	s.notifyLocked(ws, m.Tag)
	c.sendForce(0, &Created{Tag: m.Tag, WS: ws.id, Tab: t.id, Pane: p.id})
	go p.run()
	return nil
}

// split starts a pane beside another. Replies as tabNew does.
func (s *Server) split(c *conn, m *Split) error {
	if m.Dir < Right || m.Dir > Up {
		return errors.New("bad split direction")
	}
	if m.Share == 0 || m.Share >= Whole {
		m.Share = Whole / 2
	}
	// Estimate the new pane's size from the tree as it would be.
	s.mu.Lock()
	target := s.panes[m.Pane]
	if target == nil || target.tab == nil {
		s.mu.Unlock()
		return errNoPane
	}
	t := target.tab
	trial, err := splitNode(t.root.Clone(), m.Pane, ^uint32(0), m.Dir, m.Share)
	if err != nil {
		s.mu.Unlock()
		return err
	}
	// The new pane takes its neighbour's cell size, as a split takes its
	// font.
	size := s.measureLocked(t.ws, trial, map[uint32]Size{^uint32(0): target.cell()})[^uint32(0)]
	s.mu.Unlock()

	pt, term, err := s.startPane(m.Command, m.Cwd, size)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// The tree may have changed while the child started.
	if s.panes[m.Pane] != target || target.tab != t || s.tabs[t.id] != t {
		pt.Close()
		term.Close()
		return errNoPane
	}
	id := s.newIDLocked()
	root, err := splitNode(t.root, m.Pane, id, m.Dir, m.Share)
	if err != nil {
		pt.Close()
		term.Close()
		return err
	}
	t.root = root
	p := newPane(s, id, m.Command, size, pt, term)
	p.tab = t
	s.panes[id] = p
	s.log.Info("pane split", "tab", t.id, "pane", id, "beside", m.Pane, "command", m.Command, "pid", pt.PID())
	ws := t.ws
	if ws.owner != nil {
		p.attach(ws.owner, Size{})
	}
	s.retileLocked(t)
	s.notifyLocked(ws, m.Tag)
	c.sendForce(0, &Created{Tag: m.Tag, WS: ws.id, Tab: t.id, Pane: id})
	go p.run()
	return nil
}

// layout replaces a tab's proportions: a divider was dragged.
func (s *Server) layout(m *Layout) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[m.Tab]
	if t == nil {
		return errNoTab
	}
	if err := Validate(m.Tree, t.root.Panes()); err != nil {
		return err
	}
	t.root = m.Tree
	s.retileLocked(t)
	s.notifyLocked(t.ws, 0)
	return nil
}

// tabClose ends a tab's panes. The tab goes now; their exits follow.
func (s *Server) tabClose(id uint32) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[id]
	if t == nil {
		return errNoTab
	}
	for _, pid := range t.root.Panes() {
		if p := s.panes[pid]; p != nil {
			p.tab = nil
			p.kill()
		}
	}
	s.removeTabLocked(t)
	return nil
}

func (s *Server) tabRename(id uint32, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[id]
	if t == nil {
		return errNoTab
	}
	t.name = name
	s.notifyLocked(t.ws, 0)
	return nil
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
	s.notifyLocked(ws, 0)
	switch {
	case len(ws.tabs) > 0:
	case ws.killed:
		if ws.owner != nil {
			ws.owner.sendForce(0, &Detached{WS: ws.id, Reason: "killed"})
		}
		s.removeWorkspaceLocked(ws)
	case ws.owner == nil:
		// Nothing left to come back to.
		s.removeWorkspaceLocked(ws)
	}
}

// paneExited takes a pane whose child is gone out of its tab: the tree
// closes over it, an empty tab goes, and the owner hears.
func (s *Server) paneExited(p *Pane) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.panes, p.id)
	defer s.checkIdleLocked()
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
	s.notifyLocked(t.ws, 0)
}
