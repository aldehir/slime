package persist

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

// TestHelperShell is the child for TestConPTY: a shell that echoes lines.
func TestHelperShell(t *testing.T) {
	if os.Getenv("SLIMED_HELPER_SHELL") == "" {
		t.Skip("only run as TestConPTY's child")
	}
	fmt.Print("ready>")
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "exit" {
			os.Exit(3)
		}
		fmt.Printf("got %s\r\nready>", line)
	}
	os.Exit(0)
}

func TestConPTY(t *testing.T) {
	name := fmt.Sprintf(`\\.\pipe\slimed-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
	l, err := Listen(name)
	if err != nil {
		t.Fatal(err)
	}
	// A second daemon can't take the name.
	if l2, err := Listen(name); err == nil {
		l2.Close()
		t.Error("second Listen on the same pipe succeeded")
	}
	srv, err := NewServer(runtime(t), Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	go srv.Serve(l)
	t.Cleanup(func() { l.Close() })
	t.Logf("bundled ConPTY: %v", pty.Bundled())

	h := &harness{t: t, srv: srv}
	dial := func() *window {
		conn, err := Dial(context.Background(), name)
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

	os.Setenv("SLIMED_HELPER_SHELL", "1")
	defer os.Unsetenv("SLIMED_HELPER_SHELL")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := syscall.EscapeArg(exe) + " -test.run=^TestHelperShell$"

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
	win32 := false
	for _, m := range a.Panes[pane].Attached.Modes {
		if m.Mode == 9001 && !m.ANSI {
			win32 = m.Enabled
		}
	}
	t.Logf("modes in attach: %+v", a.Panes[pane].Attached.Modes)
	if !win32 {
		t.Error("win32-input-mode not reported")
	}

	w2.c.Send(pane, &Input{Data: []byte("second\r")})
	w2.until(pane, "got second")
	w2.c.Send(pane, &Input{Data: []byte("exit\r")})
	if _, e := next[*Exit](w2); e.Status != 3 {
		t.Errorf("exit status %d, want 3", e.Status)
	}
}
