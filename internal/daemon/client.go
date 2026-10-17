package daemon

import (
	"fmt"
	"io"
	"sync"
)

// Client is the client end of a connection, for slimed's own commands
// and tests. slime speaks the protocol itself.
type Client struct {
	rw    io.ReadWriteCloser
	r     *Reader
	mu    sync.Mutex // writes
	tag   uint32
	Hello HelloReply
}

// NewClient says hello over rw.
func NewClient(rw io.ReadWriteCloser) (*Client, error) {
	return NewClientWith(rw, Hello{})
}

// NewClientWith says hello over rw with hello's settings; its Version
// is filled in.
func NewClientWith(rw io.ReadWriteCloser, hello Hello) (*Client, error) {
	c := &Client{rw: rw, r: NewReader(rw)}
	hello.Version = Version
	if err := c.Send(0, &hello); err != nil {
		return nil, err
	}
	_, m, err := c.Recv()
	if err != nil {
		return nil, err
	}
	reply, ok := m.(*HelloReply)
	if !ok {
		return nil, fmt.Errorf("daemon: expected hello, got type %d", m.Type())
	}
	c.Hello = *reply
	if reply.Version != Version {
		return nil, fmt.Errorf("daemon: slimed speaks version %d, not %d", reply.Version, Version)
	}
	return c, nil
}

func (c *Client) Send(id uint32, m Message) error {
	b, err := Encode(id, m)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_, err = c.rw.Write(b)
	return err
}

// Recv reads the next message and the pane it's for.
func (c *Client) Recv() (uint32, Message, error) {
	f, err := c.r.Read()
	if err != nil {
		return 0, nil, err
	}
	m, err := Decode(f)
	return f.ID, m, err
}

func (c *Client) Close() error { return c.rw.Close() }

// NextTag returns a tag for a request.
func (c *Client) NextTag() uint32 {
	c.tag++
	return c.tag
}

// List asks for the workspaces. The helpers below read replies in line,
// so they're for a client that isn't also drawing a workspace.
func (c *Client) List() (*Workspaces, error) {
	if err := c.Send(0, &List{}); err != nil {
		return nil, err
	}
	for {
		_, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Workspaces:
			return m, nil
		case *Error:
			return nil, fmt.Errorf("slimed: %s", m.Message)
		}
	}
}

// PaneState is a pane as attaching delivered it, with the frames and
// notices that followed before the reply was complete.
type PaneState struct {
	Attached Attached
	Draws    []*Draw
	Notices  []*Notice
}

// Attachment collects what attaching (or a request that adds a pane to
// an attached workspace) delivered.
type Attachment struct {
	Workspace *Workspace
	Panes     map[uint32]*PaneState
	Created   *Created
}

// Await reads until the Workspace and Created (if want is set) replies
// tagged tag have come, collecting what came for the panes on the way.
func (c *Client) Await(tag uint32, wantCreated bool) (*Attachment, error) {
	a := &Attachment{Panes: map[uint32]*PaneState{}}
	for a.Workspace == nil || (wantCreated && a.Created == nil) {
		id, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Attached:
			a.Panes[id] = &PaneState{Attached: *m}
		case *Draw:
			if p := a.Panes[id]; p != nil {
				p.Draws = append(p.Draws, &Draw{Seq: m.Seq, Data: append([]byte(nil), m.Data...)})
			}
		case *Notice:
			if p := a.Panes[id]; p != nil {
				p.Notices = append(p.Notices, m)
			}
		case *Workspace:
			if m.Tag == tag {
				a.Workspace = m
			}
		case *Created:
			if m.Tag == tag {
				a.Created = m
			}
		case *Error:
			if m.Tag == tag {
				return nil, fmt.Errorf("slimed: %s", m.Message)
			}
		}
	}
	return a, nil
}

// AwaitCreated reads until the Created reply tagged tag, for a client
// that doesn't own the workspace it changed.
func (c *Client) AwaitCreated(tag uint32) (*Created, error) {
	for {
		_, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Created:
			if m.Tag == tag {
				return m, nil
			}
		case *Error:
			if m.Tag == tag {
				return nil, fmt.Errorf("slimed: %s", m.Message)
			}
		}
	}
}

// Peek returns the text of a pane's screen and scrollback without
// taking it: plain, or with asVT the VT that redraws it.
func (c *Client) Peek(pane uint32, asVT bool) ([]byte, error) {
	tag := c.NextTag()
	if err := c.Send(pane, &Peek{Tag: tag, VT: asVT}); err != nil {
		return nil, err
	}
	for {
		id, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *PaneText:
			if m.Tag == tag && id == pane {
				return m.Data, nil
			}
		case *Error:
			if m.Tag == tag {
				return nil, fmt.Errorf("slimed: %s", m.Message)
			}
		}
	}
}

// MostRecentDetached picks the workspace detached last, the one a new
// window takes: nil if none is detached.
func MostRecentDetached(ws *Workspaces) *WorkspaceInfo {
	var best *WorkspaceInfo
	for i := range ws.Workspaces {
		w := &ws.Workspaces[i]
		if w.Attached {
			continue
		}
		if best == nil || w.DetachedAt > best.DetachedAt {
			best = w
		}
	}
	return best
}
