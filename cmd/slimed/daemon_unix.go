//go:build unix

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func isNotRunning(err error) bool {
	// No socket, or one left by a daemon that died.
	return errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED)
}

// startDaemon runs `slimed serve` with extra arguments so it outlives us:
// in a session of its own, so the hangup that ends an SSH session doesn't
// reach it, with nothing open but its log, which goes to
// ~/.cache/slime/slimed.log.
func startDaemon(extra ...string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	args := append([]string{"serve"}, extra...)
	if dir, err := os.UserCacheDir(); err == nil {
		dir = filepath.Join(dir, "slime")
		if os.MkdirAll(dir, 0o700) == nil {
			args = append(args, "--log", filepath.Join(dir, "slimed.log"))
		}
	}
	cmd := exec.Command(exe, args...)
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	// Reap it if it exits while we're still here.
	go cmd.Wait()
	return nil
}
