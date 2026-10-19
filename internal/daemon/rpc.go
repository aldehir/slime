package daemon

import (
	"encoding/json"
	"errors"

	"github.com/aldehir/slime/internal/rpc"
)

// The control plane: every method in internal/rpc is one entry in
// methods, and the wire's Call, the CLI (over the wire), and the Lua
// bindings (in process, later) all go through Server.Call, so a method
// that exists for one exists for all.

// callCtx is one call being served: who asked (c is nil for a caller
// in process, a script), and whether it's been answered. A handler
// whose result must reach the caller before anything else does (the
// structure an attach returns) replies under the server's lock with
// reply; the rest return their result and Call sends it.
type callCtx struct {
	s       *Server
	c       *conn
	id      uint32
	replied bool
	// result is what reply was given, for a caller in process, who
	// gets it when the handler returns.
	result any
}

// reply answers the call now, with result.
func (cl *callCtx) reply(result any) {
	if cl.replied {
		return
	}
	cl.replied = true
	if cl.c != nil {
		cl.c.sendForce(NoPane, reply(cl.id, result, nil))
	} else {
		cl.result = result
	}
}

// handler serves one method: its params as raw JSON, its result as
// anything that marshals.
type handler func(cl *callCtx, params json.RawMessage) (any, error)

// method adapts an op (a Server method over typed params and result)
// to a handler.
func method[P, R any](op func(s *Server, cl *callCtx, p P) (R, error)) handler {
	return func(cl *callCtx, raw json.RawMessage) (any, error) {
		var p P
		if len(raw) > 0 && string(raw) != "null" {
			if err := json.Unmarshal(raw, &p); err != nil {
				return nil, rpc.Errorf(rpc.CodeInvalidParams, "bad params: %v", err)
			}
		}
		return op(cl.s, cl, p)
	}
}

var methods = map[string]handler{
	rpc.WorkspaceList: method(func(s *Server, _ *callCtx, _ rpc.Empty) (*rpc.WorkspaceListResult, error) {
		return s.list(), nil
	}),
	rpc.WorkspaceNew:    method((*Server).workspaceNew),
	rpc.WorkspaceAttach: method((*Server).workspaceAttach),
	rpc.WorkspaceDetach: method((*Server).workspaceDetach),
	rpc.WorkspaceKill:   method((*Server).workspaceKill),
	rpc.WorkspaceRename: method((*Server).workspaceRename),
	rpc.WorkspaceResize: method((*Server).workspaceResize),
	rpc.WorkspaceFocus:  method((*Server).workspaceFocus),
	rpc.WorkspaceInfo:   method((*Server).workspaceInfo),
	rpc.TabNew:          method((*Server).tabNew),
	rpc.TabClose:        method((*Server).tabClose),
	rpc.TabRename:       method((*Server).tabRename),
	rpc.TabLayout:       method((*Server).tabLayout),
	rpc.TabInfo:         method((*Server).tabInfo),
	rpc.PaneSplit:       method((*Server).paneSplit),
	rpc.PaneMove:        method((*Server).paneMove),
	rpc.PaneKill:        method((*Server).paneKill),
	rpc.PaneWrite:       method((*Server).paneWrite),
	rpc.PaneText:        method((*Server).paneText),
	rpc.PaneInfo:        method((*Server).paneInfo),
	rpc.Subscribe:       method((*Server).subscribe),
	rpc.HostConnect:     method((*Server).hostConnect),
	rpc.HostAnswer:      method((*Server).hostAnswer),
	rpc.HostDisconnect:  method((*Server).hostDisconnect),
	rpc.HostList:        method((*Server).hostList),
	rpc.ScriptRun:       method((*Server).scriptRun),
	rpc.ScriptCancel:    method((*Server).scriptCancel),
	rpc.ScriptList:      method((*Server).scriptList),
	rpc.ConfigGet:       method((*Server).configGet),
	rpc.ConfigReload:    method((*Server).configReload),
	rpc.ConfigCheck:     method((*Server).configCheck),
	rpc.ActionInvoke:    method((*Server).actionInvoke),
	rpc.ClientQueue:     method((*Server).clientQueue),
}

// Methods lists the control plane's methods.
func Methods() []string {
	names := make([]string, 0, len(methods))
	for name := range methods {
		names = append(names, name)
	}
	return names
}

// call serves a Call from c: the reply goes back with the request's id.
func (s *Server) call(c *conn, req rpc.Request) {
	cl := &callCtx{s: s, c: c, id: req.ID}
	result, rerr := s.invoke(cl, req.Method, req.Params)
	if cl.replied {
		return
	}
	c.sendForce(NoPane, reply(req.ID, result, rerr))
}

// Call runs a method for a connection (nil for a caller in process)
// and returns its result, marshalled, or the error a Reply would carry.
func (s *Server) Call(c *conn, name string, params json.RawMessage) (json.RawMessage, *rpc.Error) {
	cl := &callCtx{s: s, c: c}
	result, rerr := s.invoke(cl, name, params)
	if rerr != nil {
		return nil, rerr
	}
	b, err := json.Marshal(result)
	if err != nil {
		return nil, rpc.Errorf(rpc.CodeInternal, "encoding the result: %v", err)
	}
	return b, nil
}

func (s *Server) invoke(cl *callCtx, name string, params json.RawMessage) (any, *rpc.Error) {
	h := methods[name]
	if h == nil {
		return nil, rpc.Errorf(rpc.CodeMethodNotFound, "no method %q", name)
	}
	result, err := h(cl, params)
	if err != nil {
		return nil, toRPCError(err)
	}
	if cl.replied && cl.c == nil {
		result = cl.result
	}
	if result == nil {
		result = rpc.Empty{}
	}
	return result, nil
}

// toRPCError maps an op's error to the code a Reply carries.
func toRPCError(err error) *rpc.Error {
	var rerr *rpc.Error
	if errors.As(err, &rerr) {
		return rerr
	}
	code := rpc.CodeFailed
	if errors.Is(err, errNoWorkspace) || errors.Is(err, errNoTab) || errors.Is(err, errNoPane) || errors.Is(err, errNoHost) || errors.Is(err, errNoScript) {
		code = rpc.CodeNotFound
	}
	return &rpc.Error{Code: code, Message: err.Error()}
}

// reply builds a Reply to call id: result, or rerr.
func reply(id uint32, result any, rerr *rpc.Error) *Reply {
	r := &Reply{Response: rpc.Response{JSONRPC: "2.0", ID: id}}
	if rerr != nil {
		r.Response.Error = rerr
		return r
	}
	if result == nil {
		result = rpc.Empty{}
	}
	b, err := json.Marshal(result)
	if err != nil {
		r.Response.Error = rpc.Errorf(rpc.CodeInternal, "encoding the result: %v", err)
		return r
	}
	r.Response.Result = b
	return r
}

// notify builds a Notify for event name. params that don't marshal
// make an event with none, which is logged where it's sent.
func notify(name string, params any) *Notify {
	n := &Notify{Notification: rpc.Notification{JSONRPC: "2.0", Method: name}}
	if b, err := json.Marshal(params); err == nil {
		n.Notification.Params = b
	}
	return n
}

// emitLocked sends event name to the viewers of ws, if any, and to
// every connection subscribed to it, each once, except skip (which
// made the change, or already has it); and to the Lua running in
// process (scripts and the config), whose hooks pick what they want.
// Under the server's lock.
func (s *Server) emitLocked(name string, params any, ws *workspace, skip ...*conn) {
	n := notify(name, params)
	for _, sc := range s.scripts {
		if sc.runner != nil {
			sc.runner.Deliver(name, n.Notification.Params)
		}
	}
	if s.config != nil {
		s.config.Deliver(name, n.Notification.Params)
	}
	skipped := func(c *conn) bool {
		for _, x := range skip {
			if x == c {
				return true
			}
		}
		return false
	}
	if ws != nil {
		for c := range ws.viewers {
			if !skipped(c) {
				c.sendForce(NoPane, n)
			}
		}
	}
	for c := range s.conns {
		if skipped(c) || (ws != nil && ws.viewers[c] != nil) || !c.subscribedLocked(name) {
			continue
		}
		c.sendForce(NoPane, n)
	}
}

// subscribe replaces c's subscription: the events it gets beyond its
// own workspaces'.
func (s *Server) subscribe(cl *callCtx, p rpc.SubscribeParams) (rpc.Empty, error) {
	if cl.c == nil {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidRequest, "subscribe needs a connection")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cl.c.subs = p.Events
	return rpc.Empty{}, nil
}

// subscribedLocked says whether c asked for event name: by name, by
// group ("host.*"), or for everything ("*").
func (c *conn) subscribedLocked(name string) bool {
	for _, sub := range c.subs {
		if rpc.MatchEvent(sub, name) {
			return true
		}
	}
	return false
}

// clientQueue asks a workspace's viewers to perform a window action:
// client.action goes to them (and to client.* subscribers).
func (s *Server) clientQueue(_ *callCtx, p rpc.ClientQueueParams) (rpc.Empty, error) {
	if p.Name == "" {
		return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "client.queue needs an action name")
	}
	if len(p.Args) > 0 {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(p.Args, &obj); err != nil {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "args must be a JSON object")
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.Workspace]
	if ws == nil {
		return rpc.Empty{}, errNoWorkspace
	}
	s.emitLocked(rpc.EvClientAction, rpc.ClientActionParams{Workspace: ws.id, Name: p.Name, Args: p.Args}, ws)
	return rpc.Empty{}, nil
}
