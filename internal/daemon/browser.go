package daemon

import (
	"sync"
	"time"

	"github.com/aldehir/slime/internal/rpc"
)

// BrowserPane is a pane a window's browser fills. The page, its
// history, and the browser are each window's; the daemon keeps the url
// and title, to open the pane with and to relay between its viewers
// (pane.navigate, pane.visited), and nothing else. It has no child, no
// goroutine, and sends no frames.
type BrowserPane struct {
	// As Pane's: written under the server's lock and the pane's, read
	// under either.
	id      PaneID
	srv     *Server
	created time.Time

	// The tab it's in. Guarded by the server's lock.
	tab *tab

	mu      sync.Mutex
	url     string
	title   string
	viewers map[*conn]struct{}
	done    bool
}

func newBrowserPane(srv *Server, id PaneID, url string) *BrowserPane {
	return &BrowserPane{id: id, srv: srv, created: time.Now(), url: url, viewers: map[*conn]struct{}{}}
}

// errNotTerminal answers a terminal's method on a browser pane.
func errNotTerminal(id PaneID) error {
	return rpc.Errorf(rpc.CodeInvalidParams, "pane %s is a browser, not a terminal", id)
}

func (b *BrowserPane) paneID() PaneID { return b.id }
func (b *BrowserPane) tabOf() *tab    { return b.tab }
func (b *BrowserPane) setTab(t *tab)  { b.tab = t }

func (b *BrowserPane) renameLocked(id PaneID) {
	b.mu.Lock()
	b.id = id
	b.mu.Unlock()
}

// attach adds c to the viewers and tells it the pane's url, from which
// its window opens the page, and its title; nothing follows.
func (b *BrowserPane) attach(c *conn, _ Size, from PaneID) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.done {
		return nil
	}
	b.viewers[c] = struct{}{}
	c.sendForce(NoPane, notify(rpc.EvPaneAttached, rpc.PaneAttachedParams{ID: b.id, MovedFrom: from, Kind: rpc.PaneBrowser, URL: b.url, Title: b.title}))
	return nil
}

func (b *BrowserPane) detach(c *conn) {
	b.mu.Lock()
	delete(b.viewers, c)
	b.mu.Unlock()
}

// resize and cell: a page has no grid. A layout measures a browser
// leaf with the tab's cell size.
func (b *BrowserPane) resize(*conn, Size) {}
func (b *BrowserPane) cell() Size         { return Size{} }

func (b *BrowserPane) write([]byte) error { return errNotTerminal(b.lockedID()) }

func (b *BrowserPane) text(bool) (string, error) { return "", errNotTerminal(b.lockedID()) }

// lockedID is the id outside the server's lock.
func (b *BrowserPane) lockedID() PaneID {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.id
}

// kill closes the pane as a terminal's exit does, status 0: its
// viewers hear, then paneExited closes the tree over it. Apart, as a
// child's exit is: the caller may hold the server's lock.
func (b *BrowserPane) kill() { go b.exit() }

func (b *BrowserPane) exit() {
	b.mu.Lock()
	if b.done {
		b.mu.Unlock()
		return
	}
	b.done = true
	b.srv.log.Info("pane ended", "pane", b.id, "kind", rpc.PaneBrowser)
	var told []*conn
	exited := notify(rpc.EvPaneExited, rpc.PaneExitedParams{ID: b.id})
	for c := range b.viewers {
		c.sendForce(NoPane, exited)
		told = append(told, c)
	}
	clear(b.viewers)
	b.mu.Unlock()
	b.srv.paneExited(b, 0, told)
}

func (b *BrowserPane) desc() rpc.PaneDesc {
	b.mu.Lock()
	defer b.mu.Unlock()
	return rpc.PaneDesc{ID: b.id, Kind: rpc.PaneBrowser, URL: b.url, Title: b.title, Created: b.created.UnixMilli()}
}

// visitLocked keeps url and title, and sends pane.url to the viewers
// but skip and to the subscribers if the url changed, or always, and
// pane.title likewise if the title changed. Under the server's lock.
func (b *BrowserPane) visitLocked(url, title string, always bool, skip *conn) {
	b.mu.Lock()
	if b.done {
		b.mu.Unlock()
		return
	}
	moved := always || url != b.url
	b.url = url
	titled := title != b.title
	if titled {
		b.title = title
	}
	id := b.id
	told := []*conn{skip}
	if moved || titled {
		var ns []*Notify
		if moved {
			ns = append(ns, notify(rpc.EvPaneURL, rpc.PaneURLParams{ID: id, URL: url}))
		}
		if titled {
			ns = append(ns, notify(rpc.EvPaneTitle, rpc.PaneTitleParams{ID: id, Title: title}))
		}
		for c := range b.viewers {
			if c != skip {
				for _, n := range ns {
					c.sendForce(NoPane, n)
				}
				told = append(told, c)
			}
		}
	}
	b.mu.Unlock()
	if moved {
		b.srv.emitLocked(rpc.EvPaneURL, rpc.PaneURLParams{ID: id, URL: url}, nil, told...)
	}
	if titled {
		b.srv.emitLocked(rpc.EvPaneTitle, rpc.PaneTitleParams{ID: id, Title: title}, nil, told...)
	}
}

// browserLocked finds browser pane id, by an id it had too.
func (s *Server) browserLocked(id PaneID) (*BrowserPane, error) {
	p := s.paneLocked(id)
	if p == nil {
		return nil, errNoPane
	}
	b, ok := p.(*BrowserPane)
	if !ok {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "pane %s is a terminal, not a browser", p.paneID())
	}
	return b, nil
}

// paneNavigate sends a browser pane to a url: every viewer's browser
// follows (pane.url), the caller's too if it views the pane. The title
// was the last page's, so it goes until a browser reports the new one.
func (s *Server) paneNavigate(_ *callCtx, p rpc.PaneNavigateParams) (rpc.Empty, error) {
	if p.URL == "" {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "pane.navigate needs a url")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := s.browserLocked(p.Pane)
	if err != nil {
		return rpc.Empty{}, err
	}
	b.visitLocked(p.URL, "", true, nil)
	return rpc.Empty{}, nil
}

// paneVisited is a viewer's browser reporting where it went and what
// the page is titled: the other viewers follow (pane.url) and show the
// title, and the subscribers hear both (pane.title as a terminal's).
func (s *Server) paneVisited(cl *callCtx, p rpc.PaneVisitedParams) (rpc.Empty, error) {
	if p.URL == "" {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "pane.visited needs a url")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := s.browserLocked(p.Pane)
	if err != nil {
		return rpc.Empty{}, err
	}
	b.visitLocked(p.URL, p.Title, false, cl.c)
	return rpc.Empty{}, nil
}
