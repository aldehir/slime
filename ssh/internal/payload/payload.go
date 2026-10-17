// Package payload holds the slimed builds slime-ssh installs on remote
// hosts, gzipped. cmd/slime-pack writes them into bin/ before slime-ssh
// is built; a slime-ssh built without them has nothing to install, and
// its remote sessions don't persist.
package payload

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
)

//go:embed bin
var bin embed.FS

// Targets are the systems slime-pack builds for.
var Targets = []struct{ OS, Arch string }{
	{"linux", "amd64"},
}

// Name is the file a target's build is kept in, here and on the host.
func Name(goos, goarch string) string {
	return fmt.Sprintf("slimed-%s-%s.gz", goos, goarch)
}

// Build is slimed for one system.
type Build struct {
	// Gz is the executable, gzipped.
	Gz []byte
	// ID names this build: a digest of Gz. The host keeps it under a name
	// with the ID, so a different build is installed beside it rather
	// than over a running one.
	ID string
}

// For returns the build for an OS and architecture, as Go names them,
// or false if this slime-ssh carries none.
func For(goos, goarch string) (Build, bool) {
	gz, err := bin.ReadFile("bin/" + Name(goos, goarch))
	if err != nil {
		return Build{}, false
	}
	sum := sha256.Sum256(gz)
	return Build{Gz: gz, ID: hex.EncodeToString(sum[:8])}, true
}
