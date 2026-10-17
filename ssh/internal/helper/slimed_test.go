package helper

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/aldehir/slime/ssh/internal/payload"
	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

// fakeHost answers the helper's slimed commands as a host with uname
// would, installing builds in memory.
type fakeHost struct {
	uname string
	// installErr, if set, is what installing writes to stderr before
	// failing.
	installErr string

	mu        sync.Mutex
	probes    int
	installed map[string][]byte
	connects  []string
}

func (f *fakeHost) exec(command string, stdin io.Reader, stdout, stderr io.Writer) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	args := shArgs(command)
	switch {
	case strings.Contains(command, "uname -sm"):
		f.probes++
		fmt.Fprintf(stdout, "%s\n/home/alde/.cache/slime\n", f.uname)
		for name := range f.installed {
			fmt.Fprintf(stdout, "%s\n", strings.TrimPrefix(name, "/home/alde/.cache/slime/"))
		}
		return 0
	case strings.Contains(command, "gzip -dc"):
		if f.installErr != "" {
			fmt.Fprintln(stderr, f.installErr)
			return 1
		}
		zr, err := gzip.NewReader(stdin)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		exe, err := io.ReadAll(zr)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if f.installed == nil {
			f.installed = map[string][]byte{}
		}
		f.installed[args[0]] = exe
		return 0
	case strings.Contains(command, " connect --term "):
		f.connects = append(f.connects, args[1])
		f.mu.Unlock()
		defer f.mu.Lock()
		// An echo for slimed: what comes in goes back out.
		io.Copy(stdout, stdin)
		return 0
	}
	fmt.Fprintf(stderr, "sh: %s: not found\n", command)
	return 127
}

// shArgs are the arguments after the script in a shCommand.
func shArgs(command string) []string {
	var args []string
	for _, q := range strings.Split(command, "' '")[1:] {
		args = append(args, strings.Trim(q, "'"))
	}
	return args
}

// openSlimed sends an OpenSlimed for channel id and returns slime's
// side of it.
func (h *harness) openSlimed(id uint32, termName string) *term {
	in, out := h.openSlimedPipes(id, termName)
	return &term{t: h.t, keys: in, screen: newScreen(out)}
}

// openSlimedPipes is openSlimed with slime's ends as they are: what it
// writes to slimed, and what slimed sends back.
func (h *harness) openSlimedPipes(id uint32, termName string) (*io.PipeWriter, *io.PipeReader) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h.mu.Lock()
	h.next += 2
	m := &proto.OpenSlimed{In: h.next, Out: h.next + 1, Term: termName}
	h.ends[m.In], h.ends[m.Out] = inR, outW
	h.mu.Unlock()
	h.send(id, m)
	return inW, outR
}

func needPayload(t *testing.T) {
	if _, ok := payload.For("linux", "amd64"); !ok {
		t.Skip("no slimed build to install (go run ./cmd/slime-pack)")
	}
}

func TestSlimedInstallsThenBridges(t *testing.T) {
	needPayload(t)
	host := &fakeHost{uname: "Linux x86_64"}
	srv := startServer(t, sshtest.Options{Password: password, Exec: host.exec})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	sl := h.openSlimed(1, "")

	// Logging in asks in the dialog, on the slimed channel.
	h.expectPrompt(proto.PromptPassword)
	h.answer(proto.ChoiceAccept, password)
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})

	sl.typ("hello slimed")
	sl.expect(t, "hello slimed")
	build, _ := payload.For("linux", "amd64")
	exe := "/home/alde/.cache/slime/slimed-" + build.ID
	host.mu.Lock()
	got, ok := host.installed[exe]
	connects := host.connects
	host.mu.Unlock()
	if !ok || !bytes.HasPrefix(got, []byte("\x7fELF")) {
		t.Fatalf("installed %v at %s (have %v)", ok, exe, host.installed)
	}
	if len(connects) != 1 || connects[0] != "xterm-256color" {
		t.Errorf("connected with TERM %q", connects)
	}

	// Another slimed channel on the connection finds it without looking.
	sl2 := h.openSlimed(2, "")
	h.expect(2, &proto.Opened{})
	sl2.typ("again")
	sl2.expect(t, "again")
	host.mu.Lock()
	probes := host.probes
	host.mu.Unlock()
	if probes != 1 {
		t.Errorf("probed %d times", probes)
	}

	// Closing hangs up on slimed.
	h.send(2, &proto.Close{})
	sl2.expectEOF(t)
}

func TestSlimedFoundNotInstalled(t *testing.T) {
	needPayload(t)
	build, _ := payload.For("linux", "amd64")
	exe := "/home/alde/.cache/slime/slimed-" + build.ID
	host := &fakeHost{uname: "Linux x86_64", installed: map[string][]byte{exe: nil}}
	srv := startServer(t, sshtest.Options{Password: password, Exec: host.exec})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	h.openSlimed(1, "")
	h.expectPrompt(proto.PromptPassword)
	h.answer(proto.ChoiceAccept, password)
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	host.mu.Lock()
	defer host.mu.Unlock()
	if host.installed[exe] != nil {
		t.Error("installed over the build already there")
	}
}

// Where slimed can't run, the channel fails and says why, and the
// connection stays up for a plain shell.
func TestSlimedUnsupportedFallsBack(t *testing.T) {
	for _, tc := range []struct {
		name, uname, installErr, want string
	}{
		{"os", "FreeBSD amd64", "", "slimed doesn't run on FreeBSD amd64"},
		{"no build", "Darwin arm64", "", "carries no slimed for darwin/arm64"},
		{"install", "Linux x86_64", "sh: gzip: not found", "installing slimed: sh: gzip: not found"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.uname == "Linux x86_64" {
				needPayload(t)
			}
			host := &fakeHost{uname: tc.uname, installErr: tc.installErr}
			srv := startServer(t, sshtest.Options{Password: password, Exec: host.exec})
			h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
			sl := h.openSlimed(1, "")
			h.expectPrompt(proto.PromptPassword)
			h.answer(proto.ChoiceAccept, password)
			h.expect(0, &proto.Connected{})
			m := h.nextOn(1)
			if e, ok := m.(*proto.Error); !ok || !strings.Contains(e.Message, tc.want) {
				t.Fatalf("got %#v, want an Error with %q", m, tc.want)
			}
			sl.expectEOF(t)

			tm := h.open(2, 80, 24, "")
			h.expect(2, &proto.Opened{})
			tm.expect(t, "$ ")
		})
	}
}

func TestSlimedNeedsPrompts(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	sl := h.openSlimed(1, "")
	if e, ok := h.nextOn(1).(*proto.Error); !ok || !strings.Contains(e.Message, "dialog") {
		t.Fatalf("got %#v", e)
	}
	sl.expectEOF(t)
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
