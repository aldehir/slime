package sshbridge

import (
	"bytes"
	"compress/gzip"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/sshtest"
)

func gunzip(r io.Reader) ([]byte, error) {
	zr, err := gzip.NewReader(r)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(zr)
}

// dialHost logs in to a server backed by host with the password.
func dialHost(t *testing.T, host *fakeHost) *Conn {
	t.Helper()
	srv := startServer(t, sshtest.Options{Password: password, Exec: host.exec})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, password)
	return d.expectConnected()
}

// bridge is the client's end of a `slime connect` session: what it writes
// goes to the host's slime, and what that sends comes back.
type bridge struct {
	in  *io.PipeWriter
	out *io.PipeReader
	sl  *Daemon
}

func startBridge(t *testing.T, conn *Conn, term string) (*bridge, error) {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	sl, err := conn.StartDaemon(term, inR, outW, nil)
	if err != nil {
		return nil, err
	}
	go func() {
		sl.Wait()
		outW.Close()
	}()
	return &bridge{in: inW, out: outR, sl: sl}, nil
}

// echo writes s and expects it back.
func (b *bridge) echo(t *testing.T, s string) {
	t.Helper()
	go b.in.Write([]byte(s))
	buf := make([]byte, len(s))
	done := make(chan error, 1)
	go func() {
		_, err := io.ReadFull(b.out, buf)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil || string(buf) != s {
			t.Fatalf("echoed %q, %v; want %q", buf, err, s)
		}
	case <-time.After(timeout):
		t.Fatalf("nothing echoed for %q", s)
	}
}

func TestDaemonInstallsThenBridges(t *testing.T) {
	needPayload(t)
	host := &fakeHost{uname: "Linux x86_64"}
	conn := dialHost(t, host)

	b, err := startBridge(t, conn, "xterm-ghostty")
	if err != nil {
		t.Fatal(err)
	}
	b.echo(t, "hello slime")
	build, _ := testRemote().For("linux", "amd64")
	exe := "/home/alde/.cache/slime/bin/" + build.ID + "/slime"
	host.mu.Lock()
	got, ok := host.installed[exe]
	connects := host.connects
	host.mu.Unlock()
	if !ok || !bytes.HasPrefix(got, []byte("\x7fELF")) {
		t.Fatalf("installed %v at %s (have %v)", ok, exe, host.installed)
	}
	// No terminfo on this host, so TERM falls back.
	if len(connects) != 1 || connects[0] != "xterm-256color" {
		t.Errorf("connected with TERM %q", connects)
	}

	// Another session on the connection finds it without looking.
	b2, err := startBridge(t, conn, "")
	if err != nil {
		t.Fatal(err)
	}
	b2.echo(t, "again")
	host.mu.Lock()
	probes := host.probes
	host.mu.Unlock()
	if probes != 1 {
		t.Errorf("probed %d times", probes)
	}

	// Hanging up our end ends slime there cleanly.
	b2.in.Close()
	if err := b2.sl.Wait(); err != nil {
		t.Errorf("Wait after hanging up = %v", err)
	}
	// Closing the session ends it too.
	b.sl.Close()
	if _, err := b.out.Read(make([]byte, 1)); err == nil {
		t.Error("output still open after Close")
	}
}

func TestDaemonFoundNotInstalled(t *testing.T) {
	needPayload(t)
	build, _ := testRemote().For("linux", "amd64")
	exe := "/home/alde/.cache/slime/bin/" + build.ID + "/slime"
	host := &fakeHost{uname: "Linux x86_64", installed: map[string][]byte{exe: nil}}
	conn := dialHost(t, host)
	if got, err := conn.EnsureDaemon(nil); err != nil || got != exe {
		t.Fatalf("EnsureDaemon = %q, %v; want %q", got, err, exe)
	}
	host.mu.Lock()
	defer host.mu.Unlock()
	if host.installed[exe] != nil {
		t.Error("installed over the build already there")
	}
}

// Where slime can't run, setting it up fails and says why; the
// connection stays up.
func TestDaemonUnsupported(t *testing.T) {
	for _, tc := range []struct {
		name, uname, installErr, want string
	}{
		{"os", "FreeBSD amd64", "", "slime doesn't run on FreeBSD amd64"},
		{"no build", "Darwin arm64", "", "no build of slime for darwin/arm64"},
		{"install", "Linux x86_64", "sh: gzip: not found", "installing slime: sh: gzip: not found"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.uname == "Linux x86_64" {
				needPayload(t)
			}
			host := &fakeHost{uname: tc.uname, installErr: tc.installErr}
			conn := dialHost(t, host)
			var status []string
			_, err := conn.EnsureDaemon(func(s string) { status = append(status, s) })
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("EnsureDaemon = %v, want %q", err, tc.want)
			}
			if tc.installErr != "" && (len(status) != 1 || status[0] != "installing slime") {
				t.Errorf("status = %q", status)
			}
			select {
			case <-conn.Done():
				t.Error("the connection ended")
			default:
			}
		})
	}
}

// slime failing on the host (it couldn't start its daemon, say) is a
// DaemonError with its last line of stderr.
func TestDaemonFails(t *testing.T) {
	needPayload(t)
	host := &failingHost{fakeHost{uname: "Linux x86_64"}}
	srv := startServer(t, sshtest.Options{Password: password, Exec: host.exec})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, password)
	conn := d.expectConnected()
	sl, err := conn.StartDaemon("", strings.NewReader(""), io.Discard, nil)
	if err != nil {
		t.Fatal(err)
	}
	var failed *DaemonError
	if err := sl.Wait(); !errors.As(err, &failed) || failed.Why != "slime: no socket directory" {
		t.Errorf("Wait = %v", err)
	}
}

// failingHost's slime exits with an error instead of bridging.
type failingHost struct{ fakeHost }

func (f *failingHost) exec(command string, stdin io.Reader, stdout, stderr io.Writer) int {
	if strings.Contains(command, " connect --term ") {
		io.WriteString(stderr, "slime: no socket directory\n")
		return 1
	}
	return f.fakeHost.exec(command, stdin, stdout, stderr)
}

func TestGoPlatform(t *testing.T) {
	for in, want := range map[string]string{
		"Linux x86_64":   "linux/amd64",
		"Linux aarch64":  "linux/arm64",
		"Darwin arm64":   "darwin/arm64",
		"Linux armv7l":   "",
		"MINGW64_NT x86": "",
		"":               "",
	} {
		goos, goarch, ok := goPlatform(in)
		got := ""
		if ok {
			got = goos + "/" + goarch
		}
		if got != want {
			t.Errorf("goPlatform(%q) = %q, want %q", in, got, want)
		}
	}
}
