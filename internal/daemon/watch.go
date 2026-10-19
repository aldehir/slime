package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The config file is watched (Options.Watch) by polling: every interval
// the file and the Lua files beside it (what require and dofile find:
// *.lua, and */init.lua) are stat'd, and a change to any of them, once
// it has held still for a poll, reloads the config as config.reload
// does, config.changed and all. Polling, not ReadDirectoryChangesW: it's
// the same code on every platform, and editors that save by writing a
// temp file and renaming it over the old fool a watch on the file
// itself; a second's poll is cheap on a directory this small.

// watchConfig polls every interval until stop is closed.
func (s *Server) watchConfig(interval time.Duration, stop <-chan struct{}) {
	last := s.configStamp()
	// A change was seen; the reload waits for a poll in which nothing
	// changed, so a file being written isn't read half way.
	pending := false
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		now := s.configStamp()
		switch {
		case now != last:
			last = now
			pending = true
		case pending:
			pending = false
			s.log.Info("config changed; reloading", "path", s.configPath)
			s.reloadConfig()
		}
	}
}

// configStamp is what the config's files are now: each one's name,
// size, and modification time, so a change to any changes the stamp.
// Empty when the directory isn't there.
func (s *Server) configStamp() string {
	dir := filepath.Dir(s.configPath)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	var b strings.Builder
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() {
			name = filepath.Join(name, "init.lua")
		} else if !strings.HasSuffix(name, ".lua") && name != filepath.Base(s.configPath) {
			continue
		}
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		fmt.Fprintf(&b, "%s|%d|%d\n", name, info.Size(), info.ModTime().UnixNano())
	}
	return b.String()
}
