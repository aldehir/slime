package daemon

import (
	"net/url"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"sync"
)

// localHost is this machine's name, as the shells it runs report it
// in OSC 7 ($HOSTNAME, $HOST): found once.
var localHost = sync.OnceValue(func() string {
	name, _ := os.Hostname()
	return name
})

// pwdPath is the directory a shell's reported working directory names
// on host, as a path the host's processes can start in, or "" if it
// is another host's, relative, or of no known form. The forms are
// OSC 7's file://host/path (percent-encoded), kitty's
// kitty-shell-cwd://host/path (not), and the bare path of OSC 9;9
// and 1337, which ConEmu and Windows Terminal's PowerShell hook write
// quoted. No host, or localhost, is this one. On Windows the path
// comes in with a leading slash before the drive (/C:/Users), or as
// MSYS spells it (/c/Users), and goes out as C:\Users.
func pwdPath(pwd, host string) string {
	pwd = strings.TrimSpace(pwd)
	var path string
	switch {
	case strings.HasPrefix(pwd, "file://"):
		h, p, ok := splitHostPath(pwd[len("file://"):])
		if !ok || !sameHost(h, host) {
			return ""
		}
		if path, _ = url.PathUnescape(p); path == "" {
			return ""
		}
	case strings.HasPrefix(pwd, "kitty-shell-cwd://"):
		h, p, ok := splitHostPath(pwd[len("kitty-shell-cwd://"):])
		if !ok || !sameHost(h, host) {
			return ""
		}
		path = p
	case strings.Contains(pwd, "://"):
		return ""
	default:
		path = strings.TrimSuffix(strings.TrimPrefix(pwd, `"`), `"`)
	}
	return localizePath(path)
}

// splitHostPath takes host/path apart; ok is false without a path.
func splitHostPath(s string) (host, path string, ok bool) {
	i := strings.IndexByte(s, '/')
	if i < 0 {
		return "", "", false
	}
	return s[:i], s[i:], true
}

// sameHost is whether a reported host names this one: none, localhost,
// or ours by name, with or without a domain on either side.
func sameHost(reported, local string) bool {
	if reported == "" || strings.EqualFold(reported, "localhost") {
		return true
	}
	short := func(s string) string { s, _, _ = strings.Cut(s, "."); return s }
	return strings.EqualFold(reported, local) || strings.EqualFold(short(reported), short(local))
}

// localizePath is path as this system spells an absolute one, or ""
// if it isn't one.
func localizePath(path string) string {
	if goruntime.GOOS == "windows" {
		// /C:/Users or /c/Users, as a shell on Windows reports.
		if len(path) >= 3 && path[0] == '/' && isDriveLetter(path[1]) && (path[2] == ':' || path[2] == '/') {
			drive := strings.ToUpper(path[1:2])
			if path[2] == ':' {
				path = drive + path[2:]
			} else {
				path = drive + ":" + path[2:]
			}
		}
		path = filepath.Clean(filepath.FromSlash(path))
		// IsAbs wants a drive: \Users is relative to the current one.
		if !filepath.IsAbs(path) || filepath.VolumeName(path) == "" {
			return ""
		}
		return path
	}
	if !strings.HasPrefix(path, "/") {
		return ""
	}
	return filepath.Clean(path)
}

func isDriveLetter(c byte) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z'
}
