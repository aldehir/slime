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

// Recv reads the next message and the session it's for.
func (c *Client) Recv() (uint32, Message, error) {
	f, err := c.r.Read()
	if err != nil {
		return 0, nil, err
	}
	m, err := Decode(f)
	return f.ID, m, err
}

func (c *Client) Close() error { return c.rw.Close() }

// List asks for the sessions. Only for a client that isn't attached:
// it reads the reply in line.
func (c *Client) List() ([]SessionInfo, error) {
	if err := c.Send(0, &List{}); err != nil {
		return nil, err
	}
	for {
		_, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Sessions:
			return m.Sessions, nil
		case *Error:
			return nil, fmt.Errorf("slimed: %s", m.Message)
		}
	}
}

// Attachment is a session's attach reply with its snapshot assembled.
type Attachment struct {
	ID       uint32
	Attached Attached
	Snapshot []byte
}

// ReadAttach reads the reply to New or Attach: Attached and the snapshot
// chunks. Only for a client attaching one session at a time.
func (c *Client) ReadAttach() (*Attachment, error) {
	var a *Attachment
	for {
		id, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *Error:
			return nil, fmt.Errorf("slimed: %s", m.Message)
		case *Attached:
			a = &Attachment{ID: id, Attached: *m, Snapshot: make([]byte, 0, m.SnapshotLen)}
		case *Snapshot:
			if a == nil || id != a.ID {
				return nil, fmt.Errorf("persist: snapshot before attached")
			}
			a.Snapshot = append(a.Snapshot, m.Data...)
		default:
			return nil, fmt.Errorf("persist: unexpected type %d while attaching", m.Type())
		}
		if a != nil && len(a.Snapshot) == int(a.Attached.SnapshotLen) {
			return a, nil
		}
	}
}
