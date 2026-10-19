// Package lua runs scripts against the daemon: gopher-lua (Lua 5.1,
// pure Go), one state per run. A script's `slime` table (api.go)
// reaches the daemon it runs in through Host: every namespaced method
// is a thin wrapper over the same method table the wire dispatches on,
// so a method that exists for one exists for all. Values cross as JSON
// (value.go).
//
// A run is a set of tasks (loop.go): the chunk itself, and each call
// of a hook, timer, or process callback, which runs on a goroutine of
// its own in a thread of the state. One task runs Lua at a time: the
// baton. A blocking call (slime.sleep, wait, exec, a process's wait)
// lets the baton go while it waits in Go, so the others run meanwhile,
// and Lua never runs concurrently with itself.
//
// The config file (internal/config) is one Runner that lives as long
// as the daemon, whose functions are called again for each action and
// key binding (Call); each `slime do` is another (Run) that ends when
// its chunk has returned and no hook or timer is live, when it's
// cancelled, or when it calls slime.stop.
package lua

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// Host is the daemon a script runs in.
type Host interface {
	// Call runs a control-plane method in process and returns its
	// result, or the error a Reply would carry (an *rpc.Error).
	Call(method string, params json.RawMessage) (json.RawMessage, error)
	// Output is what the script printed: a line on stdout (print) or
	// stderr, when the task printing has no Output of its own
	// (CallOptions.Out).
	Output(stream Stream, text string)
	// Log is slime.log: a line for the daemon's log.
	Log(text string)
	// Invoke is slime.invoke(name, args): runs an action the config
	// file defined and returns what it returned, or the error a Reply
	// would carry.
	Invoke(name string, args json.RawMessage) (json.RawMessage, error)
}

// Stream names an output stream.
type Stream string

const (
	Stdout Stream = "stdout"
	Stderr Stream = "stderr"
)

// Output takes what a task prints: print to stdout, slime.log to
// stderr.
type Output func(stream Stream, text string)

// Context is what a script runs for: its arguments, and the pane it
// was started from (zero for none), which names its tab and workspace
// too; they fill the ids its calls leave out. Persistent is the config
// file's: Run returns when the chunk does, leaving its hooks and timers
// live, and a hook that fails or stops ends only itself.
type Context struct {
	Args       json.RawMessage
	Pane       rpc.PaneID
	Persistent bool
}

// ErrCancelled ends a run that was cancelled.
var ErrCancelled = errors.New("cancelled")

// Limits on a state, so a runaway script can't take the daemon down
// with it. Each task's thread starts with registrySize slots and grows
// by registryGrowStep up to registryMaxSize.
const (
	callStackSize    = 256
	registrySize     = 1024 * 4
	registryGrowStep = 1024 * 4
	registryMaxSize  = 1024 * 1024
)

// Runner is one Lua state and the tasks that run in it.
type Runner struct {
	L    *glua.LState
	host Host
	// slime is the script's table; its ids are read when a call fills
	// them in, so a script can change them (they're swapped per task).
	slime *glua.LTable
	// stop is what slime.stop raises.
	stop      *glua.LUserData
	traceback glua.LValue
	// persistent is Context.Persistent; pane is Context.Pane, what Run's
	// chunk runs for.
	persistent bool
	pane       rpc.PaneID

	// The run's life: cancelled by Close, and in a script by stop, a
	// task's error, or Run's context ending.
	ctx    context.Context
	cancel context.CancelFunc
	// baton holds a token while a task runs Lua; current is that task
	// (nil while the dispatcher holds it).
	baton   chan struct{}
	current *task
	tasks   sync.WaitGroup

	// The loop's state (loop.go), under mu; cond is signalled when live
	// changes or the run ends.
	mu   sync.Mutex
	cond *sync.Cond
	// live counts what keeps a run going: tasks, hooks, and timers.
	live    int
	hooks   []*handle
	waiters []*waiter
	timers  map[*handle]struct{}
	procs   map[*proc]struct{}
	// items feed the dispatcher: events from the host, timers firing,
	// and process output. Events are dropped when it's full (dropped
	// counts them); the rest wait.
	items        chan item
	dropped      int
	dispatchDone chan struct{}
	// How the run ended, in a script: stopped by slime.stop (with
	// stopResult if it gave one), or failed by a task's error.
	stopped    bool
	stopResult glua.LValue
	failed     error
	closed     bool
}

// New makes a Runner for host with the libraries a script gets: base,
// package, table, string, math, coroutine, debug, and os without exit
// (the daemon is the process). io is left out: print is the output.
func New(host Host, ctx Context) *Runner {
	L := glua.NewState(glua.Options{
		CallStackSize:    callStackSize,
		RegistrySize:     registrySize,
		RegistryGrowStep: registryGrowStep,
		RegistryMaxSize:  registryMaxSize,
		SkipOpenLibs:     true,
	})
	for _, lib := range []struct {
		name string
		open glua.LGFunction
	}{
		{glua.LoadLibName, glua.OpenPackage},
		{glua.BaseLibName, glua.OpenBase},
		{glua.TabLibName, glua.OpenTable},
		{glua.StringLibName, glua.OpenString},
		{glua.MathLibName, glua.OpenMath},
		{glua.CoroutineLibName, glua.OpenCoroutine},
		{glua.DebugLibName, glua.OpenDebug},
		{glua.OsLibName, glua.OpenOs},
	} {
		L.Push(L.NewFunction(lib.open))
		L.Push(glua.LString(lib.name))
		L.Call(1, 0)
	}
	if os, ok := L.GetGlobal(glua.OsLibName).(*glua.LTable); ok {
		os.RawSetString("exit", glua.LNil)
	}
	r := &Runner{
		L:            L,
		host:         host,
		stop:         L.NewUserData(),
		persistent:   ctx.Persistent,
		pane:         ctx.Pane,
		baton:        make(chan struct{}, 1),
		timers:       map[*handle]struct{}{},
		procs:        map[*proc]struct{}{},
		items:        make(chan item, itemQueue),
		dispatchDone: make(chan struct{}),
	}
	r.cond = sync.NewCond(&r.mu)
	r.ctx, r.cancel = context.WithCancel(context.Background())
	context.AfterFunc(r.ctx, r.wake)
	if debug, ok := L.GetGlobal(glua.DebugLibName).(*glua.LTable); ok {
		r.traceback = debug.RawGetString("traceback")
	}
	r.install(ctx)
	go r.dispatch()
	return r
}

// Run compiles source as chunk name and runs it, returning what it
// returned (its first value, as JSON; nil for none) or why it stopped:
// a syntax or runtime error with its stack trace, or ErrCancelled once
// ctx is done. In a script, Run returns once the chunk has returned
// and no hook or timer is live, or slime.stop was called (its result
// wins), or a hook failed (its error); a persistent run returns when
// the chunk does.
func (r *Runner) Run(ctx context.Context, name, source string) (json.RawMessage, error) {
	fn, err := r.L.Load(strings.NewReader(source), name)
	if err != nil {
		return nil, errors.New(errorText(err))
	}
	if r.persistent {
		return r.Call(ctx, CallOptions{Pane: r.pane}, fn)
	}
	// The run's life is the chunk's context: cancelling it ends every
	// task, not just the chunk.
	defer context.AfterFunc(ctx, r.cancel)()
	result, err := r.Call(ctx, CallOptions{Pane: r.pane}, fn)
	if err != nil && !errors.Is(err, errStopped) {
		return nil, err
	}
	r.mu.Lock()
	for r.live > 0 && !r.stopped && r.failed == nil && r.ctx.Err() == nil {
		r.cond.Wait()
	}
	failed, stopped, done := r.failed, r.stopped, r.live == 0
	r.mu.Unlock()
	r.cancel()
	r.tasks.Wait()
	switch {
	case failed != nil:
		return nil, failed
	case stopped && r.stopResult != nil:
		return toJSON(r.stopResult)
	case stopped:
		return nil, nil
	case !done:
		return nil, ErrCancelled
	}
	return result, nil
}

// CallOptions say how Call runs a function: for Pane (none if zero),
// the ids its calls fill in, and with its output going to Out (nil:
// the host's Output).
type CallOptions struct {
	Pane rpc.PaneID
	Out  Output
}

// Call runs fn with args to its end as a task on the caller's
// goroutine, waiting for the baton: its first return value comes back
// as JSON (nil for none), or why it stopped. The state is left as it
// was, so the config file's functions are called again and again.
func (r *Runner) Call(ctx context.Context, opts CallOptions, fn glua.LValue, args ...glua.LValue) (json.RawMessage, error) {
	t := r.newTask(ctx, idsOf(opts.Pane), opts.Out)
	if t == nil {
		return nil, ErrCancelled
	}
	t.acquire()
	result, err := r.runTask(t, fn, args...)
	if errors.Is(err, errStopped) && !r.persistent {
		// Run reads the stop.
		return result, err
	}
	if errors.Is(err, errStopped) {
		err = nil
	}
	return result, err
}

// CallNested runs fn with args inside the running task: slime.invoke
// from the config's own functions. The caller holds the baton.
func (r *Runner) CallNested(fn glua.LValue, args ...glua.LValue) (json.RawMessage, error) {
	t := r.current
	if t == nil {
		return nil, errors.New("no task is running")
	}
	L := t.callL
	if L == nil {
		L = t.L
	}
	top := L.GetTop()
	defer L.SetTop(top)
	saved := t.stopResult
	t.stopResult = nil
	defer func() { t.stopResult = saved }()
	L.Push(fn)
	for _, a := range args {
		L.Push(a)
	}
	err := L.PCall(len(args), 1, L.NewFunction(r.onError))
	if t.ctx.Err() != nil {
		return nil, ErrCancelled
	}
	if err != nil {
		var apiErr *glua.ApiError
		if errors.As(err, &apiErr) && apiErr.Object == r.stop {
			if t.stopResult == nil {
				return nil, nil
			}
			return toJSON(t.stopResult)
		}
		return nil, errors.New(errorText(err))
	}
	if v := L.Get(-1); v != glua.LNil {
		return toJSON(v)
	}
	return nil, nil
}

// Close ends the run: every task is cancelled and waited for, timers
// are stopped, the processes it started are killed, and the state is
// freed.
func (r *Runner) Close() {
	// No new tasks from here (newTask), then the dispatcher can't start
	// any either, then every task there is ends.
	r.mu.Lock()
	r.closed = true
	r.mu.Unlock()
	r.cancel()
	<-r.dispatchDone
	r.tasks.Wait()
	r.mu.Lock()
	for h := range r.timers {
		h.timer.Stop()
	}
	procs := make([]*proc, 0, len(r.procs))
	for p := range r.procs {
		procs = append(procs, p)
	}
	r.mu.Unlock()
	for _, p := range procs {
		p.kill()
	}
	r.L.Close()
}

// Define sets slime.<name> to fn: what a host adds to the table beyond
// what every script gets (the config file's slime.config and the rest).
func (r *Runner) Define(name string, fn glua.LGFunction) {
	r.slime.RawSetString(name, r.L.NewFunction(fn))
}

// IDs is what a task runs for, as slime.workspace_id, tab_id, and
// pane_id hold it while it runs (a script may have changed them).
type IDs struct{ Workspace, Tab, Pane glua.LValue }

// IDs reads the ids as they are now. The caller holds the baton (it's
// a task, or in the host's Call).
func (r *Runner) IDs() IDs {
	return IDs{r.slime.RawGetString("workspace_id"), r.slime.RawGetString("tab_id"), r.slime.RawGetString("pane_id")}
}

func (r *Runner) setIDs(ids IDs) {
	r.slime.RawSetString("workspace_id", ids.Workspace)
	r.slime.RawSetString("tab_id", ids.Tab)
	r.slime.RawSetString("pane_id", ids.Pane)
}

// idsOf is what a run for pane sets the ids to: nothing if it's zero.
func idsOf(pane rpc.PaneID) IDs {
	if pane.IsZero() {
		return IDs{glua.LNil, glua.LNil, glua.LNil}
	}
	return IDs{glua.LNumber(pane.WS), glua.LString(pane.TabID().String()), glua.LString(pane.String())}
}

// IDsOf is idsOf for a host building a ctx table.
func IDsOf(pane rpc.PaneID) IDs { return idsOf(pane) }

// ToJSON and FromJSON cross values for a host, by value.go's rules.
func ToJSON(v glua.LValue) (json.RawMessage, error) { return toJSON(v) }

func FromJSON(L *glua.LState, b []byte) (glua.LValue, error) { return fromJSON(L, b) }

// onError is a task's error handler: it adds the stack trace to an
// error's message where the error happened, before the stack unwinds,
// and lets slime.stop through as it is.
func (r *Runner) onError(L *glua.LState) int {
	v := L.Get(1)
	if v == r.stop || r.traceback == glua.LNil {
		L.Push(v)
		return 1
	}
	L.Push(r.traceback)
	L.Push(v)
	L.Push(glua.LNumber(2))
	L.Call(2, 1)
	return 1
}

// errorText is a Lua error's message: gopher-lua's ApiError prints its
// value, with the stack trace the handler added.
func errorText(err error) string {
	var apiErr *glua.ApiError
	if errors.As(err, &apiErr) {
		return strings.TrimSpace(apiErr.Object.String())
	}
	return err.Error()
}

// output is where a task's print goes: its own Output, or the host's.
func (r *Runner) output(stream Stream, text string) {
	if t := r.current; t != nil && t.out != nil {
		t.out(stream, text)
		return
	}
	r.host.Output(stream, text)
}

// errStopped is how runTask reports slime.stop, for Run and Call to
// tell from a failure.
var errStopped = errors.New("stopped")

// panicError is a Go panic in a task, as its error.
func panicError(rec any) error { return fmt.Errorf("panic: %v", rec) }
