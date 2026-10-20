package daemon

import (
	"os"
	"path/filepath"
	goruntime "runtime"
	"testing"

	"github.com/aldehir/slime/internal/rpc"
)

// TestPwdPath: every form a shell reports its directory in, from this
// host or another, comes out as a local path or nothing.
func TestPwdPath(t *testing.T) {
	windows := goruntime.GOOS == "windows"
	// local is the path /tmp/a b is reported as on this system, and
	// want what the daemon should start a child in.
	local, want := "/tmp/a b", "/tmp/a b"
	if windows {
		local, want = "/C:/tmp/a b", `C:\tmp\a b`
	}
	tests := []struct {
		pwd, host, want string
	}{
		{"file://box" + local, "box", want},
		{"file://box.example.com" + local, "box", want},
		{"file://BOX" + local, "box.lan", want},
		{"file://localhost" + local, "box", want},
		{"file://" + local, "box", want},
		{"file://other" + local, "box", ""},
		{"file://box/tmp/a%20b", "box", pick(windows, "", "/tmp/a b")},
		{"kitty-shell-cwd://box" + local, "box", want},
		{"kitty-shell-cwd://box/tmp/a%20b", "box", pick(windows, "", "/tmp/a%20b")},
		{"kitty-shell-cwd://other" + local, "box", ""},
		{"kitty-shell-cwd://box", "box", ""},
		{"ftp://box" + local, "box", ""},
		{"", "box", ""},
		{"relative/dir", "box", ""},
		{"/", "box", pick(windows, "", "/")},
		{`"C:\Users\x"`, "box", pick(windows, `C:\Users\x`, "")},
		{`C:\Users\x\`, "box", pick(windows, `C:\Users\x`, "")},
		{"file://box/c/Users/x", "box", pick(windows, `C:\Users\x`, "/c/Users/x")},
		{"kitty-shell-cwd://box/c/Users/x", "box", pick(windows, `C:\Users\x`, "/c/Users/x")},
		{"file://box/C:/Users/x", "box", pick(windows, `C:\Users\x`, "/C:/Users/x")},
		{`\Users\x`, "box", ""},
	}
	for _, tc := range tests {
		if got := pwdPath(tc.pwd, tc.host); got != tc.want {
			t.Errorf("pwdPath(%q, %q) = %q, want %q", tc.pwd, tc.host, got, tc.want)
		}
	}
}

func pick(cond bool, yes, no string) string {
	if cond {
		return yes
	}
	return no
}

// TestSplitInheritsPwd: a split starts in the directory its neighbour's
// shell last reported, unless the request names one or the report is
// another host's.
func TestSplitInheritsPwd(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	// A directory that exists, as the shell reports it (OSC 7's path,
	// a slash before the drive on Windows), and as the child starts in
	// it.
	want := filepath.Join(t.TempDir(), "split here")
	if err := os.Mkdir(want, 0o755); err != nil {
		t.Fatal(err)
	}
	reported := filepath.ToSlash(want)
	if goruntime.GOOS == "windows" {
		reported = "/" + reported
	}
	// Nothing reported yet: the daemon's default (no directory).
	w.split(first, Right, 5000, "")
	if dir := h.spawned(1).Dir; dir != "" {
		t.Errorf("before any report, dir %q", dir)
	}
	report := func(pwd string) {
		h.pty(0).emit("\x1b]7;" + pwd + "\x07")
		eventually(t, "the pwd "+pwd, func() bool {
			var d rpc.PaneDesc
			return w.c.Call(rpc.PaneInfo, rpc.PaneParams{ID: first}, &d) == nil && d.Pwd == pwd
		})
	}
	report("kitty-shell-cwd://" + localHost() + reported)
	w.split(first, Down, 5000, "")
	if dir := h.spawned(2).Dir; dir != want {
		t.Errorf("dir %q, want %q", dir, want)
	}
	// Told where, the request wins.
	var created rpc.Created
	if err := w.c.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Down, Cwd: "elsewhere"}, &created); err != nil {
		t.Fatal(err)
	}
	if dir := h.spawned(3).Dir; dir != "elsewhere" {
		t.Errorf("dir %q, want the request's", dir)
	}
	// A browser split beside the shell takes no directory, and a shell
	// split beside the browser gets none.
	if err := w.c.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Right, Kind: rpc.PaneBrowser, URL: "https://a.example"}, &created); err != nil {
		t.Fatal(err)
	}
	w.split(created.Pane, Down, 5000, "")
	if dir := h.spawned(4).Dir; dir != "" {
		t.Errorf("beside a browser, dir %q", dir)
	}
	// Another host's directory is no use here.
	report("file://elsewhere.example" + reported)
	w.split(first, Down, 5000, "")
	if dir := h.spawned(5).Dir; dir != "" {
		t.Errorf("another host's, dir %q", dir)
	}
	// Nor one that's gone: the split still happens, at home.
	report("kitty-shell-cwd://" + localHost() + reported + "/gone")
	w.split(first, Down, 5000, "")
	if dir := h.spawned(6).Dir; dir != "" {
		t.Errorf("a missing directory, dir %q", dir)
	}
}
