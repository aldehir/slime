package proto

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"reflect"
	"sync"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	msgs := []struct {
		id uint32
		m  Message
	}{
		{0, &Hello{Version: Version}},
		{0, &Hello{Version: Version, Features: FeaturePrompts}},
		{1, &Prompt{Kind: PromptInteractive, Title: "Sign in to bastion", Text: "One\nTwo", Questions: []Question{
			{Label: "Duo two-factor login\n\nPasscode or option (1-3): ", Echo: true},
			{Label: "Password: "},
		}}},
		{1, &Prompt{Kind: PromptChangedHost, Title: "t", Detail: "d", Error: "e", Questions: []Question{}}},
		{1, &Answer{Choice: ChoiceAccept, Answers: []string{"1", "hunter2"}}},
		{1, &Answer{Choice: ChoiceCancel, Answers: []string{}}},
		{1, &Info{Text: "Success. Logging you in..."}},
		{1, &Open{In: 0x1234, Out: 0xdeadbeefcafe, Cols: 120, Rows: 40, Term: "xterm-256color", Cwd: "/home/alde/src", Width: 960, Height: 800}},
		{1, &Open{Term: "xterm-256color"}},
		{2, &OpenSlimed{In: 0x10, Out: 0x20, Term: "xterm-ghostty"}},
		{7, &Resize{Cols: 80, Rows: 24}},
		{7, &Resize{Cols: 80, Rows: 24, Width: 640, Height: 480}},
		{7, &Close{}},
		{0, &HelloReply{Version: Version}},
		{0, &Connected{}},
		{3, &Opened{}},
		{3, &Exit{Status: 130}},
		{3, &Exit{Status: -1, Signal: "KILL"}},
		{4, &Error{Message: "open failed: administratively prohibited"}},
		{0, &Disconnected{Reason: "keepalive timeout"}},
	}

	var buf bytes.Buffer
	w := NewWriter(&buf)
	for _, tc := range msgs {
		if err := w.Send(tc.id, tc.m); err != nil {
			t.Fatalf("Send(%T): %v", tc.m, err)
		}
	}

	r := NewReader(&buf)
	for _, tc := range msgs {
		f, err := r.Read()
		if err != nil {
			t.Fatalf("Read for %T: %v", tc.m, err)
		}
		if f.Type != tc.m.Type() || f.ID != tc.id {
			t.Fatalf("header = (%d, %d), want (%d, %d)", f.Type, f.ID, tc.m.Type(), tc.id)
		}
		got, err := Decode(f)
		if err != nil {
			t.Fatalf("Decode(%T): %v", tc.m, err)
		}
		if !reflect.DeepEqual(got, tc.m) {
			t.Errorf("got %#v, want %#v", got, tc.m)
		}
	}
	if _, err := r.Read(); err != io.EOF {
		t.Errorf("Read at end = %v, want io.EOF", err)
	}
}

func TestWireFormat(t *testing.T) {
	var buf bytes.Buffer
	if err := NewWriter(&buf).Send(2, &Resize{Cols: 0x0102, Rows: 0x0304, Width: 0x05060708, Height: 0x090a0b0c}); err != nil {
		t.Fatal(err)
	}
	want := []byte{
		17, 0, 0, 0, // length
		byte(TypeResize),
		2, 0, 0, 0, // id
		0x02, 0x01,
		0x04, 0x03,
		0x08, 0x07, 0x06, 0x05,
		0x0c, 0x0b, 0x0a, 0x09,
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Errorf("wire = % x, want % x", buf.Bytes(), want)
	}
}

// A sender from before the pixel size leaves it out; it reads as zero.
func TestPixelSizeOptional(t *testing.T) {
	m, err := Decode(Frame{Type: TypeResize, Payload: []byte{80, 0, 24, 0}})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(m, &Resize{Cols: 80, Rows: 24}) {
		t.Errorf("resize = %#v", m)
	}

	var e encoder
	(&Open{In: 1, Out: 2, Cols: 80, Rows: 24, Term: "xterm-256color"}).encode(&e)
	m, err = Decode(Frame{Type: TypeOpen, Payload: e.buf[:len(e.buf)-8]})
	if err != nil {
		t.Fatal(err)
	}
	if o := m.(*Open); o.Term != "xterm-256color" || o.Width != 0 || o.Height != 0 {
		t.Errorf("open = %#v", o)
	}
}

func frame(typ Type, id uint32, payload []byte) []byte {
	b := binary.LittleEndian.AppendUint32(nil, uint32(headerLen+len(payload)))
	b = append(b, byte(typ))
	b = binary.LittleEndian.AppendUint32(b, id)
	return append(b, payload...)
}

func TestTrailingBytesIgnored(t *testing.T) {
	payload := binary.LittleEndian.AppendUint32(nil, 5)
	payload = append(payload, 0xaa, 0xbb, 0xcc)
	f, err := NewReader(bytes.NewReader(frame(TypeHello, 0, payload))).Read()
	if err != nil {
		t.Fatal(err)
	}
	m, err := Decode(f)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.(*Hello).Version; got != 5 {
		t.Errorf("Version = %d, want 5", got)
	}
}

func TestTruncatedPayload(t *testing.T) {
	cases := map[string]Frame{
		"short int":           {Type: TypeResize, Payload: []byte{80, 0, 24}},
		"short string length": {Type: TypeError, Payload: []byte{1, 0}},
		"string past end": {
			Type:    TypeError,
			Payload: append(binary.LittleEndian.AppendUint32(nil, 10), "abc"...),
		},
		"huge string length": {
			Type:    TypeError,
			Payload: binary.LittleEndian.AppendUint32(nil, 0xffffffff),
		},
	}
	for name, f := range cases {
		if _, err := Decode(f); !errors.Is(err, ErrTruncated) {
			t.Errorf("%s: err = %v, want ErrTruncated", name, err)
		}
	}
}

func TestUnknownType(t *testing.T) {
	if _, err := Decode(Frame{Type: 200}); !errors.Is(err, ErrUnknownType) {
		t.Errorf("err = %v, want ErrUnknownType", err)
	}
}

// A list can't claim more items than its bytes could hold.
func TestHugeListCount(t *testing.T) {
	payload := []byte{byte(PromptPassword)}
	for range 4 {
		payload = binary.LittleEndian.AppendUint32(payload, 0) // empty strings
	}
	payload = binary.LittleEndian.AppendUint32(payload, 0xffffffff)
	if _, err := Decode(Frame{Type: TypePrompt, Payload: payload}); !errors.Is(err, ErrTruncated) {
		t.Errorf("err = %v, want ErrTruncated", err)
	}
}

func TestBadFrames(t *testing.T) {
	tooLarge := binary.LittleEndian.AppendUint32(nil, MaxFrame+1)
	if _, err := NewReader(bytes.NewReader(tooLarge)).Read(); err != ErrTooLarge {
		t.Errorf("too large: err = %v", err)
	}

	short := append(binary.LittleEndian.AppendUint32(nil, 3), 1, 2, 3)
	if _, err := NewReader(bytes.NewReader(short)).Read(); err != ErrShortFrame {
		t.Errorf("short: err = %v", err)
	}

	whole := frame(TypeError, 1, []byte{0, 0, 0, 0})
	for n := 1; n < len(whole); n++ {
		_, err := NewReader(bytes.NewReader(whole[:n])).Read()
		if err != io.ErrUnexpectedEOF {
			t.Errorf("cut at %d: err = %v, want io.ErrUnexpectedEOF", n, err)
		}
	}
}

// Frames from concurrent senders must not interleave.
func TestConcurrentSend(t *testing.T) {
	var buf bytes.Buffer
	w := NewWriter(&buf)
	const senders, each = 8, 200
	var wg sync.WaitGroup
	for s := range senders {
		wg.Go(func() {
			for range each {
				if err := w.Send(uint32(s), &Error{Message: "interleave me if you can"}); err != nil {
					t.Error(err)
					return
				}
			}
		})
	}
	wg.Wait()

	r := NewReader(&buf)
	for range senders * each {
		f, err := r.Read()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := Decode(f); err != nil {
			t.Fatal(err)
		}
	}
}
