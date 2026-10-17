package persist

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// The wire protocol between slime and slimed. Frames are slime-ssh's
// (internal/proto): a little-endian u32 length of what follows, a u8
// type, a u32 pane id (0 when the message isn't about one pane), and a
// payload of fixed-size integers and strings (u32 length + bytes).
// Decoders ignore bytes after the fields they know, so a later version
// can append fields.
//
// Requests that create something or can fail carry a tag, which the
// reply (Created, Workspace, Attached) or Error echoes.

// Version is exchanged in Hello and HelloReply; peers with different
// versions don't talk.
const Version = 1

// MaxFrame bounds a frame so a corrupt stream can't make us allocate
// gigabytes. Snapshots go out in SnapshotChunk pieces. A full Frame of
// a big screen whose every cell has its own style and grapheme can come
// near a few MiB, and goes whole.
const (
	MaxFrame      = 8 << 20
	SnapshotChunk = 256 << 10
)

// maxDepth bounds a layout tree's nesting on the wire.
const maxDepth = 32

const headerLen = 1 + 4

type Type uint8

// Client to daemon.
const (
	TypeHello           Type = 1
	TypeList            Type = 2
	TypeWorkspaceNew    Type = 3
	TypeWorkspaceAttach Type = 4
	TypeWorkspaceDetach Type = 5
	TypeWorkspaceKill   Type = 6
	TypeWorkspaceRename Type = 7
	TypeWorkspaceResize Type = 8
	TypeTabNew          Type = 9
	TypeTabClose        Type = 10
	TypeTabRename       Type = 11
	TypeSplit           Type = 12
	TypeLayout          Type = 13
	TypePaneKill        Type = 14
	TypeInput           Type = 15
	TypeResize          Type = 16
	TypePeek            Type = 17
	TypeAck             Type = 18
	TypeEvent           Type = 19
)

// Daemon to client.
const (
	TypeHelloReply Type = 65
	TypeWorkspaces Type = 66
	TypeWorkspace  Type = 67
	TypeAttached   Type = 68
	TypeSnapshot   Type = 69
	TypeOutput     Type = 70
	TypeExit       Type = 71
	TypeDetached   Type = 72
	TypeError      Type = 73
	TypeCreated    Type = 74
	TypeDraw       Type = 75
	TypeCopied     Type = 76
	TypeNotice     Type = 77
)

var (
	ErrTooLarge    = errors.New("persist: frame too large")
	ErrShortFrame  = errors.New("persist: frame shorter than its header")
	ErrTruncated   = errors.New("persist: payload truncated")
	ErrUnknownType = errors.New("persist: unknown message type")
	ErrTooDeep     = errors.New("persist: layout nested too deep")
)

// Frame is one undecoded message.
type Frame struct {
	Type    Type
	ID      uint32
	Payload []byte
}

// Message is a decoded payload.
type Message interface {
	Type() Type
	encode(*encoder)
	decode(*decoder)
}

// Size is a terminal's grid and, if known, its cell size in pixels.
type Size struct {
	Cols, Rows   uint16
	CellW, CellH uint32
}

// Hello opens a connection. Caps and FrameInterval are optional on the
// wire; a client that sends neither runs its own terminals.
type Hello struct {
	Version uint32
	Caps    uint32
	// FrameInterval is the least time between a pane's frames, in
	// microseconds: the client's refresh period. Zero for the default.
	FrameInterval uint32
}

// Capabilities a client asks for in Hello.
const (
	// CapFrames: the client draws frames (Draw) instead of running a
	// terminal.
	// Attaching sends Attached with no snapshot, then frames; panes take
	// Event messages, not Input; and the daemon's terminal answers the
	// program's queries.
	CapFrames uint32 = 1 << 0
)

// List asks for every workspace; the reply is Workspaces.
type List struct{}

// WorkspaceNew creates an empty workspace attached to the sender. The
// reply is Workspace; add tabs with TabNew.
type WorkspaceNew struct {
	Tag  uint32
	Name string
}

// WorkspaceAttach takes a workspace from whichever window has it. Area
// is what the window gives a tab, which the daemon sizes its panes to
// before snapshotting them. The reply is, per pane, Attached and its
// snapshot, then Workspace: snapshots come before the structure that
// refers to them.
type WorkspaceAttach struct {
	Tag  uint32
	WS   uint32
	Area Area
}

// Area is a tab's space in pixels, which a layout's shares divide, and
// the cell size for panes that haven't reported their own.
type Area struct {
	Width, Height uint32
	CellW, CellH  uint32
}

type WorkspaceDetach struct{ WS uint32 }

// WorkspaceKill ends every pane in a workspace, and the workspace.
type WorkspaceKill struct{ WS uint32 }

type WorkspaceRename struct {
	WS   uint32
	Name string
}

// WorkspaceResize tells the daemon the window's tab area, for estimating
// pane sizes in its tabs. The window still resizes each pane itself.
type WorkspaceResize struct {
	WS   uint32
	Area Area
}

// TabNew adds a tab with one pane running Command (CreateProcessW
// syntax on Windows; empty for the default shell). The owner of the
// workspace gets the new pane's Attached and snapshot, then Workspace;
// the sender gets Created.
type TabNew struct {
	Tag     uint32
	WS      uint32
	Command string
	Cwd     string
	Size    Size
}

type TabClose struct{ Tab uint32 }

type TabRename struct {
	Tab  uint32
	Name string
}

// Split starts a pane beside Pane, on side Dir, taking Share basis
// points of its space. Replies as TabNew does.
type Split struct {
	Tag     uint32
	Pane    uint32
	Dir     Direction
	Share   uint16
	Command string
	Cwd     string
}

// Layout replaces a tab's tree, which must hold the same panes: a
// divider was dragged. The owner gets Workspace back.
type Layout struct {
	Tab  uint32
	Tree *Node
}

// PaneKill ends the pane in the frame's id.
type PaneKill struct{}

// Input goes to the pane in the frame's id; only its owner's counts.
type Input struct{ Data []byte }

// Resize sizes the pane in the frame's id; only its owner's counts.
type Resize struct{ Size Size }

// Peek asks for a pane's snapshot without taking it: the reply is
// Attached (with Tag) and the snapshot, and nothing live follows.
type Peek struct{ Tag uint32 }

// Ack says the client drew the pane's Draw Seq, which frees room for
// another (see Pane's framing).
type Ack struct{ Seq uint32 }

// Event is input for the pane in the frame's id, from a CapFrames
// client: a key, mouse, wheel, paste, focus change, or copy, encoded as
// ssh/internal/vt/event.zig lays out.
type Event struct{ Data []byte }

// Draw is a frame of the pane in the frame's id: what to draw, encoded
// as ssh/internal/vt/frame.zig lays out. Seq counts the pane's frames to
// this client from 1; Ack them.
type Draw struct {
	Seq  uint32
	Data []byte
}

// Copied answers a copy Event for the pane in the frame's id: Tag is the
// event's, and Text the selection's (empty with none).
type Copied struct {
	Tag  uint32
	Text string
}

// Notice tells a client that draws (CapFrames) what the pane in the
// frame's id did besides change its screen: what a client running its
// own terminal would learn from the output.
type Notice struct {
	Kind NoticeKind
	// Text is the new title or pwd (as sent: OSC 7's is a file:// URI),
	// or the clipboard's new text (empty to clear it).
	Text string
	// Status is every program status record, oldest update first, for
	// NoticeStatus.
	Status []StatusRecord
}

type NoticeKind uint8

const (
	NoticeTitle NoticeKind = iota + 1
	NoticePwd
	NoticeBell
	NoticeClipboard
	NoticeStatus
)

type HelloReply struct {
	Version uint32
	// SnapshotVersion is the snapshot format the daemon writes. A client
	// that can't decode it shouldn't attach.
	SnapshotVersion uint16
	PID             uint32
	// FrameLayout is the daemon's vt.FrameLayout. A CapFrames client
	// whose own differs can't draw its frames.
	FrameLayout uint64
}

type Workspaces struct {
	Workspaces []WorkspaceInfo
	Panes      []PaneInfo
}

type WorkspaceInfo struct {
	ID       uint32
	Name     string
	Attached bool
	// DetachedAt is when it was last detached, in unix milliseconds;
	// zero while attached or if it never was.
	DetachedAt int64
	Tabs       []TabInfo
}

type TabInfo struct {
	ID   uint32
	Name string // empty unless renamed
	Tree *Node
}

type PaneInfo struct {
	ID      uint32
	Tab     uint32
	Command string
	Title   string
	Pwd     string
	Cols    uint16
	Rows    uint16
	Created int64 // unix milliseconds
	PID     uint32
}

// Workspace describes an attached workspace's structure: on attach, and
// to its owner whenever the structure changes.
type Workspace struct {
	Tag  uint32
	ID   uint32
	Name string
	Tabs []TabInfo
}

// Attached starts a pane's attachment (or answers a Peek, with its tag).
// SnapshotLen bytes of Snapshot frames follow, then live Output. Modes
// are the modes libghostty-vt doesn't keep in a snapshot, in their
// current state (win32-input-mode).
type Attached struct {
	Tag         uint32
	SnapshotLen uint32
	Modes       []Mode
	// Command is what the pane runs, for a client that didn't start it.
	Command string
	// Status is what the pane's programs report doing (OSC 7501), which
	// a snapshot doesn't carry, oldest update first.
	Status []StatusRecord
}

// StatusRecord is one program status record: its id (empty for the
// program itself), state (vt.StatusState: idle, working, done, blocked,
// or error), and progress (0 to 100, or -1 for none).
type StatusRecord struct {
	ID       string
	State    uint8
	Progress int8
}

type Mode struct {
	Mode    uint16
	ANSI    bool
	Enabled bool
}

type Snapshot struct{ Data []byte }

type Output struct{ Data []byte }

// Exit says the pane's child exited. The owner gets Workspace after,
// with the pane gone from its tab.
type Exit struct{ Status uint32 }

// Detached ends a window's hold on a workspace it didn't let go of.
type Detached struct {
	WS     uint32
	Reason string
}

type Error struct {
	Tag     uint32
	Message string
}

// Created answers TabNew, Split, and WorkspaceNew with what they made.
type Created struct {
	Tag  uint32
	WS   uint32
	Tab  uint32
	Pane uint32
}

func (*Hello) Type() Type           { return TypeHello }
func (*List) Type() Type            { return TypeList }
func (*WorkspaceNew) Type() Type    { return TypeWorkspaceNew }
func (*WorkspaceAttach) Type() Type { return TypeWorkspaceAttach }
func (*WorkspaceDetach) Type() Type { return TypeWorkspaceDetach }
func (*WorkspaceKill) Type() Type   { return TypeWorkspaceKill }
func (*WorkspaceRename) Type() Type { return TypeWorkspaceRename }
func (*WorkspaceResize) Type() Type { return TypeWorkspaceResize }
func (*TabNew) Type() Type          { return TypeTabNew }
func (*TabClose) Type() Type        { return TypeTabClose }
func (*TabRename) Type() Type       { return TypeTabRename }
func (*Split) Type() Type           { return TypeSplit }
func (*Layout) Type() Type          { return TypeLayout }
func (*PaneKill) Type() Type        { return TypePaneKill }
func (*Input) Type() Type           { return TypeInput }
func (*Resize) Type() Type          { return TypeResize }
func (*Peek) Type() Type            { return TypePeek }
func (*Ack) Type() Type             { return TypeAck }
func (*Event) Type() Type           { return TypeEvent }
func (*HelloReply) Type() Type      { return TypeHelloReply }
func (*Workspaces) Type() Type      { return TypeWorkspaces }
func (*Workspace) Type() Type       { return TypeWorkspace }
func (*Attached) Type() Type        { return TypeAttached }
func (*Snapshot) Type() Type        { return TypeSnapshot }
func (*Output) Type() Type          { return TypeOutput }
func (*Exit) Type() Type            { return TypeExit }
func (*Detached) Type() Type        { return TypeDetached }
func (*Error) Type() Type           { return TypeError }
func (*Created) Type() Type         { return TypeCreated }
func (*Draw) Type() Type            { return TypeDraw }
func (*Copied) Type() Type          { return TypeCopied }
func (*Notice) Type() Type          { return TypeNotice }

func (m *Hello) encode(e *encoder) {
	e.u32(m.Version)
	e.u32(m.Caps)
	e.u32(m.FrameInterval)
}

func (m *Hello) decode(d *decoder) {
	m.Version = d.u32()
	if d.more() {
		m.Caps = d.u32()
		m.FrameInterval = d.u32()
	}
}

func (*List) encode(*encoder) {}
func (*List) decode(*decoder) {}

func (m *WorkspaceNew) encode(e *encoder) {
	e.u32(m.Tag)
	e.str(m.Name)
}

func (m *WorkspaceNew) decode(d *decoder) {
	m.Tag = d.u32()
	m.Name = d.str()
}

func (m *WorkspaceAttach) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.WS)
	e.area(m.Area)
}

func (m *WorkspaceAttach) decode(d *decoder) {
	m.Tag = d.u32()
	m.WS = d.u32()
	m.Area = d.area()
}

func (m *WorkspaceDetach) encode(e *encoder) { e.u32(m.WS) }
func (m *WorkspaceDetach) decode(d *decoder) { m.WS = d.u32() }

func (m *WorkspaceKill) encode(e *encoder) { e.u32(m.WS) }
func (m *WorkspaceKill) decode(d *decoder) { m.WS = d.u32() }

func (m *WorkspaceRename) encode(e *encoder) {
	e.u32(m.WS)
	e.str(m.Name)
}

func (m *WorkspaceRename) decode(d *decoder) {
	m.WS = d.u32()
	m.Name = d.str()
}

func (m *WorkspaceResize) encode(e *encoder) {
	e.u32(m.WS)
	e.area(m.Area)
}

func (m *WorkspaceResize) decode(d *decoder) {
	m.WS = d.u32()
	m.Area = d.area()
}

func (m *TabNew) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.WS)
	e.str(m.Command)
	e.str(m.Cwd)
	e.size(m.Size)
}

func (m *TabNew) decode(d *decoder) {
	m.Tag = d.u32()
	m.WS = d.u32()
	m.Command = d.str()
	m.Cwd = d.str()
	m.Size = d.size()
}

func (m *TabClose) encode(e *encoder) { e.u32(m.Tab) }
func (m *TabClose) decode(d *decoder) { m.Tab = d.u32() }

func (m *TabRename) encode(e *encoder) {
	e.u32(m.Tab)
	e.str(m.Name)
}

func (m *TabRename) decode(d *decoder) {
	m.Tab = d.u32()
	m.Name = d.str()
}

func (m *Split) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.Pane)
	e.u8(uint8(m.Dir))
	e.u16(m.Share)
	e.str(m.Command)
	e.str(m.Cwd)
}

func (m *Split) decode(d *decoder) {
	m.Tag = d.u32()
	m.Pane = d.u32()
	m.Dir = Direction(d.u8())
	m.Share = d.u16()
	m.Command = d.str()
	m.Cwd = d.str()
}

func (m *Layout) encode(e *encoder) {
	e.u32(m.Tab)
	e.node(m.Tree)
}

func (m *Layout) decode(d *decoder) {
	m.Tab = d.u32()
	m.Tree = d.node(0)
}

func (*PaneKill) encode(*encoder) {}
func (*PaneKill) decode(*decoder) {}

func (m *Input) encode(e *encoder) { e.raw(m.Data) }
func (m *Input) decode(d *decoder) { m.Data = d.rest() }

func (m *Resize) encode(e *encoder) { e.size(m.Size) }
func (m *Resize) decode(d *decoder) { m.Size = d.size() }

func (m *Peek) encode(e *encoder) { e.u32(m.Tag) }
func (m *Peek) decode(d *decoder) { m.Tag = d.u32() }

func (m *Ack) encode(e *encoder) { e.u32(m.Seq) }
func (m *Ack) decode(d *decoder) { m.Seq = d.u32() }

func (m *Event) encode(e *encoder) { e.raw(m.Data) }
func (m *Event) decode(d *decoder) { m.Data = d.rest() }

func (m *Draw) encode(e *encoder) {
	e.u32(m.Seq)
	e.raw(m.Data)
}

func (m *Draw) decode(d *decoder) {
	m.Seq = d.u32()
	m.Data = d.rest()
}

func (m *Copied) encode(e *encoder) {
	e.u32(m.Tag)
	e.str(m.Text)
}

func (m *Copied) decode(d *decoder) {
	m.Tag = d.u32()
	m.Text = d.str()
}

func (m *Notice) encode(e *encoder) {
	e.u8(uint8(m.Kind))
	e.str(m.Text)
	e.statusRecords(m.Status)
}

func (m *Notice) decode(d *decoder) {
	m.Kind = NoticeKind(d.u8())
	m.Text = d.str()
	m.Status = d.statusRecords()
}

func (m *HelloReply) encode(e *encoder) {
	e.u32(m.Version)
	e.u16(m.SnapshotVersion)
	e.u32(m.PID)
	e.u64(m.FrameLayout)
}

func (m *HelloReply) decode(d *decoder) {
	m.Version = d.u32()
	m.SnapshotVersion = d.u16()
	m.PID = d.u32()
	if d.more() {
		m.FrameLayout = d.u64()
	}
}

func (m *Workspaces) encode(e *encoder) {
	e.u32(uint32(len(m.Workspaces)))
	for _, w := range m.Workspaces {
		e.u32(w.ID)
		e.str(w.Name)
		e.bool(w.Attached)
		e.u64(uint64(w.DetachedAt))
		e.tabs(w.Tabs)
	}
	e.u32(uint32(len(m.Panes)))
	for _, p := range m.Panes {
		e.u32(p.ID)
		e.u32(p.Tab)
		e.str(p.Command)
		e.str(p.Title)
		e.str(p.Pwd)
		e.u16(p.Cols)
		e.u16(p.Rows)
		e.u64(uint64(p.Created))
		e.u32(p.PID)
	}
}

func (m *Workspaces) decode(d *decoder) {
	n := d.count(4 + 4 + 1 + 8 + 4)
	m.Workspaces = make([]WorkspaceInfo, n)
	for i := range m.Workspaces {
		w := &m.Workspaces[i]
		w.ID = d.u32()
		w.Name = d.str()
		w.Attached = d.bool()
		w.DetachedAt = int64(d.u64())
		w.Tabs = d.tabs()
	}
	n = d.count(4 + 4 + 4*3 + 2*2 + 8 + 4)
	m.Panes = make([]PaneInfo, n)
	for i := range m.Panes {
		p := &m.Panes[i]
		p.ID = d.u32()
		p.Tab = d.u32()
		p.Command = d.str()
		p.Title = d.str()
		p.Pwd = d.str()
		p.Cols = d.u16()
		p.Rows = d.u16()
		p.Created = int64(d.u64())
		p.PID = d.u32()
	}
}

func (m *Workspace) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.ID)
	e.str(m.Name)
	e.tabs(m.Tabs)
}

func (m *Workspace) decode(d *decoder) {
	m.Tag = d.u32()
	m.ID = d.u32()
	m.Name = d.str()
	m.Tabs = d.tabs()
}

func (m *Attached) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.SnapshotLen)
	e.u32(uint32(len(m.Modes)))
	for _, md := range m.Modes {
		e.u16(md.Mode)
		e.bool(md.ANSI)
		e.bool(md.Enabled)
	}
	e.str(m.Command)
	e.statusRecords(m.Status)
}

func (m *Attached) decode(d *decoder) {
	m.Tag = d.u32()
	m.SnapshotLen = d.u32()
	n := d.count(4)
	m.Modes = make([]Mode, n)
	for i := range m.Modes {
		m.Modes[i] = Mode{Mode: d.u16(), ANSI: d.bool(), Enabled: d.bool()}
	}
	m.Command = d.str()
	m.Status = d.statusRecords()
}

func (m *Snapshot) encode(e *encoder) { e.raw(m.Data) }
func (m *Snapshot) decode(d *decoder) { m.Data = d.rest() }

func (m *Output) encode(e *encoder) { e.raw(m.Data) }
func (m *Output) decode(d *decoder) { m.Data = d.rest() }

func (m *Exit) encode(e *encoder) { e.u32(m.Status) }
func (m *Exit) decode(d *decoder) { m.Status = d.u32() }

func (m *Detached) encode(e *encoder) {
	e.u32(m.WS)
	e.str(m.Reason)
}

func (m *Detached) decode(d *decoder) {
	m.WS = d.u32()
	m.Reason = d.str()
}

func (m *Error) encode(e *encoder) {
	e.u32(m.Tag)
	e.str(m.Message)
}

func (m *Error) decode(d *decoder) {
	m.Tag = d.u32()
	m.Message = d.str()
}

func (m *Created) encode(e *encoder) {
	e.u32(m.Tag)
	e.u32(m.WS)
	e.u32(m.Tab)
	e.u32(m.Pane)
}

func (m *Created) decode(d *decoder) {
	m.Tag = d.u32()
	m.WS = d.u32()
	m.Tab = d.u32()
	m.Pane = d.u32()
}

// Decode turns a frame's payload into its message. Byte payloads alias
// the frame's.
func Decode(f Frame) (Message, error) {
	m := newMessage(f.Type)
	if m == nil {
		return nil, fmt.Errorf("%w %d", ErrUnknownType, f.Type)
	}
	d := decoder{buf: f.Payload}
	m.decode(&d)
	if d.err != nil {
		return nil, fmt.Errorf("decoding type %d: %w", f.Type, d.err)
	}
	return m, nil
}

func newMessage(t Type) Message {
	switch t {
	case TypeHello:
		return new(Hello)
	case TypeList:
		return new(List)
	case TypeWorkspaceNew:
		return new(WorkspaceNew)
	case TypeWorkspaceAttach:
		return new(WorkspaceAttach)
	case TypeWorkspaceDetach:
		return new(WorkspaceDetach)
	case TypeWorkspaceKill:
		return new(WorkspaceKill)
	case TypeWorkspaceRename:
		return new(WorkspaceRename)
	case TypeWorkspaceResize:
		return new(WorkspaceResize)
	case TypeTabNew:
		return new(TabNew)
	case TypeTabClose:
		return new(TabClose)
	case TypeTabRename:
		return new(TabRename)
	case TypeSplit:
		return new(Split)
	case TypeLayout:
		return new(Layout)
	case TypePaneKill:
		return new(PaneKill)
	case TypeInput:
		return new(Input)
	case TypeResize:
		return new(Resize)
	case TypePeek:
		return new(Peek)
	case TypeAck:
		return new(Ack)
	case TypeEvent:
		return new(Event)
	case TypeHelloReply:
		return new(HelloReply)
	case TypeWorkspaces:
		return new(Workspaces)
	case TypeWorkspace:
		return new(Workspace)
	case TypeAttached:
		return new(Attached)
	case TypeSnapshot:
		return new(Snapshot)
	case TypeOutput:
		return new(Output)
	case TypeExit:
		return new(Exit)
	case TypeDetached:
		return new(Detached)
	case TypeError:
		return new(Error)
	case TypeCreated:
		return new(Created)
	case TypeDraw:
		return new(Draw)
	case TypeCopied:
		return new(Copied)
	case TypeNotice:
		return new(Notice)
	}
	return nil
}

// Encode returns m as a frame for pane id (0 for none), ready to write.
func Encode(id uint32, m Message) ([]byte, error) {
	e := encoder{buf: make([]byte, 4+headerLen, 64)}
	m.encode(&e)
	if len(e.buf)-4 > MaxFrame {
		return nil, ErrTooLarge
	}
	binary.LittleEndian.PutUint32(e.buf[0:4], uint32(len(e.buf)-4))
	e.buf[4] = byte(m.Type())
	binary.LittleEndian.PutUint32(e.buf[5:9], id)
	return e.buf, nil
}

// Reader reads frames.
type Reader struct{ r *bufio.Reader }

func NewReader(r io.Reader) *Reader { return &Reader{r: bufio.NewReaderSize(r, 64<<10)} }

// Read returns the next frame. It returns io.EOF only at a frame
// boundary; a stream that ends mid-frame is io.ErrUnexpectedEOF.
func (r *Reader) Read() (Frame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r.r, lenBuf[:]); err != nil {
		return Frame{}, err
	}
	n := binary.LittleEndian.Uint32(lenBuf[:])
	if n > MaxFrame {
		return Frame{}, ErrTooLarge
	}
	if n < headerLen {
		return Frame{}, ErrShortFrame
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r.r, buf); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return Frame{}, err
	}
	return Frame{
		Type:    Type(buf[0]),
		ID:      binary.LittleEndian.Uint32(buf[1:5]),
		Payload: buf[headerLen:],
	}, nil
}

type encoder struct{ buf []byte }

func (e *encoder) u8(v uint8) { e.buf = append(e.buf, v) }

func (e *encoder) bool(v bool) {
	if v {
		e.u8(1)
	} else {
		e.u8(0)
	}
}

func (e *encoder) u16(v uint16) { e.buf = binary.LittleEndian.AppendUint16(e.buf, v) }
func (e *encoder) u32(v uint32) { e.buf = binary.LittleEndian.AppendUint32(e.buf, v) }
func (e *encoder) u64(v uint64) { e.buf = binary.LittleEndian.AppendUint64(e.buf, v) }
func (e *encoder) raw(b []byte) { e.buf = append(e.buf, b...) }

func (e *encoder) str(s string) {
	e.u32(uint32(len(s)))
	e.buf = append(e.buf, s...)
}

func (e *encoder) statusRecords(rs []StatusRecord) {
	e.u32(uint32(len(rs)))
	for _, r := range rs {
		e.str(r.ID)
		e.u8(r.State)
		e.u8(uint8(r.Progress))
	}
}

func (e *encoder) size(s Size) {
	e.u16(s.Cols)
	e.u16(s.Rows)
	e.u32(s.CellW)
	e.u32(s.CellH)
}

func (e *encoder) area(a Area) {
	e.u32(a.Width)
	e.u32(a.Height)
	e.u32(a.CellW)
	e.u32(a.CellH)
}

// node writes a layout tree in pre-order: a pane is u8 0 and its u32 id;
// a split is u8 1, its u8 axis, a u16 child count, and per child its u16
// share then the child.
func (e *encoder) node(n *Node) {
	if n == nil || n.isLeaf() {
		e.u8(0)
		if n == nil {
			e.u32(0)
		} else {
			e.u32(n.Pane)
		}
		return
	}
	e.u8(1)
	e.u8(uint8(n.Axis))
	e.u16(uint16(len(n.Children)))
	for _, c := range n.Children {
		e.u16(c.Share)
		e.node(c.Node)
	}
}

func (e *encoder) tabs(tabs []TabInfo) {
	e.u32(uint32(len(tabs)))
	for _, t := range tabs {
		e.u32(t.ID)
		e.str(t.Name)
		e.node(t.Tree)
	}
}

// decoder reads fields until the first error, after which every field
// reads as zero and err says what went wrong.
type decoder struct {
	buf []byte
	err error
}

func (d *decoder) take(n int) []byte {
	if d.err != nil {
		return nil
	}
	if len(d.buf) < n {
		d.err = ErrTruncated
		return nil
	}
	b := d.buf[:n]
	d.buf = d.buf[n:]
	return b
}

// more says whether anything is left: fields added later are optional.
func (d *decoder) more() bool { return d.err == nil && len(d.buf) > 0 }

func (d *decoder) rest() []byte {
	b := d.buf
	d.buf = nil
	return b
}

func (d *decoder) u8() uint8 {
	if b := d.take(1); b != nil {
		return b[0]
	}
	return 0
}

func (d *decoder) bool() bool { return d.u8() != 0 }

// count reads a list's length, which can't be more than the bytes left
// allow at minSize bytes an item.
func (d *decoder) count(minSize int) int {
	n := d.u32()
	if d.err != nil {
		return 0
	}
	if uint64(n)*uint64(minSize) > uint64(len(d.buf)) {
		d.err = ErrTruncated
		return 0
	}
	return int(n)
}

func (d *decoder) u16() uint16 {
	if b := d.take(2); b != nil {
		return binary.LittleEndian.Uint16(b)
	}
	return 0
}

func (d *decoder) u32() uint32 {
	if b := d.take(4); b != nil {
		return binary.LittleEndian.Uint32(b)
	}
	return 0
}

func (d *decoder) u64() uint64 {
	if b := d.take(8); b != nil {
		return binary.LittleEndian.Uint64(b)
	}
	return 0
}

func (d *decoder) str() string {
	n := d.u32()
	if d.err != nil {
		return ""
	}
	if uint64(n) > uint64(len(d.buf)) {
		d.err = ErrTruncated
		return ""
	}
	return string(d.take(int(n)))
}

func (d *decoder) statusRecords() []StatusRecord {
	n := d.count(6)
	rs := make([]StatusRecord, n)
	for i := range rs {
		rs[i] = StatusRecord{ID: d.str(), State: d.u8(), Progress: int8(d.u8())}
	}
	return rs
}

func (d *decoder) size() Size {
	return Size{Cols: d.u16(), Rows: d.u16(), CellW: d.u32(), CellH: d.u32()}
}

func (d *decoder) area() Area {
	return Area{Width: d.u32(), Height: d.u32(), CellW: d.u32(), CellH: d.u32()}
}

func (d *decoder) node(depth int) *Node {
	if depth > maxDepth {
		if d.err == nil {
			d.err = ErrTooDeep
		}
		return nil
	}
	switch d.u8() {
	case 0:
		return &Node{Pane: d.u32()}
	case 1:
		n := &Node{Axis: Axis(d.u8())}
		// Each child is at least a share and a pane: 2 + 5 bytes.
		count := int(d.u16())
		if d.err == nil && count*7 > len(d.buf) {
			d.err = ErrTruncated
		}
		for range count {
			if d.err != nil {
				return nil
			}
			share := d.u16()
			n.Children = append(n.Children, Child{share, d.node(depth + 1)})
		}
		return n
	default:
		if d.err == nil {
			d.err = errors.New("persist: bad layout node")
		}
		return nil
	}
}

func (d *decoder) tabs() []TabInfo {
	n := d.count(4 + 4 + 5)
	tabs := make([]TabInfo, n)
	for i := range tabs {
		tabs[i] = TabInfo{ID: d.u32(), Name: d.str(), Tree: d.node(0)}
	}
	return tabs
}
