package pty

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The pseudoconsole API, from the conpty.dll next to our executable (the
// Microsoft.Windows.Console.ConPTY package slime ships) or else kernel32's
// inbox version, as src/win32/conpty.zig loads it.
type conptyAPI struct {
	create, resize, close proc
	bundled               bool
}

// proc is a *windows.Proc or *windows.LazyProc.
type proc interface {
	Call(a ...uintptr) (r1, r2 uintptr, lastErr error)
}

// From the package's conpty.h. GLYPH_WIDTH_GRAPHEMES makes ConPTY measure
// text the way libghostty-vt does with mode 2027; the inbox ConPTY
// doesn't know it.
const pseudoconsoleGlyphWidthGraphemes = 0x08

// conptyDir, if set, is where conpty.dll is, instead of next to us.
var conptyDir string

// SetConptyDir loads conpty.dll from dir instead of from next to our
// executable: slime runs slimed from a copy, and points it back at its
// own. Call it before the first Start.
func SetConptyDir(dir string) { conptyDir = dir }

func loadConpty() (windows.Handle, error) {
	if conptyDir != "" {
		// conpty.dll finds OpenConsole.exe next to itself.
		return windows.LoadLibraryEx(filepath.Join(conptyDir, "conpty.dll"), 0, windows.LOAD_WITH_ALTERED_SEARCH_PATH)
	}
	return windows.LoadLibraryEx("conpty.dll", 0, windows.LOAD_LIBRARY_SEARCH_APPLICATION_DIR)
}

var loadAPI = sync.OnceValues(func() (*conptyAPI, error) {
	if dll, err := loadConpty(); err == nil {
		// Never unloaded.
		d := &windows.DLL{Name: "conpty.dll", Handle: dll}
		var create, resize, close *windows.Proc
		var errs [3]error
		create, errs[0] = d.FindProc("ConptyCreatePseudoConsole")
		resize, errs[1] = d.FindProc("ConptyResizePseudoConsole")
		close, errs[2] = d.FindProc("ConptyClosePseudoConsole")
		if err := errors.Join(errs[:]...); err != nil {
			return nil, err
		}
		return &conptyAPI{create: create, resize: resize, close: close, bundled: true}, nil
	}
	k := windows.NewLazySystemDLL("kernel32.dll")
	create := k.NewProc("CreatePseudoConsole")
	if err := create.Find(); err != nil {
		return nil, err
	}
	return &conptyAPI{
		create: create,
		resize: k.NewProc("ResizePseudoConsole"),
		close:  k.NewProc("ClosePseudoConsole"),
	}, nil
})

// Bundled says whether ConPTY comes from slime's conpty.dll rather than
// the system's.
func Bundled() bool {
	api, err := loadAPI()
	return err == nil && api.bundled
}

type conpty struct {
	api     *conptyAPI
	hpc     windows.Handle
	in      *os.File // our end of the input pipe
	out     *os.File // our end of the output pipe
	process windows.Handle
	pid     uint32
	job     windows.Handle

	done     chan struct{} // closed once the child has exited
	exitCode uint32
	exitErr  error

	closeOnce sync.Once // ClosePseudoConsole
	freeOnce  sync.Once
}

// Start runs opts.Command in a new pseudoconsole. The child runs in a job
// object that kills it, and everything it starts, when the pty closes.
func Start(opts Options) (Pty, error) {
	api, err := loadAPI()
	if err != nil {
		return nil, fmt.Errorf("pty: loading ConPTY: %w", err)
	}
	command := opts.Command
	if command == "" {
		command = defaultShell()
	}

	var inRead, inWrite, outRead, outWrite windows.Handle
	if err := windows.CreatePipe(&inRead, &inWrite, nil, 0); err != nil {
		return nil, fmt.Errorf("pty: CreatePipe: %w", err)
	}
	defer windows.CloseHandle(inRead)
	if err := windows.CreatePipe(&outRead, &outWrite, nil, 0); err != nil {
		windows.CloseHandle(inWrite)
		return nil, fmt.Errorf("pty: CreatePipe: %w", err)
	}
	// ConPTY duplicates its ends; closing ours means outRead sees EOF
	// once the pseudoconsole closes.
	defer windows.CloseHandle(outWrite)
	c := &conpty{
		api:  api,
		in:   os.NewFile(uintptr(inWrite), "conpty input"),
		out:  os.NewFile(uintptr(outRead), "conpty output"),
		done: make(chan struct{}),
	}

	var flags uintptr
	if api.bundled {
		flags = pseudoconsoleGlyphWidthGraphemes
	}
	r, _, _ := api.create.Call(coord(opts.Cols, opts.Rows), uintptr(inRead), uintptr(outWrite), flags,
		uintptr(unsafe.Pointer(&c.hpc)))
	if hr := int32(r); hr < 0 {
		c.in.Close()
		c.out.Close()
		return nil, fmt.Errorf("pty: CreatePseudoConsole: 0x%08x", uint32(hr))
	}

	if err := c.spawn(command, opts.Dir); err != nil {
		c.closePseudoconsole()
		c.free()
		return nil, err
	}
	go c.wait()
	return c, nil
}

func (c *conpty) spawn(command, dir string) error {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return fmt.Errorf("pty: CreateJobObject: %w", err)
	}
	c.job = job
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{
			LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
		},
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return fmt.Errorf("pty: SetInformationJobObject: %w", err)
	}

	attrs, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		return fmt.Errorf("pty: NewProcThreadAttributeList: %w", err)
	}
	defer attrs.Delete()
	// The attribute's value is the HPCON itself, not a pointer to it.
	hpc := *(*unsafe.Pointer)(unsafe.Pointer(&c.hpc))
	if err := attrs.Update(windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, unsafe.Sizeof(c.hpc)); err != nil {
		return fmt.Errorf("pty: UpdateProcThreadAttribute: %w", err)
	}

	// STARTF_USESTDHANDLES with null handles: otherwise a child of a
	// process with redirected stdio (the daemon, detached) would get
	// those handles instead of the pseudoconsole's.
	si := windows.StartupInfoEx{ProcThreadAttributeList: attrs.List()}
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = windows.STARTF_USESTDHANDLES

	cmd, err := windows.UTF16PtrFromString(command)
	if err != nil {
		return err
	}
	var cwd *uint16
	if dir != "" {
		if cwd, err = windows.UTF16PtrFromString(dir); err != nil {
			return err
		}
	}
	var pi windows.ProcessInformation
	err = windows.CreateProcess(nil, cmd, nil, nil, false,
		windows.EXTENDED_STARTUPINFO_PRESENT|windows.CREATE_UNICODE_ENVIRONMENT|windows.CREATE_SUSPENDED,
		nil, cwd, &si.StartupInfo, &pi)
	if err != nil {
		return fmt.Errorf("pty: CreateProcess %q: %w", command, err)
	}
	defer windows.CloseHandle(pi.Thread)
	c.process = pi.Process
	c.pid = pi.ProcessId
	// Assign before the child runs so anything it starts lands in the
	// job too.
	if err := windows.AssignProcessToJobObject(job, pi.Process); err != nil {
		windows.TerminateProcess(pi.Process, 1)
		return fmt.Errorf("pty: AssignProcessToJobObject: %w", err)
	}
	if _, err := windows.ResumeThread(pi.Thread); err != nil {
		windows.TerminateProcess(pi.Process, 1)
		return fmt.Errorf("pty: ResumeThread: %w", err)
	}
	return nil
}

// wait waits for the child, then closes the pseudoconsole: ConPTY never
// ends its output on its own. Closing flushes what's left and closes the
// pipe, so Read reaches EOF.
func (c *conpty) wait() {
	_, err := windows.WaitForSingleObject(c.process, windows.INFINITE)
	if err == nil {
		err = windows.GetExitCodeProcess(c.process, &c.exitCode)
	}
	c.exitErr = err
	close(c.done)
	c.closePseudoconsole()
}

func (c *conpty) closePseudoconsole() {
	c.closeOnce.Do(func() { c.api.close.Call(uintptr(c.hpc)) })
}

func (c *conpty) Read(p []byte) (int, error) {
	n, err := c.out.Read(p)
	if errors.Is(err, windows.ERROR_BROKEN_PIPE) || errors.Is(err, os.ErrClosed) {
		err = io.EOF
	}
	return n, err
}

func (c *conpty) Write(p []byte) (int, error) { return c.in.Write(p) }

func (c *conpty) Resize(cols, rows uint16) error {
	r, _, _ := c.api.resize.Call(uintptr(c.hpc), coord(cols, rows))
	if hr := int32(r); hr < 0 {
		return fmt.Errorf("pty: ResizePseudoConsole: 0x%08x", uint32(hr))
	}
	return nil
}

func (c *conpty) PID() uint32 { return c.pid }

func (c *conpty) Wait() (uint32, error) {
	<-c.done
	return c.exitCode, c.exitErr
}

// Close kills the job, which ends the child; wait then closes the
// pseudoconsole, and a reader still draining sees EOF. The handles are
// freed once the child is gone.
func (c *conpty) Close() error {
	c.freeOnce.Do(func() {
		windows.TerminateJobObject(c.job, 1)
		<-c.done
		c.closePseudoconsole()
		c.release()
	})
	return nil
}

// free releases a pty that never started its child.
func (c *conpty) free() { c.freeOnce.Do(c.release) }

func (c *conpty) release() {
	c.in.Close()
	c.out.Close()
	if c.process != 0 {
		windows.CloseHandle(c.process)
	}
	if c.job != 0 {
		windows.CloseHandle(c.job)
	}
}

// coord packs a COORD, which is passed by value, into a register.
func coord(cols, rows uint16) uintptr {
	x := min(cols, 0x7fff)
	y := min(rows, 0x7fff)
	return uintptr(x) | uintptr(y)<<16
}

func defaultShell() string {
	if s := os.Getenv("COMSPEC"); s != "" {
		return s
	}
	return `C:\Windows\System32\cmd.exe`
}
