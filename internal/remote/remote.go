// Package remote finds the slime builds this program carries for other
// systems, to install on hosts. `remote/manifest` beside the executable
// names each as `os arch sha256 size`, one per line, and the build sits
// beside it gzipped as slime-<os>-<arch>.gz. build.zig writes them
// (src/build/pack.zig); a program without them has nothing to install.
package remote

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Dir is the directory beside the executable that holds the builds.
const Dir = "remote"

// ManifestName is the manifest's file name in Dir.
const ManifestName = "manifest"

// Name is the file a build is kept in, here and on the host.
func Name(goos, goarch string) string {
	return fmt.Sprintf("slime-%s-%s.gz", goos, goarch)
}

// Build is slime for one system.
type Build struct {
	OS, Arch string
	// ID names this build: the first 16 hex digits of the gzipped
	// file's SHA-256. A host keeps it under a name with the ID, so a
	// different build is installed beside it rather than over a
	// running one.
	ID string
	// Size is the gzipped file's, in bytes.
	Size int64
	// Path is the gzipped file.
	Path string
}

// Open opens the gzipped build.
func (b Build) Open() (io.ReadCloser, error) {
	return os.Open(b.Path)
}

// Manifest is the set of builds a directory holds.
type Manifest struct {
	builds []Build
}

// Load reads the manifest in dir. A directory without one is an error
// (os.ErrNotExist); a manifest it can't parse too.
func Load(dir string) (*Manifest, error) {
	f, err := os.Open(filepath.Join(dir, ManifestName))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	m := &Manifest{}
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		b, err := parseLine(line)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", f.Name(), n, err)
		}
		b.Path = filepath.Join(dir, Name(b.OS, b.Arch))
		m.builds = append(m.builds, b)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return m, nil
}

// Beside reads the manifest beside the executable. An executable with
// no remote directory gets an empty manifest, not an error.
func Beside() (*Manifest, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	m, err := Load(filepath.Join(filepath.Dir(exe), Dir))
	if errors.Is(err, os.ErrNotExist) {
		return &Manifest{}, nil
	}
	return m, err
}

func parseLine(line string) (Build, error) {
	f := strings.Fields(line)
	if len(f) != 4 {
		return Build{}, fmt.Errorf("expected `os arch sha256 size`, got %q", line)
	}
	sum, err := hex.DecodeString(f[2])
	if err != nil || len(sum) != 32 {
		return Build{}, fmt.Errorf("bad sha256 %q", f[2])
	}
	size, err := strconv.ParseInt(f[3], 10, 64)
	if err != nil || size < 0 {
		return Build{}, fmt.Errorf("bad size %q", f[3])
	}
	return Build{OS: f[0], Arch: f[1], ID: f[2][:16], Size: size}, nil
}

// For returns the build for an OS and architecture, as Go names them,
// or false if the manifest carries none.
func (m *Manifest) For(goos, goarch string) (Build, bool) {
	for _, b := range m.builds {
		if b.OS == goos && b.Arch == goarch {
			return b, true
		}
	}
	return Build{}, false
}

// Builds lists every build, in the manifest's order.
func (m *Manifest) Builds() []Build {
	return append([]Build(nil), m.builds...)
}
