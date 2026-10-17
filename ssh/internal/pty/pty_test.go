package pty

import (
	"bytes"
	"io"
	"testing"
	"time"
)

// readAll reads until EOF, failing after a timeout.
func readAll(t *testing.T, p Pty) string {
	t.Helper()
	var buf bytes.Buffer
	done := make(chan error, 1)
	go func() {
		_, err := io.Copy(&buf, p)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("read: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatalf("no EOF; got %q", buf.String())
	}
	return buf.String()
}
