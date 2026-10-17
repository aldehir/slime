//go:build unix

package persist

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aldehir/slime/ssh/internal/vt"
)

// testAddr is a socket in a fresh private directory.
func testAddr(t *testing.T) string {
	dir := filepath.Join(t.TempDir(), "slimed")
	return filepath.Join(dir, "sock")
}

func TestUnixSocket(t *testing.T) {
	addr := testAddr(t)
	l, err := Listen(addr)
	if err != nil {
		t.Fatal(err)
	}
	// A second daemon can't take it.
	if l2, err := Listen(addr); err == nil {
		l2.Close()
		t.Error("second Listen on the same socket succeeded")
	}
	srv, err := NewServer(runtime(t), Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	go srv.Serve(l)
	t.Cleanup(func() { l.Close() })

	h := &harness{t: t, srv: srv}
	dial := func() *window {
		conn, err := Dial(context.Background(), addr)
		if err != nil {
			t.Fatal(err)
		}
		c, err := NewClient(conn)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return &window{t: t, h: h, c: c, terms: map[uint32]*vt.Terminal{}}
	}
	command := `printf 'ready>'; while read l; do [ "$l" = exit ] && exit 3; printf 'got %s\r\nready>' "$l"; done`

	w1 := dial()
	tag := w1.c.NextTag()
	w1.c.Send(0, &WorkspaceNew{Tag: tag})
	a, err := w1.c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	w1.absorb(a)
	tag = w1.c.NextTag()
	w1.c.Send(0, &TabNew{Tag: tag, WS: w1.ws.ID, Command: command, Size: Size{Cols: 80, Rows: 24}})
	if a, err = w1.c.Await(tag, true); err != nil {
		t.Fatal(err)
	}
	w1.absorb(a)
	pane := a.Created.Pane
	w1.until(pane, "ready>")
	w1.c.Send(pane, &Input{Data: []byte("first\r")})
	w1.until(pane, "got first")
	w1.c.Close()
	eventually(t, "detach", func() bool { return !h.attached(w1.ws.ID) })

	w2 := dial()
	list, err := w2.c.List()
	if err != nil || len(list.Workspaces) != 1 || list.Workspaces[0].Attached {
		t.Fatalf("list %+v, %v", list, err)
	}
	tag = w2.c.NextTag()
	w2.c.Send(0, &WorkspaceAttach{Tag: tag, WS: list.Workspaces[0].ID, Area: Area{Width: 720, Height: 456, CellW: 9, CellH: 19}})
	if a, err = w2.c.Await(tag, false); err != nil {
		t.Fatal(err)
	}
	w2.absorb(a)
	if s := w2.text(pane); !strings.Contains(s, "got first") {
		t.Errorf("restored text %q", s)
	}
	w2.c.Send(pane, &Input{Data: []byte("second\r")})
	w2.until(pane, "got second")
	w2.c.Send(pane, &Input{Data: []byte("exit\r")})
	if _, e := next[*Exit](w2); e.Status != 3 {
		t.Errorf("exit status %d, want 3", e.Status)
	}
}

// A socket left by a daemon that died doesn't stop the next listening.
func TestUnixStaleSocket(t *testing.T) {
	addr := testAddr(t)
	if err := os.Mkdir(filepath.Dir(addr), 0o700); err != nil {
		t.Fatal(err)
	}
	dead, err := net.Listen("unix", addr)
	if err != nil {
		t.Fatal(err)
	}
	dead.(*net.UnixListener).SetUnlinkOnClose(false)
	dead.Close()
	if _, err := Dial(context.Background(), addr); err == nil {
		t.Fatal("dialed a dead socket")
	}
	l, err := Listen(addr)
	if err != nil {
		t.Fatal(err)
	}
	l.Close()
	if _, err := os.Stat(addr); !os.IsNotExist(err) {
		t.Errorf("socket left after Close: %v", err)
	}
}

func TestUnixDirOpenToOthers(t *testing.T) {
	addr := testAddr(t)
	if err := os.Mkdir(filepath.Dir(addr), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(addr), 0o755); err != nil {
		t.Fatal(err)
	}
	if l, err := Listen(addr); err == nil {
		l.Close()
		t.Fatal("listened in a directory others can enter")
	}
	if _, err := Dial(context.Background(), addr); err == nil || !strings.Contains(err.Error(), "open to other users") {
		t.Fatalf("dial: %v", err)
	}
}
