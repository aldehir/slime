package lua

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	glua "github.com/yuin/gopher-lua"
)

// Processes: slime.exec runs a program on the daemon's host and waits
// for it; slime.exec.start runs one and hands back a handle to write
// to, wait for, or kill, with its output collected for wait or passed
// to callbacks as it comes (in tasks, through the dispatcher, in
// order). A process doesn't keep a run alive; one still running when
// the run ends is killed.

// proc is one started process.
type proc struct {
	r   *Runner
	cmd *exec.Cmd
	// stdin is the pipe, when the script asked to write to it.
	stdin io.WriteCloser
	// onStdout and onStderr take the output as it comes; without one
	// the stream is collected for wait.
	onStdout, onStderr *glua.LFunction
	ids                IDs
	done               chan struct{}

	mu     sync.Mutex
	stdout strings.Builder
	stderr strings.Builder
	status int
	exited bool
}

const procType = "slime.process"

// installExec sets slime.exec (callable, with exec.start) and the
// process type.
func (r *Runner) installExec() {
	L := r.L
	ex := L.NewTable()
	ex.RawSetString("start", L.NewFunction(r.luaExecStart))
	mt := L.NewTable()
	mt.RawSetString("__call", L.NewFunction(func(L *glua.LState) int {
		// __call gets the table first.
		L.Remove(1)
		return r.luaExec(L)
	}))
	L.SetMetatable(ex, mt)
	r.slime.RawSetString("exec", ex)

	pmt := L.NewTypeMetatable(procType)
	methods := L.SetFuncs(L.NewTable(), map[string]glua.LGFunction{
		"wait":        r.procWait,
		"write":       r.procWrite,
		"close_stdin": procCloseStdin,
		"kill":        procKill,
		"running":     procRunning,
	})
	pmt.RawSetString("__index", L.NewFunction(func(L *glua.LState) int {
		p := checkProc(L)
		if key := L.CheckString(2); key == "pid" {
			L.Push(glua.LNumber(p.cmd.Process.Pid))
			return 1
		}
		L.Push(methods.RawGetString(L.CheckString(2)))
		return 1
	}))
}

// luaExec is slime.exec(argv, opts): the program run to its end, with
// {status, ok, stdout, stderr}; nil, err if it couldn't start, or
// timed out (opts.timeout seconds; it's killed then).
func (r *Runner) luaExec(L *glua.LState) int {
	opts := L.OptTable(2, nil)
	p, err := r.startProc(L, L.Get(1), opts)
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	var timeout time.Duration
	if opts != nil {
		if n, ok := opts.RawGetString("timeout").(glua.LNumber); ok && n > 0 {
			timeout = time.Duration(float64(n) * float64(time.Second))
		}
	}
	if !r.waitProc(L, p, timeout) {
		p.kill()
		r.waitProc(L, p, 0)
		return pushError(L, fmt.Sprintf("timed out after %gs", timeout.Seconds()), 0)
	}
	L.Push(p.result(L))
	return 1
}

// luaExecStart is slime.exec.start(argv, opts): the process, started,
// as a handle; nil, err if it couldn't start.
func (r *Runner) luaExecStart(L *glua.LState) int {
	p, err := r.startProc(L, L.Get(1), L.OptTable(2, nil))
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	ud := L.NewUserData()
	ud.Value = p
	L.SetMetatable(ud, L.GetTypeMetatable(procType))
	L.Push(ud)
	return 1
}

// startProc starts argv (a list of strings, or one string for a
// program without arguments) with opts: cwd, env (a table of
// variables to set over the daemon's), stdin (a string to give it, or
// true for a pipe to write to), stdout and stderr (functions taking
// each piece of output as it comes).
func (r *Runner) startProc(L *glua.LState, argvV glua.LValue, opts *glua.LTable) (*proc, error) {
	var argv []string
	switch v := argvV.(type) {
	case glua.LString:
		argv = []string{string(v)}
	case *glua.LTable:
		for i := 1; ; i++ {
			s, ok := v.RawGetInt(i).(glua.LString)
			if !ok {
				break
			}
			argv = append(argv, string(s))
		}
	}
	if len(argv) == 0 || argv[0] == "" {
		return nil, errors.New("argv is a list of strings, the program first")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	p := &proc{r: r, cmd: cmd, ids: r.IDs(), done: make(chan struct{})}
	if opts != nil {
		if cwd, ok := opts.RawGetString("cwd").(glua.LString); ok {
			cmd.Dir = string(cwd)
		}
		if env, ok := opts.RawGetString("env").(*glua.LTable); ok {
			cmd.Env = os.Environ()
			env.ForEach(func(k, v glua.LValue) {
				cmd.Env = append(cmd.Env, k.String()+"="+v.String())
			})
		}
		switch in := opts.RawGetString("stdin").(type) {
		case glua.LString:
			cmd.Stdin = strings.NewReader(string(in))
		case glua.LBool:
			if in {
				w, err := cmd.StdinPipe()
				if err != nil {
					return nil, err
				}
				p.stdin = w
			}
		}
		p.onStdout, _ = opts.RawGetString("stdout").(*glua.LFunction)
		p.onStderr, _ = opts.RawGetString("stderr").(*glua.LFunction)
	}
	cmd.Stdout = &streamWriter{p: p, stream: Stdout, callback: p.onStdout != nil, buf: &p.stdout}
	cmd.Stderr = &streamWriter{p: p, stream: Stderr, callback: p.onStderr != nil, buf: &p.stderr}
	// A child of the process that outlives it holding the pipes (a
	// killed cmd.exe's ping) ends the wait after this.
	cmd.WaitDelay = waitDelay
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.procs[p] = struct{}{}
	r.mu.Unlock()
	go func() {
		err := cmd.Wait()
		p.mu.Lock()
		p.exited = true
		p.status = cmd.ProcessState.ExitCode()
		if err != nil && p.status == 0 && !errors.Is(err, exec.ErrWaitDelay) {
			p.status = -1
		}
		p.mu.Unlock()
		r.mu.Lock()
		delete(r.procs, p)
		r.mu.Unlock()
		close(p.done)
	}()
	return p, nil
}

// waitDelay bounds how long a process's end waits for its pipes to
// close once it has exited.
const waitDelay = time.Second

// streamWriter takes one of the process's streams: to the callback,
// through the dispatcher, or into the buffer.
type streamWriter struct {
	p        *proc
	stream   Stream
	callback bool
	buf      *strings.Builder
}

func (w *streamWriter) Write(b []byte) (int, error) {
	if w.callback {
		w.p.r.enqueue(item{proc: w.p, stream: w.stream, data: string(b)})
		return len(b), nil
	}
	w.p.mu.Lock()
	defer w.p.mu.Unlock()
	return w.buf.Write(b)
}

// procOutput runs a stream's callback with a piece of output. The
// dispatcher's.
func (r *Runner) procOutput(p *proc, stream Stream, data string) {
	fn := p.onStdout
	if stream == Stderr {
		fn = p.onStderr
	}
	if fn == nil || !r.hold() {
		return
	}
	if r.start(p.ids, fn, glua.LString(data)) {
		r.unhold()
	}
}

// kill ends the process if it's running.
func (p *proc) kill() {
	p.mu.Lock()
	running := !p.exited
	p.mu.Unlock()
	if running {
		p.cmd.Process.Kill()
	}
}

// waitProc waits for p without the baton, up to timeout (none for as
// long as it takes), and says whether it ended.
func (r *Runner) waitProc(L *glua.LState, p *proc, timeout time.Duration) bool {
	t := r.current
	var limit <-chan time.Time
	if timeout > 0 {
		timer := time.NewTimer(timeout)
		defer timer.Stop()
		limit = timer.C
	}
	t.block(func(ctx context.Context) {
		select {
		case <-p.done:
		case <-limit:
		case <-ctx.Done():
		}
	})
	if t.ctx.Err() != nil {
		L.RaiseError("cancelled")
	}
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

// result is the process's end, as wait returns it: status (the exit
// code; a killed process's is the platform's, 1 on Windows, -1 where
// there is none), ok (status 0), and stdout and stderr as collected
// (empty where a callback took them).
func (p *proc) result(L *glua.LState) *glua.LTable {
	p.mu.Lock()
	defer p.mu.Unlock()
	t := L.NewTable()
	t.RawSetString("status", glua.LNumber(p.status))
	t.RawSetString("ok", glua.LBool(p.status == 0))
	t.RawSetString("stdout", glua.LString(p.stdout.String()))
	t.RawSetString("stderr", glua.LString(p.stderr.String()))
	return t
}

func checkProc(L *glua.LState) *proc {
	if p, ok := L.CheckUserData(1).Value.(*proc); ok {
		return p
	}
	L.ArgError(1, "a process handle")
	return nil
}

// procWait is h:wait([timeout]): the result once the process ends, or
// nil, "timeout".
func (r *Runner) procWait(L *glua.LState) int {
	p := checkProc(L)
	var timeout time.Duration
	if L.Get(2) != glua.LNil {
		timeout = seconds(L, 2)
	}
	if !r.waitProc(L, p, timeout) {
		return pushError(L, "timeout", 0)
	}
	L.Push(p.result(L))
	return 1
}

// procWrite is h:write(text): to its stdin (started with stdin =
// true); nil, err if it has none or the write failed. The baton is
// let go for the write: a full pipe waits for the process.
func (r *Runner) procWrite(L *glua.LState) int {
	p := checkProc(L)
	text := L.CheckString(2)
	if p.stdin == nil {
		return pushError(L, "the process wasn't started with stdin = true", 0)
	}
	var err error
	r.current.block(func(context.Context) { _, err = io.WriteString(p.stdin, text) })
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	L.Push(glua.LTrue)
	return 1
}

// procCloseStdin is h:close_stdin(): the process sees end of input.
func procCloseStdin(L *glua.LState) int {
	p := checkProc(L)
	if p.stdin != nil {
		p.stdin.Close()
	}
	return 0
}

// procKill is h:kill().
func procKill(L *glua.LState) int {
	checkProc(L).kill()
	return 0
}

// procRunning is h:running().
func procRunning(L *glua.LState) int {
	p := checkProc(L)
	p.mu.Lock()
	defer p.mu.Unlock()
	L.Push(glua.LBool(!p.exited))
	return 1
}
