package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows"
)

func isNotRunning(err error) bool {
	return errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, os.ErrNotExist)
}

// startDaemon runs `slimed serve` with extra arguments so it outlives
// us: detached from our console, and out of our job object if we're in
// one (slime puts its children in a kill-on-close job). Its log goes to
// %LOCALAPPDATA%\slime\slimed.log.
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
	const flags = windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP
	start := func(extra uint32) error {
		cmd := exec.Command(exe, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags | extra}
		if err := cmd.Start(); err != nil {
			return err
		}
		return cmd.Process.Release()
	}
	// Breaking away fails with access denied when our job doesn't allow
	// it; then the daemon dies with the job, but at least it runs.
	if err := start(windows.CREATE_BREAKAWAY_FROM_JOB); err == nil {
		return nil
	}
	return start(0)
}
