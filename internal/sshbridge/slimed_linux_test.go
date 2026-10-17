package sshbridge

import (
	"context"
	"io"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/sshtest"
	"github.com/aldehir/slime/internal/vt"
)

// shellHost runs exec requests with sh, as a real host does, in a home
// and temp directory of their own, so slimed installs and runs its
// daemon there.
func shellHost(t *testing.T) (run func(string, io.Reader, io.Writer, io.Writer) int, home string) {
	root := t.TempDir()
	home = filepath.Join(root, "home")
	tmp := filepath.Join(root, "tmp")
	for _, d := range []string{home, tmp} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	env := []string{
		"HOME=" + home,
		"TMPDIR=" + tmp,
		"SHELL=/bin/sh",
		"PATH=" + os.Getenv("PATH"),
		"SLIMED_INSTANCE=sshbridge-test",
	}
	return func(command string, stdin io.Reader, stdout, stderr io.Writer) int {
		cmd := osexec.Command("/bin/sh", "-c", command)
		cmd.Env = env
		cmd.Dir = home
		cmd.Stdin = stdin
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		// Don't wait on stdin once it's gone: a command that never
		// reads it would hold us until the client hangs up.
		cmd.WaitDelay = time.Second
		if err := cmd.Run(); err != nil {
			if exit, ok := err.(*osexec.ExitError); ok {
				return exit.ExitCode()
			}
			return 127
		}
		return 0
	}, home
}

// rw joins slime's ends of a slimed session.
type rw struct {
	io.Writer
	io.Reader
	close func() error
}

func (c rw) Close() error { return c.close() }

// dialSlimed logs in over a new connection and returns a daemon client
// talking to the host's slimed.
func dialSlimed(t *testing.T, srv *sshtest.Server, knownHosts string) *daemon.Client {
	t.Helper()
	d := startDialog(t, srv, knownHosts)
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, password)
	conn := d.expectConnected()
	b, err := startBridge(t, conn, terminfoName)
	if err != nil {
		t.Fatal(err)
	}
	c, err := daemon.NewClient(rw{b.in, b.out, func() error { b.out.Close(); return b.in.Close() }})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

const terminfoName = "xterm-ghostty"

func TestSlimedOnLinux(t *testing.T) {
	needPayload(t)
	host, home := shellHost(t)
	srv := startServer(t, sshtest.Options{Password: password, Exec: host})
	kh := knownHostsFile(t, srv.KnownHostsLine())

	c := dialSlimed(t, srv, kh)
	t.Cleanup(func() { syscall.Kill(int(c.Hello.PID), syscall.SIGKILL) })
	build, _ := testRemote().For("linux", "amd64")
	if _, err := os.Stat(filepath.Join(home, ".cache", "slime", "slimed-"+build.ID)); err != nil {
		t.Fatalf("not installed: %v", err)
	}

	tag := c.NextTag()
	c.Send(0, &daemon.WorkspaceNew{Tag: tag})
	created, err := c.AwaitCreated(tag)
	if err != nil {
		t.Fatal(err)
	}
	tag = c.NextTag()
	// No terminfo on this host, so TERM falls back.
	c.Send(0, &daemon.TabNew{Tag: tag, WS: created.WS, Command: `echo "marker:$TERM:$HOME"; exec cat`, Size: daemon.Size{Cols: 80, Rows: 24}})
	a, err := c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	pane := a.Created.Pane
	want := "marker:xterm-256color:" + home
	waitText(t, c, pane, want, a.Panes[pane])
	// Hanging up the SSH connection detaches the workspace.
	c.Close()

	c2 := dialSlimed(t, srv, kh)
	defer c2.Close()
	if c2.Hello.PID != c.Hello.PID {
		t.Errorf("a second daemon: pid %d, then %d", c.Hello.PID, c2.Hello.PID)
	}
	var list *daemon.Workspaces
	deadline := time.Now().Add(timeout)
	for {
		if list, err = c2.List(); err != nil {
			t.Fatal(err)
		}
		if w := daemon.MostRecentDetached(list); w != nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if w := daemon.MostRecentDetached(list); w == nil || w.ID != created.WS {
		t.Fatalf("workspace %d not detached: %+v", created.WS, list)
	}
	text, err := c2.Peek(pane, false)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(text), want) {
		t.Errorf("kept text %q", text)
	}
}

// waitText draws pane's frames, after what attaching gave, until its
// screen holds want.
func waitText(t *testing.T, c *daemon.Client, pane uint32, want string, p *daemon.PaneState) {
	t.Helper()
	got := make(chan string, 1)
	go func() {
		s, err := vt.NewScreen()
		if err != nil {
			got <- err.Error()
			return
		}
		defer s.Close()
		var text string
		draw := func(d *daemon.Draw) bool {
			if err := s.Apply(d.Data); err != nil {
				text = err.Error()
				return true
			}
			c.Send(pane, &daemon.Ack{Seq: d.Seq})
			text, _ = s.Text()
			return strings.Contains(text, want)
		}
		for _, d := range p.Draws {
			if draw(d) {
				got <- text
				return
			}
		}
		for {
			id, m, err := c.Recv()
			if err != nil {
				got <- text
				return
			}
			if d, ok := m.(*daemon.Draw); ok && id == pane && draw(d) {
				got <- text
				return
			}
		}
	}()
	select {
	case text := <-got:
		if !strings.Contains(text, want) {
			t.Fatalf("no %q in %q", want, text)
		}
	case <-time.After(timeout):
		t.Fatalf("no %q within %v", want, timeout)
	}
}
