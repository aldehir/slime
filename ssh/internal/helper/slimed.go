package helper

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/ssh/internal/payload"
	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/terminfo"
)

// Setting slimed up on a host runs these, each under the user's login
// shell, so under sh -c: the login shell may not be POSIX (fish, csh).
// None has a single quote or a !, which csh expands even in quotes.
const (
	// slimedProbe prints `uname -sm`, the directory builds are kept in,
	// and the builds there.
	slimedProbe = `uname -sm; d="${XDG_CACHE_HOME:-$HOME/.cache}/slime"; echo "$d"; for f in "$d"/slimed-*; do [ -x "$f" ] && echo "${f##*/}"; done; true`
	// slimedInstall unpacks a build from stdin to $0, beside which
	// nothing half-written is left.
	slimedInstall = `set -e; umask 077; mkdir -p "${0%/*}"; t="$0.$$"; trap "rm -f \"$t\"" EXIT; gzip -dc >"$t"; chmod 700 "$t"; mv -f "$t" "$0"; trap - EXIT`
	// slimedConnect bridges the session to the daemon, starting it if
	// needed with panes on TERM $1.
	slimedConnect = `exec "$0" connect --term "$1"`
)

// The probe bounds how long a host has to answer; the install, to take
// a build (a few MiB) over a slow link.
const (
	slimedProbeTimeout   = 15 * time.Second
	slimedInstallTimeout = 2 * time.Minute
)

// startSlimed runs slimed on the host, installing it first if the host
// lacks this build, and bridges ch's pipes to `slimed connect` until one
// end hangs up.
func (s *Server) startSlimed(client *ssh.Client, ch *channel) {
	exe, err := s.ensureSlimed(client)
	if err != nil {
		s.slimedFailed(ch, err)
		return
	}
	sess, err := client.NewSession()
	if err != nil {
		s.slimedFailed(ch, err)
		return
	}

	s.mu.Lock()
	if ch.closed || s.state == stateClosing {
		s.mu.Unlock()
		sess.Close()
		s.drop(ch)
		s.finishIfIdle()
		return
	}
	ch.sess = sess
	term := ch.term
	if term == terminfo.Name && !s.ghosttyTerm {
		term = terminfo.Fallback
	}
	s.mu.Unlock()

	var stderr tail
	sess.Stdin = ch.input
	sess.Stdout = ch.out
	sess.Stderr = &stderr
	if err := sess.Start(shCommand(slimedConnect, exe, term)); err != nil {
		sess.Close()
		s.slimedFailed(ch, fmt.Errorf("starting slimed: %w", err))
		return
	}
	log.Printf("channel %d: slimed %s", ch.id, exe)
	s.send(ch.id, &proto.Opened{})

	err = sess.Wait()
	s.mu.Lock()
	closed := ch.closed
	s.mu.Unlock()
	exit, ok := exitMessage(err)
	if ok && !closed {
		if exit.Status != 0 {
			// Its stderr says why, under its own "slimed: ": it couldn't
			// start the daemon, say.
			why := stderr.String(exit)
			if !strings.HasPrefix(why, "slimed: ") {
				why = "slimed: " + why
			}
			s.send(ch.id, &proto.Error{Message: why})
		} else {
			s.send(ch.id, exit)
		}
	}
	s.drop(ch)
	// Otherwise the connection failed, and watch reports that.
	if ok || closed {
		s.finishIfIdle()
	}
}

// slimedFailed reports that slimed couldn't start for ch and drops it.
// The connection stays up with no channels: slime opens a plain one in
// its place, or hangs up.
func (s *Server) slimedFailed(ch *channel, err error) {
	log.Printf("channel %d: no slimed: %v", ch.id, err)
	s.mu.Lock()
	report := !ch.closed && s.state != stateClosing
	s.mu.Unlock()
	if report {
		s.send(ch.id, &proto.Error{Message: err.Error()})
	}
	s.drop(ch)
	s.mu.Lock()
	closed := ch.closed
	s.mu.Unlock()
	if closed {
		s.finishIfIdle()
	}
}

// ensureSlimed returns the path to this slime-ssh's build of slimed on
// the host, installing it if it isn't there yet.
func (s *Server) ensureSlimed(client *ssh.Client) (string, error) {
	s.mu.Lock()
	exe := s.slimedExe
	s.mu.Unlock()
	if exe != "" {
		return exe, nil
	}

	out, err := run(client, shCommand(slimedProbe), nil, slimedProbeTimeout)
	if err != nil {
		return "", fmt.Errorf("looking for slimed: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		return "", fmt.Errorf("looking for slimed: unexpected answer %q", out)
	}
	goos, goarch, ok := goPlatform(lines[0])
	if !ok {
		return "", fmt.Errorf("slimed doesn't run on %s", strings.TrimSpace(lines[0]))
	}
	build, ok := payload.For(goos, goarch)
	if !ok {
		return "", fmt.Errorf("this slime-ssh carries no slimed for %s/%s", goos, goarch)
	}
	name := "slimed-" + build.ID
	exe = strings.TrimSpace(lines[1]) + "/" + name
	installed := false
	for _, l := range lines[2:] {
		installed = installed || strings.TrimSpace(l) == name
	}
	if !installed {
		log.Printf("installing slimed (%s/%s, %d KiB) as %s", goos, goarch, len(build.Gz)>>10, exe)
		if _, err := run(client, shCommand(slimedInstall, exe), build.Gz, slimedInstallTimeout); err != nil {
			return "", fmt.Errorf("installing slimed: %w", err)
		}
	}
	s.mu.Lock()
	s.slimedExe = exe
	s.mu.Unlock()
	return exe, nil
}

// goPlatform maps `uname -sm` to Go's names for it.
func goPlatform(uname string) (goos, goarch string, ok bool) {
	f := strings.Fields(uname)
	if len(f) != 2 {
		return "", "", false
	}
	switch f[0] {
	case "Linux":
		goos = "linux"
	case "Darwin":
		goos = "darwin"
	default:
		return "", "", false
	}
	switch f[1] {
	case "x86_64", "amd64":
		goarch = "amd64"
	case "aarch64", "arm64":
		goarch = "arm64"
	default:
		return "", "", false
	}
	return goos, goarch, true
}

// run runs command on the host with stdin, and returns its stdout. It
// fails if the command does, saying what it wrote to stderr, or if it
// takes longer than timeout.
func run(client *ssh.Client, command string, stdin []byte, timeout time.Duration) ([]byte, error) {
	sess, err := client.NewSession()
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	var stdout bytes.Buffer
	var stderr tail
	sess.Stdout = &stdout
	sess.Stderr = &stderr
	if stdin != nil {
		sess.Stdin = bytes.NewReader(stdin)
	}
	if err := sess.Start(command); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- sess.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			exit, _ := exitMessage(err)
			return nil, errors.New(stderr.String(exit))
		}
		return stdout.Bytes(), nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("no answer in %v", timeout)
	}
}

// shCommand runs script under sh with args as $0, $1, and on.
func shCommand(script string, args ...string) string {
	var b strings.Builder
	b.WriteString("sh -c ")
	b.WriteString(shellQuote(script))
	for _, a := range args {
		b.WriteByte(' ')
		b.WriteString(shellQuote(a))
	}
	return b.String()
}

// tail keeps the end of what a remote command writes to stderr, to say
// why it failed.
type tail struct{ b []byte }

const tailMax = 1024

func (t *tail) Write(p []byte) (int, error) {
	t.b = append(t.b, p...)
	if len(t.b) > tailMax {
		t.b = t.b[len(t.b)-tailMax:]
	}
	return len(p), nil
}

// String is the last line written, or how the command ended if it wrote
// nothing.
func (t *tail) String(exit *proto.Exit) string {
	lines := strings.Split(strings.TrimSpace(string(t.b)), "\n")
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
		return last
	}
	switch {
	case exit == nil:
		return "the connection failed"
	case exit.Signal != "":
		return "killed by signal " + exit.Signal
	}
	return fmt.Sprintf("exited with status %d", exit.Status)
}

var _ io.Writer = (*tail)(nil)
