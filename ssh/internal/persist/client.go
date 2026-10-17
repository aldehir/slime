package persist

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
	c := &Client{rw: rw, r: NewReader(rw)}
	if err := c.Send(0, &Hello{Version: Version}); err != nil {
		return nil, err
	}
	_, m, err := c.Recv()
	if err != nil {
		return nil, err
	}
	reply, ok := m.(*HelloReply)
	if !ok {
		return nil, fmt.Errorf("persist: expected hello, got type %d", m.Type())
	}
	c.Hello = *reply
	if reply.Version != Version {
		return nil, fmt.Errorf("persist: slimed speaks version %d, not %d", reply.Version, Version)
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
// so they're for a client that isn't also reading live output.
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

// PaneState is a pane as attaching delivered it: its snapshot, and the
// output that followed before the reply was complete.
type PaneState struct {
	Attached Attached
	Snapshot []byte
	Output   [][]byte
}

// Attachment collects what attaching (or a request that adds a pane to
// an attached workspace) delivered.
type Attachment struct {
	Workspace *Workspace
	Panes     map[uint32]*PaneState
	Created   *Created
}

// Await reads until the Workspace and Created (if want is set) replies
// tagged tag have come, collecting pane snapshots and output on the way.
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
		case *Snapshot:
			if p := a.Panes[id]; p != nil {
				p.Snapshot = append(p.Snapshot, m.Data...)
			}
		case *Output:
			if p := a.Panes[id]; p != nil {
				p.Output = append(p.Output, append([]byte(nil), m.Data...))
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

// Peek returns a pane's snapshot without taking it.
func (c *Client) Peek(pane uint32) (*PaneState, error) {
	tag := c.NextTag()
	if err := c.Send(pane, &Peek{Tag: tag}); err != nil {
		return nil, err
	}
	var p *PaneState
	for {
		id, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Attached:
			if m.Tag == tag && id == pane {
				p = &PaneState{Attached: *m}
			}
		case *Snapshot:
			if p != nil && id == pane {
				p.Snapshot = append(p.Snapshot, m.Data...)
			}
		case *Error:
			if m.Tag == tag {
				return nil, fmt.Errorf("slimed: %s", m.Message)
			}
		}
		if p != nil && len(p.Snapshot) == int(p.Attached.SnapshotLen) {
			return p, nil
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
