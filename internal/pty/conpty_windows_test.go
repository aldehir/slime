package pty

import (
	"io"
	"strings"
	"testing"
	"time"
)

func TestOutputAndExit(t *testing.T) {
	p, err := Start(Options{Command: `cmd.exe /c echo hello-pty & exit 7`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	t.Logf("bundled ConPTY: %v", Bundled())
	out := readAll(t, p)
	if !strings.Contains(out, "hello-pty") {
		t.Errorf("output %q", out)
	}
	code, err := p.Wait()
	if err != nil || code != 7 {
		t.Errorf("exit %d, %v; want 7", code, err)
	}
}

func TestInputAndResize(t *testing.T) {
	p, err := Start(Options{Command: `cmd.exe /q /k prompt $g`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err := p.Resize(100, 30, 0, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Write([]byte("echo typed-%PROCESSOR_ARCHITECTURE%\r")); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Write([]byte("exit 3\r")); err != nil {
		t.Fatal(err)
	}
	out := readAll(t, p)
	if !strings.Contains(out, "typed-AMD64") {
		t.Errorf("output %q", out)
	}
	if code, _ := p.Wait(); code != 3 {
		t.Errorf("exit %d, want 3", code)
	}
}

// TestClose kills a child that would run for a minute.
func TestClose(t *testing.T) {
	p, err := Start(Options{Command: `ping -n 60 127.0.0.1`, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan string)
	go func() {
		b, _ := io.ReadAll(p)
		done <- string(b)
	}()
	time.Sleep(500 * time.Millisecond)
	start := time.Now()
	p.Close()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("reader didn't see EOF after Close")
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("Close took %v", d)
	}
}
