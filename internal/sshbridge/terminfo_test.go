package sshbridge

import (
	"testing"

	"github.com/aldehir/slime/internal/sshtest"
	"github.com/aldehir/slime/internal/terminfo"
)

// dialTerminfo logs in to a host whose terminfo answers per mode.
func dialTerminfo(t *testing.T, mode sshtest.TerminfoMode) (*Conn, *sshtest.Server) {
	t.Helper()
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: mode})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	return dialPassword(t, d), srv
}

func TestTerminfoAlreadyInstalled(t *testing.T) {
	conn, srv := dialTerminfo(t, sshtest.TerminfoInstalled)
	if !conn.InstallTerminfo() {
		t.Error("not installed")
	}
	if srv.Compiled() != "" {
		t.Error("compiled an entry the host already had")
	}
	if got := conn.Term(terminfo.Name); got != terminfo.Name {
		t.Errorf("Term = %q", got)
	}
}

func TestTerminfoCompiled(t *testing.T) {
	conn, srv := dialTerminfo(t, sshtest.TerminfoTic)
	if !conn.InstallTerminfo() {
		t.Error("not installed")
	}
	if got := srv.Compiled(); got != terminfo.Source {
		t.Errorf("tic got %d bytes, want the %d-byte entry", len(got), len(terminfo.Source))
	}
}

func TestTerminfoFallback(t *testing.T) {
	conn, _ := dialTerminfo(t, sshtest.TerminfoMissing)
	if conn.InstallTerminfo() {
		t.Error("installed with no tic")
	}
	if got := conn.Term(terminfo.Name); got != terminfo.Fallback {
		t.Errorf("Term = %q", got)
	}
	if got := conn.Term("screen"); got != "screen" {
		t.Errorf("Term(screen) = %q", got)
	}
}

func TestTerminfoSourceEmbedded(t *testing.T) {
	if len(terminfo.Source) < 1000 || terminfo.Source[:len(terminfo.Name)+1] != terminfo.Name+"|" {
		t.Errorf("embedded source starts %q", terminfo.Source[:min(40, len(terminfo.Source))])
	}
}
