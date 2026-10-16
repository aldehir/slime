// Package proto is the control protocol between slime and slime-ssh,
// carried on the helper's stdin and stdout.
//
// Every frame is a little-endian u32 length (of what follows), a u8
// type, a u32 channel id (0 for the connection), and a payload. Payload
// fields are fixed-size integers or strings (u32 length + UTF-8).
//
// Decoders ignore bytes after the fields they know, so a later version
// can append fields to a message without breaking an older peer.
package proto

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Version is exchanged in Hello and HelloReply. Peers with different
// versions don't talk.
const Version = 1

// MaxFrame bounds a frame's length so a corrupt stream can't make us
// allocate gigabytes.
const MaxFrame = 1 << 20

// headerLen is the type and id that every frame's length covers.
const headerLen = 1 + 4

type Type uint8

// slime to helper.
const (
	TypeHello  Type = 1
	TypeOpen   Type = 2
	TypeResize Type = 3
	TypeClose  Type = 4
)

// Helper to slime.
const (
	TypeHelloReply   Type = 65
	TypeConnected    Type = 66
	TypeOpened       Type = 67
	TypeExit         Type = 68
	TypeError        Type = 69
	TypeDisconnected Type = 70
	// TypePrompt is reserved for structured auth prompts.
	TypePrompt Type = 71
)

var (
	ErrTooLarge    = errors.New("proto: frame too large")
	ErrShortFrame  = errors.New("proto: frame shorter than its header")
	ErrTruncated   = errors.New("proto: payload truncated")
	ErrUnknownType = errors.New("proto: unknown message type")
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

// Open asks for a new channel. In and Out are the helper's ends of the
// channel's pipes, duplicated into the helper's process: it reads the
// user's input from In and writes the remote's output to Out.
type Open struct {
	In, Out    uint64
	Cols, Rows uint16
	Term       string
	// Cwd, if set, is where the remote shell starts.
	Cwd string
}

type Resize struct{ Cols, Rows uint16 }

type Close struct{}

type HelloReply struct{ Version uint32 }

// Connected says authentication is done and further channels open
// without prompting.
type Connected struct{}

type Opened struct{}

// Exit reports how a channel's remote command ended. Status is -1 when
// it was killed by Signal.
type Exit struct {
	Status int32
	Signal string
}

type Error struct{ Message string }

type Disconnected struct{ Reason string }

func (*Hello) Type() Type        { return TypeHello }
func (*Open) Type() Type         { return TypeOpen }
func (*Resize) Type() Type       { return TypeResize }
func (*Close) Type() Type        { return TypeClose }
func (*HelloReply) Type() Type   { return TypeHelloReply }
func (*Connected) Type() Type    { return TypeConnected }
func (*Opened) Type() Type       { return TypeOpened }
func (*Exit) Type() Type         { return TypeExit }
func (*Error) Type() Type        { return TypeError }
func (*Disconnected) Type() Type { return TypeDisconnected }

func (m *Hello) encode(e *encoder) { e.u32(m.Version) }
func (m *Hello) decode(d *decoder) { m.Version = d.u32() }

func (m *Open) encode(e *encoder) {
	e.u64(m.In)
	e.u64(m.Out)
	e.u16(m.Cols)
	e.u16(m.Rows)
	e.str(m.Term)
	e.str(m.Cwd)
}

func (m *Open) decode(d *decoder) {
	m.In = d.u64()
	m.Out = d.u64()
	m.Cols = d.u16()
	m.Rows = d.u16()
	m.Term = d.str()
	m.Cwd = d.str()
}

func (m *Resize) encode(e *encoder) {
	e.u16(m.Cols)
	e.u16(m.Rows)
}

func (m *Resize) decode(d *decoder) {
	m.Cols = d.u16()
	m.Rows = d.u16()
}

func (*Close) encode(*encoder) {}
func (*Close) decode(*decoder) {}

func (m *HelloReply) encode(e *encoder) { e.u32(m.Version) }
func (m *HelloReply) decode(d *decoder) { m.Version = d.u32() }

func (*Connected) encode(*encoder) {}
func (*Connected) decode(*decoder) {}

func (*Opened) encode(*encoder) {}
func (*Opened) decode(*decoder) {}

func (m *Exit) encode(e *encoder) {
	e.u32(uint32(m.Status))
	e.str(m.Signal)
}

func (m *Exit) decode(d *decoder) {
	m.Status = int32(d.u32())
	m.Signal = d.str()
}

func (m *Error) encode(e *encoder) { e.str(m.Message) }
func (m *Error) decode(d *decoder) { m.Message = d.str() }

func (m *Disconnected) encode(e *encoder) { e.str(m.Reason) }
func (m *Disconnected) decode(d *decoder) { m.Reason = d.str() }

// Decode turns a frame's payload into its message.
func Decode(f Frame) (Message, error) {
	var m Message
	switch f.Type {
	case TypeHello:
		m = new(Hello)
	case TypeOpen:
		m = new(Open)
	case TypeResize:
		m = new(Resize)
	case TypeClose:
		m = new(Close)
	case TypeHelloReply:
		m = new(HelloReply)
	case TypeConnected:
		m = new(Connected)
	case TypeOpened:
		m = new(Opened)
	case TypeExit:
		m = new(Exit)
	case TypeError:
		m = new(Error)
	case TypeDisconnected:
		m = new(Disconnected)
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

// Reader reads frames.
type Reader struct {
	r *bufio.Reader
}

func NewReader(r io.Reader) *Reader {
	return &Reader{r: bufio.NewReader(r)}
}

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

// Writer writes frames. Safe to use from several goroutines; each frame
// goes out in one Write.
type Writer struct {
	mu sync.Mutex
	w  io.Writer
}

func NewWriter(w io.Writer) *Writer {
	return &Writer{w: w}
}

// Send writes m as a frame for channel id.
func (w *Writer) Send(id uint32, m Message) error {
	e := encoder{buf: make([]byte, 4+headerLen, 64)}
	m.encode(&e)
	if len(e.buf)-4 > MaxFrame {
		return ErrTooLarge
	}
	binary.LittleEndian.PutUint32(e.buf[0:4], uint32(len(e.buf)-4))
	e.buf[4] = byte(m.Type())
	binary.LittleEndian.PutUint32(e.buf[5:9], id)

	w.mu.Lock()
	defer w.mu.Unlock()
	_, err := w.w.Write(e.buf)
	return err
}

type encoder struct{ buf []byte }

func (e *encoder) u16(v uint16) { e.buf = binary.LittleEndian.AppendUint16(e.buf, v) }
func (e *encoder) u32(v uint32) { e.buf = binary.LittleEndian.AppendUint32(e.buf, v) }
func (e *encoder) u64(v uint64) { e.buf = binary.LittleEndian.AppendUint64(e.buf, v) }

func (e *encoder) str(s string) {
	e.u32(uint32(len(s)))
	e.buf = append(e.buf, s...)
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
