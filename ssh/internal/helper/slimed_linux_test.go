package helper

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

	"github.com/aldehir/slime/ssh/internal/payload"
	"github.com/aldehir/slime/ssh/internal/persist"
	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
	"github.com/aldehir/slime/ssh/internal/vt"
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
		"SLIMED_INSTANCE=helper-test",
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

// rw joins slime's ends of a slimed channel.
type rw struct {
	io.Writer
	io.Reader
	close func() error
}

func (c rw) Close() error { return c.close() }

// dialSlimed logs in over a new connection and returns a persist client
// talking to the host's slimed.
func dialSlimed(t *testing.T, srv *sshtest.Server, knownHosts string) *persist.Client {
	t.Helper()
	h := newDialogHarness(t, srv, knownHosts)
	in, out := h.openSlimedPipes(1, terminfoName)
	h.expectPrompt(proto.PromptPassword)
	h.answer(proto.ChoiceAccept, password)
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	c, err := persist.NewClient(rw{in, out, func() error { out.Close(); return in.Close() }})
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
	build, _ := payload.For("linux", "amd64")
	if _, err := os.Stat(filepath.Join(home, ".cache", "slime", "slimed-"+build.ID)); err != nil {
		t.Fatalf("not installed: %v", err)
	}

	tag := c.NextTag()
	c.Send(0, &persist.WorkspaceNew{Tag: tag})
	created, err := c.AwaitCreated(tag)
	if err != nil {
		t.Fatal(err)
	}
	tag = c.NextTag()
	// No terminfo on this host, so TERM falls back.
	c.Send(0, &persist.TabNew{Tag: tag, WS: created.WS, Command: `echo "marker:$TERM:$HOME"; exec cat`, Size: persist.Size{Cols: 80, Rows: 24}})
	a, err := c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	pane := a.Created.Pane
	want := "marker:xterm-256color:" + home
	waitOutput(t, c, pane, want, a.Panes[pane])
	// Hanging up the SSH connection detaches the workspace.
	c.Close()

	c2 := dialSlimed(t, srv, kh)
	defer c2.Close()
	if c2.Hello.PID != c.Hello.PID {
		t.Errorf("a second daemon: pid %d, then %d", c.Hello.PID, c2.Hello.PID)
	}
	var list *persist.Workspaces
	deadline := time.Now().Add(timeout)
	for {
		if list, err = c2.List(); err != nil {
			t.Fatal(err)
		}
		if w := persist.MostRecentDetached(list); w != nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if w := persist.MostRecentDetached(list); w == nil || w.ID != created.WS {
		t.Fatalf("workspace %d not detached: %+v", created.WS, list)
	}
	p, err := c2.Peek(pane)
	if err != nil {
		t.Fatal(err)
	}
	if text := snapshotText(t, p.Snapshot); !strings.Contains(text, want) {
		t.Errorf("restored text %q", text)
	}
}

// waitOutput reads until pane's output, after what attaching gave,
// holds want.
func waitOutput(t *testing.T, c *persist.Client, pane uint32, want string, p *persist.PaneState) {
	t.Helper()
	var got strings.Builder
	for _, b := range p.Output {
		got.Write(b)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for !strings.Contains(got.String(), want) {
			id, m, err := c.Recv()
			if err != nil {
				return
			}
			if o, ok := m.(*persist.Output); ok && id == pane {
				got.Write(o.Data)
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(timeout):
		t.Fatalf("no %q in %q", want, got.String())
	}
	if !strings.Contains(got.String(), want) {
		t.Fatalf("no %q in %q", want, got.String())
	}
}

func snapshotText(t *testing.T, snap []byte) string {
	t.Helper()
	ctx := context.Background()
	rt, err := vt.NewRuntime(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close(ctx)
	term, err := rt.Decode(snap)
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	s, err := term.Text()
	if err != nil {
		t.Fatal(err)
	}
	return s
}
