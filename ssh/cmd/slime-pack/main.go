// slime-pack builds slimed for each of payload.Targets and writes them,
// gzipped, into internal/payload/bin for slime-ssh to embed. A file whose
// contents haven't changed is left alone.
//
// Usage: go run ./cmd/slime-pack (from ssh/)
package main

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/aldehir/slime/ssh/internal/payload"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("slime-pack: ")
	tmp, err := os.MkdirTemp("", "slime-pack")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(tmp)
	for _, t := range payload.Targets {
		if err := pack(tmp, t.OS, t.Arch); err != nil {
			os.RemoveAll(tmp)
			log.Fatalf("%s/%s: %v", t.OS, t.Arch, err)
		}
	}
}

func pack(tmp, goos, goarch string) error {
	exe := filepath.Join(tmp, "slimed-"+goos+"-"+goarch)
	build := exec.Command("go", "build", "-trimpath", "-ldflags=-s -w", "-o", exe, "./cmd/slimed")
	build.Env = append(os.Environ(), "GOOS="+goos, "GOARCH="+goarch, "CGO_ENABLED=0")
	build.Stdout = os.Stderr
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		return err
	}
	raw, err := os.ReadFile(exe)
	if err != nil {
		return err
	}
	// No name or time in the header, so the same build packs the same.
	var gz bytes.Buffer
	w, err := gzip.NewWriterLevel(&gz, gzip.BestCompression)
	if err != nil {
		return err
	}
	if _, err := w.Write(raw); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	out := filepath.Join("internal", "payload", "bin", payload.Name(goos, goarch))
	if old, err := os.ReadFile(out); err == nil && bytes.Equal(old, gz.Bytes()) {
		return nil
	}
	if err := os.WriteFile(out, gz.Bytes(), 0o644); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "slime-pack: %s: %d KiB (%d KiB unpacked)\n", out, gz.Len()>>10, len(raw)>>10)
	return nil
}
