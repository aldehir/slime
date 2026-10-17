package daemon

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/aldehir/slime/internal/rpc"
)

// The wire protocol between a client and the daemon. A frame is a
// little-endian u32 length of what follows, a u8 type, a u32 pane id
// (0 when the message isn't about one pane), and a payload.
//
// Hello and HelloReply are binary, so a client learns the version
// before it parses anything else, and so is the per-pane path, whose
// cost scales with output: Draw, Image, Copied, and Notice down, Event,
// Ack, and Resize up, laid out as internal/vt's frame.zig and event.zig
// define for every client. Everything that manages the model is a
// JSON-RPC 2.0 object (internal/rpc) in a Call, Reply, or Notify
// envelope, one object per envelope with the envelope's id zero: the
// type lets a reader route without parsing JSON, so the frame path
// never waits on a decode. Binary payloads are fixed-size integers and
// strings (u32 length + bytes); decoders ignore bytes after the fields
// they know, so a later version can append fields.

// Version is exchanged in Hello and HelloReply; peers with different
// versions don't talk.
const Version = 1

// MaxFrame bounds a frame so a corrupt stream can't make us allocate
// gigabytes. Images go out in ImageChunk pieces. A full Draw of a big
// screen whose every cell has its own style and grapheme can come near
// a few MiB, and goes whole.
const (
	MaxFrame   = 8 << 20
	ImageChunk = 1 << 20
)

const headerLen = 1 + 4

type Type uint8

// Client to daemon.
const (
	TypeHello  Type = 1
	TypeCall   Type = 2
	TypeAck    Type = 3
	TypeEvent  Type = 4
	TypeResize Type = 5
	TypeBridge Type = 6
)

// Daemon to client.
const (
	TypeHelloReply Type = 65
	TypeReply      Type = 66
	TypeNotify     Type = 67
	TypeError      Type = 68
	TypeDraw       Type = 69
	TypeImage      Type = 70
	TypeCopied     Type = 71
	TypeNotice     Type = 72
)

var (
	ErrTooLarge    = errors.New("daemon: frame too large")
	ErrShortFrame  = errors.New("daemon: frame shorter than its header")
	ErrTruncated   = errors.New("daemon: payload truncated")
	ErrUnknownType = errors.New("daemon: unknown message type")
	ErrBadJSON     = errors.New("daemon: bad JSON-RPC payload")
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

// The model's types, shared with the control plane's vocabulary.
type (
	Size         = rpc.Size
	Area         = rpc.Area
	Node         = rpc.Node
	Child        = rpc.Child
	Axis         = rpc.Axis
	Direction    = rpc.Direction
	StatusRecord = rpc.StatusRecord
	HostStatus   = rpc.HostState
)

const (
	Whole  = rpc.Whole
	Row    = rpc.Row
	Column = rpc.Column
	Right  = rpc.Right
	Down   = rpc.Down
	Left   = rpc.Left
	Up     = rpc.Up

	HostConnecting = rpc.HostConnecting
	HostConnected  = rpc.HostConnected
	HostFailed     = rpc.HostFailed
	HostLost       = rpc.HostLost
	HostGone       = rpc.HostGone
)

// Hello opens a connection. The client draws what the daemon sends
// (Draw) and sends input back as Event messages; the daemon's terminal
// answers the program's queries.
type Hello struct {
	Version uint32
	// FrameInterval is the least time between a pane's frames, in
	// microseconds: the client's refresh period. Zero for the default.
	FrameInterval uint32
}

type HelloReply struct {
	Version uint32
	PID     uint32
	// FrameLayout is the daemon's vt.FrameLayout. A client whose own
	// differs can't draw its frames.
	FrameLayout uint64
}

// Error answers a connection's first frame when it can't be served: a
// Hello of another version, or a Bridge to a host that isn't there. A
// failed Call gets a Reply with an error instead.
type Error struct{ Message string }

// Call is a method call (rpc.Request) on the connection; the Reply with
// its id answers it.
type Call struct{ Request rpc.Request }

// Reply answers a Call (rpc.Response).
type Reply struct{ Response rpc.Response }

// Notify is an event (rpc.Notification), from the daemon to a viewer of
// the workspace it's about and to the connections subscribed to it.
type Notify struct{ Notification rpc.Notification }

// Bridge, as a connection's first frame instead of Hello, splices the
// connection to `slime connect` on the host in the frame's id: every
// frame after it goes to the host's daemon, and its replies come back.
// Term is the TERM for panes it starts (xterm-ghostty falls back where
// the host lacks it). A bridge that can't be served gets Error and the
// connection closes; one that is gets nothing from the local daemon, so
// the client sends Hello right after Bridge and reads the host daemon's
// HelloReply.
type Bridge struct{ Term string }

// Resize sizes the pane in the frame's id; only its viewer's counts.
type Resize struct{ Size Size }

// Ack says the client drew the pane's Draw Seq and those before it,
// which frees room for more (see Pane's framing).
type Ack struct{ Seq uint32 }

// Event is input for the pane in the frame's id, from its viewer: a
// key, mouse, wheel, paste, focus change, or copy, encoded as
// internal/vt/event.zig lays out.
type Event struct{ Data []byte }

// Draw is a frame of the pane in the frame's id: what to draw, encoded
// as internal/vt/frame.zig lays out. Seq counts the pane's frames to
// this client from 1; Ack them.
type Draw struct {
	Seq  uint32
	Data []byte
}

// Image carries a kitty image the pane in the frame's id places, before
// the first Draw that places it (again, with a new Generation, if the
// program retransmits it): its RGBA pixels, deflated (raw, no header),
// in pieces of up to ImageChunk bytes. Total is the deflated length
// and Offset where Data goes in it; a piece at Offset 0 starts the
// image. Images aren't acked: a Draw's images come between its
// predecessor and it, so they're bounded by the frames in flight.
type Image struct {
	ID         uint32
	Generation uint64
	Width      uint32
	Height     uint32
	Total      uint32
	Offset     uint32
	Data       []byte
}

// Copied answers a copy Event for the pane in the frame's id: Tag is the
// event's, and Text the selection's (empty with none).
type Copied struct {
	Tag  uint32
	Text string
}

// Notice tells the client what the pane in the frame's id did besides
// change its screen: what a terminal of its own would have told it.
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

func (*Hello) Type() Type      { return TypeHello }
func (*Call) Type() Type       { return TypeCall }
func (*Ack) Type() Type        { return TypeAck }
func (*Event) Type() Type      { return TypeEvent }
func (*Resize) Type() Type     { return TypeResize }
func (*Bridge) Type() Type     { return TypeBridge }
func (*HelloReply) Type() Type { return TypeHelloReply }
func (*Reply) Type() Type      { return TypeReply }
func (*Notify) Type() Type     { return TypeNotify }
func (*Error) Type() Type      { return TypeError }
func (*Draw) Type() Type       { return TypeDraw }
func (*Image) Type() Type      { return TypeImage }
func (*Copied) Type() Type     { return TypeCopied }
func (*Notice) Type() Type     { return TypeNotice }

func (m *Hello) encode(e *encoder) {
	e.u32(m.Version)
	e.u32(m.FrameInterval)
}

func (m *Hello) decode(d *decoder) {
	m.Version = d.u32()
	m.FrameInterval = d.u32()
}

func (m *HelloReply) encode(e *encoder) {
	e.u32(m.Version)
	e.u32(m.PID)
	e.u64(m.FrameLayout)
}

func (m *HelloReply) decode(d *decoder) {
	m.Version = d.u32()
	m.PID = d.u32()
	m.FrameLayout = d.u64()
}

func (m *Error) encode(e *encoder) { e.str(m.Message) }
func (m *Error) decode(d *decoder) { m.Message = d.str() }

func (m *Call) encode(e *encoder)   { e.json(m.Request) }
func (m *Call) decode(d *decoder)   { d.json(&m.Request) }
func (m *Reply) encode(e *encoder)  { e.json(m.Response) }
func (m *Reply) decode(d *decoder)  { d.json(&m.Response) }
func (m *Notify) encode(e *encoder) { e.json(m.Notification) }
func (m *Notify) decode(d *decoder) { d.json(&m.Notification) }

func (m *Bridge) encode(e *encoder) { e.str(m.Term) }
func (m *Bridge) decode(d *decoder) { m.Term = d.str() }

func (m *Resize) encode(e *encoder) { e.size(m.Size) }
func (m *Resize) decode(d *decoder) { m.Size = d.size() }

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

func (m *Image) encode(e *encoder) {
	e.u32(m.ID)
	e.u64(m.Generation)
	e.u32(m.Width)
	e.u32(m.Height)
	e.u32(m.Total)
	e.u32(m.Offset)
	e.raw(m.Data)
}

func (m *Image) decode(d *decoder) {
	m.ID = d.u32()
	m.Generation = d.u64()
	m.Width = d.u32()
	m.Height = d.u32()
	m.Total = d.u32()
	m.Offset = d.u32()
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
	case TypeCall:
		return new(Call)
	case TypeAck:
		return new(Ack)
	case TypeEvent:
		return new(Event)
	case TypeResize:
		return new(Resize)
	case TypeBridge:
		return new(Bridge)
	case TypeHelloReply:
		return new(HelloReply)
	case TypeReply:
		return new(Reply)
	case TypeNotify:
		return new(Notify)
	case TypeError:
		return new(Error)
	case TypeDraw:
		return new(Draw)
	case TypeImage:
		return new(Image)
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
	if e.err != nil {
		return nil, e.err
	}
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

// stream is the rest of the input, starting with what's buffered, for
// splicing it elsewhere.
func (r *Reader) stream() io.Reader { return r.r }

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

type encoder struct {
	buf []byte
	err error
}

func (e *encoder) u8(v uint8) { e.buf = append(e.buf, v) }

func (e *encoder) u16(v uint16) { e.buf = binary.LittleEndian.AppendUint16(e.buf, v) }
func (e *encoder) u32(v uint32) { e.buf = binary.LittleEndian.AppendUint32(e.buf, v) }
func (e *encoder) u64(v uint64) { e.buf = binary.LittleEndian.AppendUint64(e.buf, v) }
func (e *encoder) raw(b []byte) { e.buf = append(e.buf, b...) }

func (e *encoder) str(s string) {
	e.u32(uint32(len(s)))
	e.buf = append(e.buf, s...)
}

func (e *encoder) json(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		e.err = err
		return
	}
	e.raw(b)
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

func (d *decoder) json(v any) {
	if d.err != nil {
		return
	}
	if err := json.Unmarshal(d.rest(), v); err != nil {
		d.err = fmt.Errorf("%w: %v", ErrBadJSON, err)
	}
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
