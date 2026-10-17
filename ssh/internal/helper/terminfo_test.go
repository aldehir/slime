package helper

import (
	"testing"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
	"github.com/aldehir/slime/ssh/internal/terminfo"
)

// loginAs logs in on channel 1 asking for TERM term.
func loginAs(t *testing.T, h *harness, term string) *term {
	t.Helper()
	tm := h.openWith(1, &proto.Open{Cols: 80, Rows: 24, Term: term})
	tm.expect(t, "password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	tm.expect(t, "$ ")
	return tm
}

func TestTerminfoAlreadyInstalled(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: sshtest.TerminfoInstalled})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := loginAs(t, h, terminfo.Name)
	tm.typ("info\r")
	tm.expect(t, "term=xterm-ghostty ")
	if srv.Compiled() != "" {
		t.Error("compiled an entry the host already had")
	}
}

func TestTerminfoCompiled(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: sshtest.TerminfoTic})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := loginAs(t, h, terminfo.Name)
	tm.typ("info\r")
	tm.expect(t, "term=xterm-ghostty ")
	if got := srv.Compiled(); got != terminfo.Source {
		t.Errorf("tic got %d bytes, want the %d-byte entry", len(got), len(terminfo.Source))
	}

	// Later channels on the connection get it without checking again.
	tm2 := h.openWith(2, &proto.Open{Cols: 80, Rows: 24, Term: terminfo.Name})
	h.expect(2, &proto.Opened{})
	tm2.expect(t, "$ ")
	tm2.typ("info\r")
	tm2.expect(t, "term=xterm-ghostty ")
}

func TestTerminfoFallback(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: sshtest.TerminfoMissing})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := loginAs(t, h, terminfo.Name)
	tm.typ("info\r")
	tm.expect(t, "term=xterm-256color ")

	tm2 := h.openWith(2, &proto.Open{Cols: 80, Rows: 24, Term: terminfo.Name})
	h.expect(2, &proto.Opened{})
	tm2.expect(t, "$ ")
	tm2.typ("info\r")
	tm2.expect(t, "term=xterm-256color ")
}

// Asking for another TERM leaves the host alone.
func TestTerminfoNotAsked(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: sshtest.TerminfoTic})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := loginAs(t, h, "xterm-256color")
	tm.typ("info\r")
	tm.expect(t, "term=xterm-256color ")
	if srv.Compiled() != "" {
		t.Error("compiled an entry nobody asked for")
	}
}

func TestTerminfoSourceEmbedded(t *testing.T) {
	if len(terminfo.Source) < 1000 || terminfo.Source[:len(terminfo.Name)+1] != terminfo.Name+"|" {
		t.Errorf("embedded source starts %q", terminfo.Source[:min(40, len(terminfo.Source))])
	}
}
