// Package lua runs scripts against the daemon: gopher-lua (Lua 5.1,
// pure Go), one state per run, driven by one goroutine. A script's
// `slime` table (api.go) reaches the daemon it runs in through Host:
// every namespaced method is a thin wrapper over the same method table
// the wire dispatches on, so a method that exists for one exists for
// all. Values cross as JSON (value.go).
//
// The config file (later) is one Runner that lives as long as the
// daemon; each `slime do` is another that ends when its chunk returns,
// when it's cancelled, or when it calls slime.stop.
package lua

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// Host is the daemon a script runs in.
type Host interface {
	// Call runs a control-plane method in process and returns its
	// result, or the error a Reply would carry (an *rpc.Error).
	Call(method string, params json.RawMessage) (json.RawMessage, error)
	// Output is what the script printed: a line on stdout (print) or
	// stderr.
	Output(stream Stream, text string)
	// Log is slime.log: a line for the daemon's log.
	Log(text string)
}

// Stream names an output stream.
type Stream string

const (
	Stdout Stream = "stdout"
	Stderr Stream = "stderr"
)

// Context is what a script runs for: its arguments, and the pane it
// was started from (zero for none), which names its tab and workspace
// too; they fill the ids its calls leave out.
type Context struct {
	Args json.RawMessage
	Pane rpc.PaneID
}

// ErrCancelled ends a run that was cancelled.
var ErrCancelled = errors.New("cancelled")

// Limits on a state, so a runaway script can't take the daemon down
// with it.
const (
	callStackSize   = 256
	registrySize    = 1024 * 64
	registryMaxSize = 1024 * 1024
)

// Runner is one Lua state and the goroutine that drives it.
type Runner struct {
	L    *glua.LState
	host Host
	// slime is the script's table; its ids are read when a call fills
	// them in, so a script can change them.
	slime *glua.LTable
	// stop is what slime.stop raises, and stopResult what it was given.
	stop       *glua.LUserData
	stopResult glua.LValue
	traceback  glua.LValue
}

// New makes a Runner for host with the libraries a script gets: base,
// package, table, string, math, coroutine, debug, and os without exit
// (the daemon is the process). io is left out: print is the output.
func New(host Host, ctx Context) *Runner {
	L := glua.NewState(glua.Options{
		CallStackSize:   callStackSize,
		RegistrySize:    registrySize,
		RegistryMaxSize: registryMaxSize,
		SkipOpenLibs:    true,
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
	r := &Runner{L: L, host: host, stop: L.NewUserData()}
	if debug, ok := L.GetGlobal(glua.DebugLibName).(*glua.LTable); ok {
		r.traceback = debug.RawGetString("traceback")
	}
	r.install(ctx)
	return r
}

// Run compiles source as chunk name and runs it to the end, returning
// what it returned (its first value, as JSON; nil for none) or why it
// stopped: a syntax or runtime error with its stack trace, or
// ErrCancelled once ctx is done. The state can't be used after.
func (r *Runner) Run(ctx context.Context, name, source string) (result json.RawMessage, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			err = fmt.Errorf("panic: %v", rec)
		}
	}()
	L := r.L
	L.SetContext(ctx)
	fn, err := L.Load(strings.NewReader(source), name)
	if err != nil {
		return nil, errors.New(errorText(err))
	}
	L.Push(fn)
	err = L.PCall(0, glua.MultRet, L.NewFunction(r.onError))
	if ctx.Err() != nil {
		return nil, ErrCancelled
	}
	if err != nil {
		var apiErr *glua.ApiError
		if errors.As(err, &apiErr) && apiErr.Object == r.stop {
			if r.stopResult == nil {
				return nil, nil
			}
			return toJSON(r.stopResult)
		}
		return nil, errors.New(errorText(err))
	}
	if L.GetTop() == 0 || L.Get(1) == glua.LNil {
		return nil, nil
	}
	return toJSON(L.Get(1))
}

// Close frees the state.
func (r *Runner) Close() { r.L.Close() }

// onError is the run's error handler: it adds the stack trace to an
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
