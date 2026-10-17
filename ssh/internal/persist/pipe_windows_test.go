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

	dial := func() *Client {
		conn, err := Dial(context.Background(), name)
		if err != nil {
			t.Fatal(err)
		}
		c, err := NewClient(conn)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	h := &harness{t: t, srv: srv}

	os.Setenv("SLIMED_HELPER_SHELL", "1")
	defer os.Unsetenv("SLIMED_HELPER_SHELL")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := syscall.EscapeArg(exe) + " -test.run=^TestHelperShell$"

	c1 := dial()
	c1.Send(0, &New{Tag: 1, Command: command, Size: Size{Cols: 80, Rows: 24}})
	v1 := h.view(c1)
	v1.until("ready>")
	c1.Send(v1.id, &Input{Data: []byte("first\r")})
	v1.until("got first")
	c1.Close()
	eventually(t, "detach", func() bool { return !srv.session(v1.id).info().Attached })

	c2 := dial()
	sessions, err := c2.List()
	if err != nil || len(sessions) != 1 || sessions[0].Attached {
		t.Fatalf("list %+v, %v", sessions, err)
	}
	v2 := h.attach(c2, v1.id)
	if s := v2.text(); !strings.Contains(s, "got first") {
		t.Errorf("restored text %q", s)
	}
	win32 := false
	for _, m := range v2.att.Modes {
		if m.Mode == 9001 && !m.ANSI {
			win32 = m.Enabled
		}
	}
	t.Logf("modes in attach: %+v", v2.att.Modes)
	if !win32 {
		t.Error("win32-input-mode not reported")
	}

	c2.Send(v2.id, &Input{Data: []byte("second\r")})
	v2.until("got second")
	c2.Send(v2.id, &Input{Data: []byte("exit\r")})
	for {
		_, m, err := c2.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if e, ok := m.(*Exit); ok {
			if e.Status != 3 {
				t.Errorf("exit status %d, want 3", e.Status)
			}
			break
		}
	}
}
