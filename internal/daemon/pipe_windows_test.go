package daemon

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// TestHelperShell is the child for TestConPTY: a shell that echoes lines.
func TestHelperShell(t *testing.T) {
	if os.Getenv("SLIME_HELPER_SHELL") == "" {
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
	name := fmt.Sprintf(`\\.\pipe\slime-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
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
		return &window{t: t, h: h, c: c, screens: map[uint32]*vt.Screen{}}
	}

	os.Setenv("SLIME_HELPER_SHELL", "1")
	defer os.Unsetenv("SLIME_HELPER_SHELL")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := syscall.EscapeArg(exe) + " -test.run=^TestHelperShell$"

	w1 := dial()
	var ws rpc.Workspace
	if _, err := w1.call(rpc.WorkspaceNew, nil, &ws); err != nil {
		t.Fatal(err)
	}
	w1.ws = &ws
	var created rpc.Created
	a, err := w1.call(rpc.TabNew, rpc.TabNewParams{Workspace: ws.ID, Command: command, Size: Size{Cols: 80, Rows: 24}}, &created)
	if err != nil {
		t.Fatal(err)
	}
	w1.absorb(a)
	pane := created.Pane
	w1.until(pane, "ready>")
	w1.c.Send(pane, &Event{Data: evText("first\r")})
	w1.until(pane, "got first")
	w1.c.Close()
	eventually(t, "detach", func() bool { return !h.attached(w1.ws.ID) })

	w2 := dial()
	var list rpc.WorkspaceListResult
	if err := w2.c.Call(rpc.WorkspaceList, nil, &list); err != nil || len(list.Workspaces) != 1 || list.Workspaces[0].Attached {
		t.Fatalf("list %+v, %v", list, err)
	}
	w2.attach(list.Workspaces[0].ID, Area{Width: 720, Height: 456, CellW: 9, CellH: 19})
	w2.until(pane, "got first")
	// ConPTY turns on win32-input-mode, which the daemon must track to
	// encode keys for it.
	p := srv.pane(pane)
	p.mu.Lock()
	win32 := p.win32InputLocked()
	t.Logf("modes seen: %+v", p.modes)
	p.mu.Unlock()
	if !win32 {
		t.Error("win32-input-mode not tracked")
	}

	w2.c.Send(pane, &Event{Data: evText("second\r")})
	w2.until(pane, "got second")
	w2.c.Send(pane, &Event{Data: evText("exit\r")})
	if e := nextEvent[rpc.PaneExitedParams](w2, rpc.EvPaneExited); e.Status != 3 {
		t.Errorf("exit status %d, want 3", e.Status)
	}
}
