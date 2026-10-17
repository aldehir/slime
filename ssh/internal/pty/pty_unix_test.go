//go:build unix

package pty

import (
	"strings"
	"testing"
	"time"
)

func TestOutputAndExit(t *testing.T) {
	p, err := Start(Options{Command: `echo hello-pty $TERM; exit 7`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	out := readAll(t, p)
	if !strings.Contains(out, "hello-pty "+term) {
		t.Errorf("output %q", out)
	}
	code, err := p.Wait()
	if err != nil || code != 7 {
		t.Errorf("exit %d, %v; want 7", code, err)
	}
}

func TestInputAndResize(t *testing.T) {
	p, err := Start(Options{Command: `read line; stty size; echo "got $line"; exit 3`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err := p.Resize(100, 30, 1000, 600); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Write([]byte("typed\r")); err != nil {
		t.Fatal(err)
	}
	out := readAll(t, p)
	if !strings.Contains(out, "30 100") || !strings.Contains(out, "got typed") {
		t.Errorf("output %q", out)
	}
	if code, _ := p.Wait(); code != 3 {
		t.Errorf("exit %d; want 3", code)
	}
}

// A job left running in the background holds the pty open; the pane
// still ends with its child.
func TestBackgroundJobDoesNotHoldIt(t *testing.T) {
	p, err := Start(Options{Command: `sleep 30 & echo started`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	start := time.Now()
	if out := readAll(t, p); !strings.Contains(out, "started") {
		t.Errorf("output %q", out)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("took %v to end", d)
	}
}

func TestCloseKillsTheSession(t *testing.T) {
	p, err := Start(Options{Command: `trap '' HUP; echo ready; sleep 60`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	if n, _ := p.Read(buf); !strings.Contains(string(buf[:n]), "ready") {
		t.Fatalf("read %q", buf[:n])
	}
	p.Close()
	done := make(chan uint32, 1)
	go func() { code, _ := p.Wait(); done <- code }()
	select {
	case code := <-done:
		// SIGKILL, after ignoring the hangup.
		if code != 128+9 {
			t.Errorf("exit %d; want %d", code, 128+9)
		}
	case <-time.After(killGrace + 5*time.Second):
		t.Fatal("still running after Close")
	}
}
