package remote

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	manifest := "# builds\n\nlinux amd64 " + sum + " 1234\n  darwin arm64 " + strings.Repeat("ff", 32) + " 7\n"
	if err := os.WriteFile(filepath.Join(dir, ManifestName), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, Name("linux", "amd64")), []byte("gz"), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	b, ok := m.For("linux", "amd64")
	if !ok {
		t.Fatal("no linux/amd64")
	}
	if b.ID != "0123456789abcdef" || b.Size != 1234 || b.Path != filepath.Join(dir, "slime-linux-amd64.gz") {
		t.Errorf("build %+v", b)
	}
	f, err := b.Open()
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(f)
	f.Close()
	if string(data) != "gz" {
		t.Errorf("read %q", data)
	}
	if d, ok := m.For("darwin", "arm64"); !ok || d.ID != "ffffffffffffffff" || d.Size != 7 {
		t.Errorf("darwin build %+v %v", d, ok)
	}
	if _, ok := m.For("linux", "arm64"); ok {
		t.Error("found a build the manifest lacks")
	}
	if n := len(m.Builds()); n != 2 {
		t.Errorf("%d builds", n)
	}
}

func TestLoadRejectsBadLines(t *testing.T) {
	for _, line := range []string{
		"linux amd64 " + sum,
		"linux amd64 abc 12",
		"linux amd64 " + sum + " many",
		"linux amd64 " + sum + " -1",
	} {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, ManifestName), []byte(line+"\n"), 0o644)
		if _, err := Load(dir); err == nil {
			t.Errorf("%q: loaded", line)
		}
	}
}

func TestLoadMissing(t *testing.T) {
	if _, err := Load(t.TempDir()); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("err %v", err)
	}
}
