package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/aldehir/slime/internal/config"
	"github.com/aldehir/slime/internal/lua"
	"github.com/aldehir/slime/internal/rpc"
)

// The config: init.lua (internal/config), evaluated when the server
// starts and on config.reload. What it set is what config.get answers
// and config.changed carries; its actions and function bindings run
// here as scripts do (action.invoke), in the config's own state, one at
// a time. A reload that fails keeps the last good config and reports
// why; one that succeeds swaps it in and closes the old once nothing
// runs in it.

// configHost is what the config's Lua reaches: the server, in process.
type configHost struct{ s *Server }

func (h *configHost) Call(method string, params json.RawMessage) (json.RawMessage, error) {
	result, rerr := h.s.Call(nil, method, params)
	if rerr != nil {
		return nil, rerr
	}
	return result, nil
}

func (h *configHost) Log(text string) { h.s.log.Info("config", "msg", text) }

// loadConfig evaluates the config file and makes it current, whether
// it loaded or not (the errors say), closing the one before once it's
// idle. The caller doesn't hold the lock.
func (s *Server) loadConfig() *rpc.ConfigDesc {
	cfg, errs := config.Load(&configHost{s}, s.configPath, func(stream lua.Stream, text string) {
		s.log.Info("config", string(stream), strings.TrimRight(text, "\n"))
	})
	s.mu.Lock()
	var old *config.Config
	s.configErrors = errs
	if cfg != nil {
		old, s.config = s.config, cfg
	}
	desc := s.configDescLocked()
	s.mu.Unlock()
	if old != nil {
		go old.Close()
	}
	for _, e := range errs {
		s.log.Warn("config", "path", s.configPath, "err", firstLine(e))
	}
	return desc
}

// configDescLocked describes the current config, with the errors of
// the last evaluation, which may have failed to replace it.
func (s *Server) configDescLocked() *rpc.ConfigDesc {
	d := rpc.ConfigDesc{Path: s.configPath, Settings: json.RawMessage("{}"), Keymap: []rpc.Binding{}, Actions: []rpc.ActionDesc{}}
	if s.config != nil {
		d = s.config.Desc()
	}
	d.Errors = s.configErrors
	return &d
}

// currentConfig is the config as it is now.
func (s *Server) currentConfig() *config.Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.config
}

// shellCommand is what a pane runs when its spec names nothing: the
// config's shell.command, or "" for the platform's default.
func (s *Server) shellCommand() string {
	if cfg := s.currentConfig(); cfg != nil {
		return cfg.Shell()
	}
	return ""
}

func (s *Server) configGet(_ *callCtx, _ rpc.Empty) (*rpc.ConfigDesc, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.configDescLocked(), nil
}

// configReload evaluates the file again and tells everyone subscribed
// how it went, whether or not it replaced the config.
func (s *Server) configReload(_ *callCtx, _ rpc.Empty) (*rpc.ConfigDesc, error) {
	desc := s.loadConfig()
	s.mu.Lock()
	s.emitLocked(rpc.EvConfigChanged, desc, nil)
	s.mu.Unlock()
	return desc, nil
}

// configCheck evaluates the file (or another) without keeping it.
func (s *Server) configCheck(_ *callCtx, p rpc.ConfigCheckParams) (*rpc.ConfigDesc, error) {
	path := p.Path
	if path == "" {
		path = s.configPath
	}
	cfg, errs := config.Load(&configHost{s}, path, func(lua.Stream, string) {})
	d := rpc.ConfigDesc{Path: path, Settings: json.RawMessage("{}"), Keymap: []rpc.Binding{}, Actions: []rpc.ActionDesc{}}
	if cfg != nil {
		d = cfg.Desc()
		cfg.Close()
	}
	d.Errors = errs
	return &d, nil
}

// actionInvoke runs an action or a function binding of the config as a
// script: it answers with the script's id, and the run's output and end
// follow as script.output and script.done.
func (s *Server) actionInvoke(cl *callCtx, p rpc.ActionInvokeParams) (*rpc.ScriptRunResult, error) {
	if p.Name == "" && p.Lua == 0 {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "action.invoke needs a name or a lua id")
	}
	if len(p.Args) > 0 {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(p.Args, &obj); err != nil {
			return nil, rpc.Errorf(rpc.CodeInvalidParams, "args must be a JSON object")
		}
	}
	name := p.Name
	if name == "" {
		name = fmt.Sprintf("binding %d", p.Lua)
	}
	inv := config.Invocation{Name: p.Name, Lua: p.Lua, Args: p.Args, Origin: p.Origin}
	s.mu.Lock()
	cfg := s.config
	if cfg == nil {
		s.mu.Unlock()
		return nil, rpc.Errorf(rpc.CodeNotFound, "no %s: no config is loaded", name)
	}
	if err := cfg.Check(inv); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	sc, err := s.startScriptLocked(cl, name, p.Pane, false)
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	inv.Pane = sc.pane
	go func() {
		result, err := cfg.Run(sc.ctx, inv, func(stream lua.Stream, text string) {
			s.scriptEmit(sc, rpc.EvScriptOutput, rpc.ScriptOutputParams{ID: sc.id, Stream: string(stream), Data: text})
		})
		if errors.Is(err, lua.ErrCancelled) || (err != nil && sc.ctx.Err() != nil) {
			err = lua.ErrCancelled
		}
		s.scriptEnded(sc, result, err)
	}()
	return &rpc.ScriptRunResult{ID: sc.id}, nil
}

// invokeFor is slime.invoke from a script: the action runs in the
// config's state for the script's pane, and the script waits for it.
func (s *Server) invokeFor(ctx context.Context, sc *script, name string, args json.RawMessage, out func(lua.Stream, string)) (json.RawMessage, error) {
	cfg := s.currentConfig()
	if cfg == nil {
		return nil, rpc.Errorf(rpc.CodeNotFound, "no action %q: no config is loaded", name)
	}
	return cfg.Run(ctx, config.Invocation{Name: name, Args: args, Pane: sc.pane, Origin: config.OriginScript}, out)
}
