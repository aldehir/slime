package daemon

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/aldehir/slime/internal/lua"
	"github.com/aldehir/slime/internal/rpc"
)

// Scripts: Lua the daemon runs against itself (internal/lua). Each is
// a state of its own on a goroutine of its own; its calls go through
// Server.Call in process, as a caller with no connection, so they take
// the server's lock as wire handlers do and never hold it while Lua
// runs. What it prints and how it ended go to the connection that
// started it, and to anyone subscribed to script.*.

// script is one run.
type script struct {
	id      uint32
	name    string
	pane    PaneID
	started time.Time
	// owner started it and gets its output; nil once it has hung up.
	// Unless detached, the owner hanging up cancels the script.
	owner    *conn
	detached bool
	cancel   context.CancelFunc
}

func (sc *script) desc() rpc.ScriptDesc {
	return rpc.ScriptDesc{ID: sc.id, Name: sc.name, Pane: sc.pane, Started: sc.started.UnixMilli(), Detached: sc.detached}
}

var errNoScript = errors.New("no such script")

// scriptRun starts a script and answers with its id; script.done
// follows when it ends.
func (s *Server) scriptRun(cl *callCtx, p rpc.ScriptRunParams) (*rpc.ScriptRunResult, error) {
	if p.Source == "" {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "script.run needs a source")
	}
	if len(p.Args) > 0 {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(p.Args, &obj); err != nil {
			return nil, rpc.Errorf(rpc.CodeInvalidParams, "args must be a JSON object")
		}
	}
	name := p.Name
	if name == "" {
		name = "script"
	}
	ctx, cancel := context.WithCancel(context.Background())
	lctx := lua.Context{Args: p.Args}

	s.mu.Lock()
	if !p.Pane.IsZero() {
		// The pane as it's named now, if it moved.
		pane := s.paneLocked(p.Pane)
		if pane == nil || pane.tab == nil {
			s.mu.Unlock()
			cancel()
			return nil, errNoPane
		}
		lctx.Pane = pane.id
	}
	s.nextScript++
	sc := &script{id: s.nextScript, name: name, pane: lctx.Pane, started: time.Now(), owner: cl.c, detached: p.Detach || cl.c == nil, cancel: cancel}
	s.scripts[sc.id] = sc
	s.checkIdleLocked()
	s.mu.Unlock()
	s.log.Info("script started", "script", sc.id, "name", sc.name, "pane", sc.pane)

	go s.runScript(ctx, sc, lctx, p.Source)
	return &rpc.ScriptRunResult{ID: sc.id}, nil
}

// runScript drives a script to its end and reports it.
func (s *Server) runScript(ctx context.Context, sc *script, lctx lua.Context, source string) {
	r := lua.New(&scriptHost{s: s, sc: sc}, lctx)
	result, err := r.Run(ctx, sc.name, source)
	r.Close()
	sc.cancel()

	s.mu.Lock()
	delete(s.scripts, sc.id)
	s.checkIdleLocked()
	s.mu.Unlock()

	done := rpc.ScriptDoneParams{ID: sc.id, OK: err == nil, Result: result}
	if err != nil {
		done.Error = err.Error()
		s.log.Info("script failed", "script", sc.id, "name", sc.name, "err", firstLine(done.Error))
	} else {
		s.log.Info("script done", "script", sc.id, "name", sc.name)
	}
	s.scriptEmit(sc, rpc.EvScriptDone, done)
}

// scriptEmit sends a script's event to its owner and to the
// subscribers, each once.
func (s *Server) scriptEmit(sc *script, name string, params any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sc.owner != nil {
		sc.owner.sendForce(NoPane, notify(name, params))
	}
	s.emitLocked(name, params, nil, sc.owner)
}

// scriptClientGoneLocked is called when c hangs up: its scripts lose
// their owner, and those it didn't detach are cancelled.
func (s *Server) scriptClientGoneLocked(c *conn) {
	for _, sc := range s.scripts {
		if sc.owner != c {
			continue
		}
		sc.owner = nil
		if !sc.detached {
			sc.cancel()
		}
	}
}

// scriptCancel ends a script; script.done says it was cancelled.
func (s *Server) scriptCancel(_ *callCtx, p rpc.ScriptParams) (rpc.Empty, error) {
	s.mu.Lock()
	sc := s.scripts[p.ID]
	s.mu.Unlock()
	if sc == nil {
		return rpc.Empty{}, errNoScript
	}
	sc.cancel()
	return rpc.Empty{}, nil
}

func (s *Server) scriptList(_ *callCtx, _ rpc.Empty) (*rpc.ScriptListResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &rpc.ScriptListResult{Scripts: []rpc.ScriptDesc{}}
	for _, sc := range s.scripts {
		out.Scripts = append(out.Scripts, sc.desc())
	}
	slices.SortFunc(out.Scripts, func(a, b rpc.ScriptDesc) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}

// scriptHost is what a script's bindings reach: the server, in
// process.
type scriptHost struct {
	s  *Server
	sc *script
}

func (h *scriptHost) Call(method string, params json.RawMessage) (json.RawMessage, error) {
	result, rerr := h.s.Call(nil, method, params)
	if rerr != nil {
		return nil, rerr
	}
	return result, nil
}

func (h *scriptHost) Output(stream lua.Stream, text string) {
	h.s.scriptEmit(h.sc, rpc.EvScriptOutput, rpc.ScriptOutputParams{ID: h.sc.id, Stream: string(stream), Data: text})
}

// Log is slime.log: the daemon's log, and the script's stderr.
func (h *scriptHost) Log(text string) {
	h.s.log.Info("script", "script", h.sc.id, "name", h.sc.name, "msg", text)
	h.Output(lua.Stderr, text+"\n")
}

func firstLine(s string) string {
	for i, c := range s {
		if c == '\n' {
			return s[:i]
		}
	}
	return s
}
