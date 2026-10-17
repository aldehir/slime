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
// type, a u32 session id (0 for the connection), and a payload of
// fixed-size integers and strings (u32 length + bytes). Decoders ignore
// bytes after the fields they know, so a later version can append
// fields.

// Version is exchanged in Hello and HelloReply; peers with different
// versions don't talk.
const Version = 1

// MaxFrame bounds a frame so a corrupt stream can't make us allocate
// gigabytes. Snapshots go out in SnapshotChunk pieces.
const (
	MaxFrame      = 1 << 20
	SnapshotChunk = 256 << 10
)

const headerLen = 1 + 4

type Type uint8

// Client to daemon.
const (
	TypeHello  Type = 1
	TypeList   Type = 2
	TypeNew    Type = 3
	TypeAttach Type = 4
	TypeDetach Type = 5
	TypeInput  Type = 6
	TypeResize Type = 7
	TypeKill   Type = 8
)

// Daemon to client.
const (
	TypeHelloReply Type = 65
	TypeSessions   Type = 66
	TypeAttached   Type = 67
	TypeSnapshot   Type = 68
	TypeOutput     Type = 69
	TypeDetached   Type = 70
	TypeExit       Type = 71
	TypeError      Type = 72
)

var (
	ErrTooLarge    = errors.New("persist: frame too large")
	ErrShortFrame  = errors.New("persist: frame shorter than its header")
	ErrTruncated   = errors.New("persist: payload truncated")
	ErrUnknownType = errors.New("persist: unknown message type")
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

type Hello struct{ Version uint32 }

type List struct{}

// New starts a session and attaches the sender to it; the reply is
// Attached (or Error) carrying Tag, on the new session's id.
type New struct {
	Tag uint32
	// Command is the command line (CreateProcessW syntax on Windows);
	// empty for the default shell.
	Command string
	Cwd     string
	Size    Size
}

// Attach takes a session, from whichever client has it. The reply is
// Attached and the snapshot, then Output.
type Attach struct {
	Tag  uint32
	Size Size
}

type Detach struct{}

type Input struct{ Data []byte }

type Resize struct{ Size Size }

type Kill struct{}

// Size is a terminal's grid and, if known, its cell size in pixels.
type Size struct {
	Cols, Rows   uint16
	CellW, CellH uint32
}

type HelloReply struct {
	Version uint32
	// SnapshotVersion is the snapshot format the daemon writes. A client
	// that can't decode it shouldn't attach.
	SnapshotVersion uint16
	PID             uint32
}

type Sessions struct{ Sessions []SessionInfo }

type SessionInfo struct {
	ID       uint32
	Command  string
	Title    string
	Pwd      string
	Cols     uint16
	Rows     uint16
	Attached bool
	Created  int64 // unix milliseconds
	PID      uint32
}

// Attached starts an attachment. SnapshotLen bytes of Snapshot frames
// follow, then live Output. Modes are the modes libghostty-vt doesn't
// keep in a snapshot, in their current state (win32-input-mode).
type Attached struct {
	Tag         uint32
	SnapshotLen uint32
	Modes       []Mode
}

type Mode struct {
	Mode    uint16
	ANSI    bool
	Enabled bool
}

type Snapshot struct{ Data []byte }

type Output struct{ Data []byte }

// Detached ends an attachment the client didn't ask to end.
type Detached struct{ Reason string }

type Exit struct{ Status uint32 }

type Error struct {
	Tag     uint32
	Message string
}

func (*Hello) Type() Type      { return TypeHello }
func (*List) Type() Type       { return TypeList }
func (*New) Type() Type        { return TypeNew }
func (*Attach) Type() Type     { return TypeAttach }
func (*Detach) Type() Type     { return TypeDetach }
func (*Input) Type() Type      { return TypeInput }
func (*Resize) Type() Type     { return TypeResize }
func (*Kill) Type() Type       { return TypeKill }
func (*HelloReply) Type() Type { return TypeHelloReply }
func (*Sessions) Type() Type   { return TypeSessions }
func (*Attached) Type() Type   { return TypeAttached }
func (*Snapshot) Type() Type   { return TypeSnapshot }
func (*Output) Type() Type     { return TypeOutput }
func (*Detached) Type() Type   { return TypeDetached }
func (*Exit) Type() Type       { return TypeExit }
func (*Error) Type() Type      { return TypeError }

func (m *Hello) encode(e *encoder) { e.u32(m.Version) }
func (m *Hello) decode(d *decoder) { m.Version = d.u32() }

func (*List) encode(*encoder) {}
func (*List) decode(*decoder) {}

func (m *New) encode(e *encoder) {
	e.u32(m.Tag)
	e.str(m.Command)
	e.str(m.Cwd)
	e.size(m.Size)
}

func (m *New) decode(d *decoder) {
	m.Tag = d.u32()
	m.Command = d.str()
	m.Cwd = d.str()
	m.Size = d.size()
}

func (m *Attach) encode(e *encoder) {
	e.u32(m.Tag)
	e.size(m.Size)
}

func (m *Attach) decode(d *decoder) {
	m.Tag = d.u32()
	m.Size = d.size()
}

func (*Detach) encode(*encoder) {}
func (*Detach) decode(*decoder) {}

func (m *Input) encode(e *encoder) { e.raw(m.Data) }
func (m *Input) decode(d *decoder) { m.Data = d.rest() }

func (m *Resize) encode(e *encoder) { e.size(m.Size) }
func (m *Resize) decode(d *decoder) { m.Size = d.size() }

func (*Kill) encode(*encoder) {}
func (*Kill) decode(*decoder) {}

func (m *HelloReply) encode(e *encoder) {
	e.u32(m.Version)
	e.u16(m.SnapshotVersion)
	e.u32(m.PID)
}

func (m *HelloReply) decode(d *decoder) {
	m.Version = d.u32()
	m.SnapshotVersion = d.u16()
	m.PID = d.u32()
}

func (m *Sessions) encode(e *encoder) {
	e.u32(uint32(len(m.Sessions)))
	for _, s := range m.Sessions {
		e.u32(s.ID)
		e.str(s.Command)
		e.str(s.Title)
		e.str(s.Pwd)
		e.u16(s.Cols)
		e.u16(s.Rows)
		e.bool(s.Attached)
		e.u64(uint64(s.Created))
		e.u32(s.PID)
	}
}

func (m *Sessions) decode(d *decoder) {
	n := d.count(4 + 4*3 + 2*2 + 1 + 8 + 4)
	m.Sessions = make([]SessionInfo, n)
	for i := range m.Sessions {
		s := &m.Sessions[i]
		s.ID = d.u32()
		s.Command = d.str()
		s.Title = d.str()
		s.Pwd = d.str()
		s.Cols = d.u16()
		s.Rows = d.u16()
		s.Attached = d.bool()
		s.Created = int64(d.u64())
		s.PID = d.u32()
	}
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
}

func (m *Attached) decode(d *decoder) {
	m.Tag = d.u32()
	m.SnapshotLen = d.u32()
	n := d.count(4)
	m.Modes = make([]Mode, n)
	for i := range m.Modes {
		m.Modes[i] = Mode{Mode: d.u16(), ANSI: d.bool(), Enabled: d.bool()}
	}
}

func (m *Snapshot) encode(e *encoder) { e.raw(m.Data) }
func (m *Snapshot) decode(d *decoder) { m.Data = d.rest() }

func (m *Output) encode(e *encoder) { e.raw(m.Data) }
func (m *Output) decode(d *decoder) { m.Data = d.rest() }

func (m *Detached) encode(e *encoder) { e.str(m.Reason) }
func (m *Detached) decode(d *decoder) { m.Reason = d.str() }

func (m *Exit) encode(e *encoder) { e.u32(m.Status) }
func (m *Exit) decode(d *decoder) { m.Status = d.u32() }

func (m *Error) encode(e *encoder) {
	e.u32(m.Tag)
	e.str(m.Message)
}

func (m *Error) decode(d *decoder) {
	m.Tag = d.u32()
	m.Message = d.str()
}

// Decode turns a frame's payload into its message. Byte payloads alias
// the frame's.
func Decode(f Frame) (Message, error) {
	var m Message
	switch f.Type {
	case TypeHello:
		m = new(Hello)
	case TypeList:
		m = new(List)
	case TypeNew:
		m = new(New)
	case TypeAttach:
		m = new(Attach)
	case TypeDetach:
		m = new(Detach)
	case TypeInput:
		m = new(Input)
	case TypeResize:
		m = new(Resize)
	case TypeKill:
		m = new(Kill)
	case TypeHelloReply:
		m = new(HelloReply)
	case TypeSessions:
		m = new(Sessions)
	case TypeAttached:
		m = new(Attached)
	case TypeSnapshot:
		m = new(Snapshot)
	case TypeOutput:
		m = new(Output)
	case TypeDetached:
		m = new(Detached)
	case TypeExit:
		m = new(Exit)
	case TypeError:
		m = new(Error)
	default:
		return nil, fmt.Errorf("%w %d", ErrUnknownType, f.Type)
	}
	d := decoder{buf: f.Payload}
	m.decode(&d)
	if d.err != nil {
		return nil, fmt.Errorf("decoding type %d: %w", f.Type, d.err)
	}
	return m, nil
}

// Encode returns m as a frame for session id, ready to write.
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

func (e *encoder) size(s Size) {
	e.u16(s.Cols)
	e.u16(s.Rows)
	e.u32(s.CellW)
	e.u32(s.CellH)
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

func (d *decoder) size() Size {
	return Size{Cols: d.u16(), Rows: d.u16(), CellW: d.u32(), CellH: d.u32()}
}
