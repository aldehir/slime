package helper

import (
	"os"
	"testing"

	"golang.org/x/sys/windows"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

// winPipes makes a channel's pipes as slime does, without the move to
// another process: the helper's ends are duplicated within this one.
func winPipes(t *testing.T) (in, out uint64, keys, screen *os.File) {
	t.Helper()
	var inR, inW, outR, outW windows.Handle
	if err := windows.CreatePipe(&inR, &inW, nil, 0); err != nil {
		t.Fatal(err)
	}
	if err := windows.CreatePipe(&outR, &outW, nil, 0); err != nil {
		t.Fatal(err)
	}
	return uint64(inR), uint64(outW), os.NewFile(uintptr(inW), "keys"), os.NewFile(uintptr(outR), "screen")
}

func TestOpenHandles(t *testing.T) {
	in, out, keys, screen := winPipes(t)
	defer keys.Close()
	defer screen.Close()
	r, w, err := openHandles(in, out)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()

	keys.Write([]byte("ping"))
	buf := make([]byte, 4)
	if _, err := r.Read(buf); err != nil || string(buf) != "ping" {
		t.Fatalf("read %q, %v", buf, err)
	}
	w.Write([]byte("pong"))
	if _, err := screen.Read(buf); err != nil || string(buf) != "pong" {
		t.Fatalf("read %q, %v", buf, err)
	}
	// Closing the helper's output end is EOF for slime.
	w.Close()
	if _, err := screen.Read(buf); err == nil {
		t.Error("no EOF after the helper closed its end")
	}
}

func TestOpenHandlesRefusesNonPipes(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "notapipe")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	in, out, keys, screen := winPipes(t)
	defer keys.Close()
	defer screen.Close()
	defer windows.CloseHandle(windows.Handle(in))
	defer windows.CloseHandle(windows.Handle(out))

	if _, _, err := openHandles(uint64(f.Fd()), out); err == nil {
		t.Error("accepted a file")
	}
	if _, _, err := openHandles(in, 0xdead0); err == nil {
		t.Error("accepted a bogus handle")
	}
}

// A whole session over real pipes, including the helper unblocking its
// read of a pipe that slime still holds open when the session ends.
func TestServeOverWindowsPipes(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))

	in, out, keys, screenFile := winPipes(t)
	defer keys.Close()
	h.send(1, &proto.Open{In: in, Out: out, Cols: 80, Rows: 24})
	scr := newScreen(screenFile)
	scr.expect(t, "password: ")
	keys.Write([]byte(password + "\r"))
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	scr.expect(t, "$ ")
	keys.Write([]byte("info\r"))
	scr.expect(t, "size=80x24")
	keys.Write([]byte("exit 7\r"))
	h.expect(1, &proto.Exit{Status: 7})
	scr.expectEOF(t)
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}
