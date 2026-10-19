package lua

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/slime/internal/rpc"
)

// The loop: tasks and what starts them. A task is one run of a
// function in a thread of the state, on a goroutine of its own; the
// baton (Runner.baton) lets one run Lua at a time. The dispatcher
// goroutine takes items (events the host delivers, timers firing,
// process output) in order and starts a task for each hook or callback
// they reach, handing it the baton and waiting until it has finished
// or blocked before taking the next, so hooks start in the order their
// events came. A task that blocks (sleep, wait, a process's wait) lets
// the baton go and takes it back after.

// itemQueue bounds items: events past it are dropped (they're the
// only ones a host sends without waiting).
const itemQueue = 256

// task is one run of a function.
type task struct {
	r      *Runner
	L      *glua.LState
	ctx    context.Context
	cancel context.CancelFunc
	// unhook forgets the run's end as a reason to cancel, once the task
	// has ended on its own.
	unhook func() bool
	// out takes what it prints, if it has one of its own.
	out Output
	// ids are slime.workspace_id and the rest while it runs, kept here
	// while it doesn't.
	ids IDs
	// cur is the coroutine the task was in when it let the baton go.
	cur *glua.LState
	// callL is the state slime.invoke was called from, for a nested
	// call to run in.
	callL *glua.LState
	// stopResult is what slime.stop was given.
	stopResult glua.LValue
	// parked is closed the first time the task lets the baton go, or
	// ends: the dispatcher waits for it after handing a task the baton.
	parked     chan struct{}
	parkedOnce sync.Once
}

// newTask makes a task under ctx for ids, counting it live; nil once
// the run is closing. Under mu, so Close sees every task there is
// before it waits for them.
func (r *Runner) newTask(ctx context.Context, ids IDs, out Output) *task {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	t := &task{r: r, ids: ids, out: out, parked: make(chan struct{})}
	t.L, _ = r.L.NewThread()
	t.cur = t.L
	// The task ends with its own context, or with the run.
	t.ctx, t.cancel = context.WithCancel(ctx)
	t.unhook = context.AfterFunc(r.ctx, t.cancel)
	t.L.SetContext(t.ctx)
	r.tasks.Add(1)
	r.live++
	return t
}

// acquire takes the baton for t.
func (t *task) acquire() {
	t.r.baton <- struct{}{}
	t.enter()
}

// enter makes t the task running: the caller holds the baton for it.
func (t *task) enter() {
	t.r.current = t
	t.r.setIDs(t.ids)
	t.L.G.CurrentThread = t.cur
}

// release lets the baton go: t is blocking, or done.
func (t *task) release() {
	t.ids = t.r.IDs()
	t.r.setIDs(IDs{glua.LNil, glua.LNil, glua.LNil})
	t.cur = t.L.G.CurrentThread
	t.r.current = nil
	<-t.r.baton
	t.parkedOnce.Do(func() { close(t.parked) })
}

// block runs wait without the baton, taking it back after. wait gets
// the task's context, which ends when the run does.
func (t *task) block(wait func(ctx context.Context)) {
	t.release()
	wait(t.ctx)
	t.acquire()
}

// runTask runs fn with args in t, whose baton the caller holds, to its
// end, and reports how it went: the result as JSON, or the error,
// errStopped for slime.stop (the result is then what it was given).
func (r *Runner) runTask(t *task, fn glua.LValue, args ...glua.LValue) (result json.RawMessage, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			err = panicError(rec)
		}
		t.release()
		t.cancel()
		t.unhook()
		r.taskEnded(t, err)
		r.tasks.Done()
	}()
	L := t.L
	L.Push(fn)
	for _, a := range args {
		L.Push(a)
	}
	err = L.PCall(len(args), 1, L.NewFunction(r.onError))
	if t.ctx.Err() != nil {
		return nil, ErrCancelled
	}
	if err != nil {
		var apiErr *glua.ApiError
		if errors.As(err, &apiErr) && apiErr.Object == r.stop {
			if t.stopResult == nil {
				return nil, errStopped
			}
			result, err = toJSON(t.stopResult)
			if err != nil {
				return nil, err
			}
			return result, errStopped
		}
		return nil, errors.New(errorText(err))
	}
	if v := L.Get(-1); v != glua.LNil {
		return toJSON(v)
	}
	return nil, nil
}

// taskEnded takes t out of the live count and, in a script, ends the
// run if t stopped or failed. A persistent run's failed hooks are
// logged, and errors of the functions it was asked to call are the
// caller's.
func (r *Runner) taskEnded(t *task, err error) {
	r.mu.Lock()
	r.live--
	if !r.persistent {
		switch {
		case errors.Is(err, errStopped):
			r.stopped = true
			if t.stopResult != nil {
				r.stopResult = t.stopResult
			}
			r.cancel()
		case err != nil && !errors.Is(err, ErrCancelled) && r.failed == nil:
			r.failed = err
			r.cancel()
		}
	}
	r.cond.Broadcast()
	r.mu.Unlock()
}

// wake has Run look again: the run's context ended.
func (r *Runner) wake() {
	r.mu.Lock()
	r.cond.Broadcast()
	r.mu.Unlock()
}

// unlive takes a hook or timer out of the live count.
func (r *Runner) unliveLocked() {
	r.live--
	r.cond.Broadcast()
}

// handle is a hook (slime.on) or a timer (after, every), as Lua holds
// it: cancel ends it, active says whether it's still to run.
type handle struct {
	r *Runner
	// fn is called with (ctx, ev) for a hook, (ctx) for a timer, in a
	// task for ids: what the registering task ran for.
	fn  *glua.LFunction
	ids IDs
	// For a hook: the events it's for (a pattern as subscribe takes).
	event string
	// For a timer: the delay, whether it repeats, and the Go timer.
	delay  time.Duration
	every  bool
	timer  *time.Timer
	active bool
}

// waiter is one slime.wait: the event it waits for, by pattern and
// filter, and the result once it came.
type waiter struct {
	event  string
	filter *glua.LTable
	done   chan struct{}
	result glua.LValue
}

// item is one thing for the dispatcher: an event (name and params), a
// timer that fired, or a process's output.
type item struct {
	name   string
	params json.RawMessage
	timer  *handle
	proc   *proc
	stream Stream
	data   string
}

// Deliver gives the run an event, which the dispatcher passes to the
// hooks and waits for it. It never blocks: the host calls it under its
// lock; when the queue is full the event is dropped and counted.
func (r *Runner) Deliver(name string, params json.RawMessage) {
	r.mu.Lock()
	wanted := !r.closed && r.interestedLocked(name)
	r.mu.Unlock()
	if !wanted {
		return
	}
	select {
	case r.items <- item{name: name, params: params}:
	default:
		r.mu.Lock()
		r.dropped++
		r.mu.Unlock()
	}
}

// interestedLocked says whether a hook or waiter is for event name.
func (r *Runner) interestedLocked(name string) bool {
	for _, h := range r.hooks {
		if h.active && rpc.MatchEvent(h.event, name) {
			return true
		}
	}
	for _, w := range r.waiters {
		if rpc.MatchEvent(w.event, name) {
			return true
		}
	}
	return false
}

// dispatch takes items in order until the run ends.
func (r *Runner) dispatch() {
	defer close(r.dispatchDone)
	for {
		select {
		case <-r.ctx.Done():
			return
		case it := <-r.items:
			switch {
			case it.timer != nil:
				r.fire(it.timer)
			case it.proc != nil:
				r.procOutput(it.proc, it.stream, it.data)
			default:
				r.event(it.name, it.params)
			}
		}
	}
}

// hold takes the baton for the dispatcher, which runs no Lua of its
// own but builds the values a task gets; it reports whether the run is
// still going.
func (r *Runner) hold() bool {
	select {
	case r.baton <- struct{}{}:
		return true
	case <-r.ctx.Done():
		return false
	}
}

func (r *Runner) unhold() { <-r.baton }

// start runs fn with args in a new task for ids, handing it the
// baton the dispatcher holds, and waits until it has finished or
// blocked, then takes the baton back; false if the run ended first
// and it couldn't. The caller holds the baton.
func (r *Runner) start(ids IDs, fn *glua.LFunction, args ...glua.LValue) bool {
	t := r.newTask(r.ctx, ids, nil)
	if t == nil {
		return false
	}
	t.enter()
	go func() {
		_, err := r.runTask(t, fn, args...)
		if r.persistent && err != nil && !errors.Is(err, errStopped) && !errors.Is(err, ErrCancelled) {
			r.host.Log("handler failed: " + err.Error())
		}
	}()
	<-t.parked
	return r.hold()
}

// event passes an event to the waiters whose filter it matches, then
// starts a task for each hook it reaches, in the order they were
// registered.
func (r *Runner) event(name string, params json.RawMessage) {
	if !r.hold() {
		return
	}
	holding := true
	defer func() {
		if holding {
			r.unhold()
		}
	}()
	r.mu.Lock()
	dropped := r.dropped
	r.dropped = 0
	var hooks []*handle
	for _, h := range r.hooks {
		if h.active && rpc.MatchEvent(h.event, name) {
			hooks = append(hooks, h)
		}
	}
	var waiters []*waiter
	for _, w := range r.waiters {
		if rpc.MatchEvent(w.event, name) {
			waiters = append(waiters, w)
		}
	}
	r.mu.Unlock()
	if dropped > 0 {
		r.host.Log("event queue full: " + strconv.Itoa(dropped) + " events dropped")
	}
	ids := eventIDs(name, params)
	for _, w := range waiters {
		ev := eventTable(r.L, params)
		if !filterMatches(w.filter, ids, ev) {
			continue
		}
		r.mu.Lock()
		for i, x := range r.waiters {
			if x == w {
				r.waiters = append(r.waiters[:i], r.waiters[i+1:]...)
				break
			}
		}
		r.mu.Unlock()
		w.result = ev
		close(w.done)
	}
	for _, h := range hooks {
		r.mu.Lock()
		active := h.active
		r.mu.Unlock()
		if !active {
			continue
		}
		if !r.start(h.ids, h.fn, r.ctxTable(ids, "event", name), eventTable(r.L, params)) {
			holding = false
			return
		}
	}
}

// fire runs a timer's function, once for after, and again after each
// delay for every until it's cancelled.
func (r *Runner) fire(h *handle) {
	if !r.hold() {
		return
	}
	r.mu.Lock()
	if !h.active {
		r.mu.Unlock()
		r.unhold()
		return
	}
	if h.every {
		h.timer = time.AfterFunc(h.delay, func() { r.enqueue(item{timer: h}) })
	} else {
		h.active = false
		delete(r.timers, h)
		r.unliveLocked()
	}
	r.mu.Unlock()
	if r.start(h.ids, h.fn, r.ctxTable(h.ids, "timer", "")) {
		r.unhold()
	}
}

// enqueue queues an item from a goroutine of the run's own (a timer,
// a process), waiting for room unless the run ends.
func (r *Runner) enqueue(it item) {
	select {
	case r.items <- it:
	case <-r.ctx.Done():
	}
}

// ctxTable is a hook's or timer's ctx: what it runs for, and why.
func (r *Runner) ctxTable(ids IDs, origin, event string) *glua.LTable {
	t := r.L.NewTable()
	t.RawSetString("workspace_id", ids.Workspace)
	t.RawSetString("tab_id", ids.Tab)
	t.RawSetString("pane_id", ids.Pane)
	t.RawSetString("origin", glua.LString(origin))
	if event != "" {
		t.RawSetString("event", glua.LString(event))
	}
	return t
}

// eventTable is an event's params as the Lua table a handler gets.
func eventTable(L *glua.LState, params json.RawMessage) glua.LValue {
	if len(params) > 0 {
		if v, err := fromJSON(L, params); err == nil && v != glua.LNil {
			return v
		}
	}
	return L.NewTable()
}

// eventIDs is what an event is about, from its id by its group: a
// pane's names its tab and workspace too, a tab's its workspace. Other
// groups' ids (a script's, a host's) name nothing here.
func eventIDs(name string, params json.RawMessage) IDs {
	ids := IDs{glua.LNil, glua.LNil, glua.LNil}
	group, _, _ := strings.Cut(name, ".")
	var p struct {
		ID json.RawMessage `json:"id"`
	}
	if json.Unmarshal(params, &p) != nil || len(p.ID) == 0 {
		return ids
	}
	switch group {
	case "pane":
		var id rpc.PaneID
		if json.Unmarshal(p.ID, &id) == nil && !id.IsZero() {
			ids = idsOf(id)
		}
	case "tab":
		var id rpc.TabID
		if json.Unmarshal(p.ID, &id) == nil && !id.IsZero() {
			ids.Workspace, ids.Tab = glua.LNumber(id.WS), glua.LString(id.String())
		}
	case "workspace":
		var id uint32
		if json.Unmarshal(p.ID, &id) == nil && id != 0 {
			ids.Workspace = glua.LNumber(id)
		}
	}
	return ids
}

// filterMatches says whether ev is what a wait's filter asks for:
// each key of the filter equals the event's field of that name, except
// workspace_id, tab_id, and pane_id, which are what the event is
// about (eventIDs). No filter matches everything.
func filterMatches(filter *glua.LTable, ids IDs, ev glua.LValue) bool {
	if filter == nil {
		return true
	}
	evt, _ := ev.(*glua.LTable)
	ok := true
	filter.ForEach(func(k, want glua.LValue) {
		if !ok {
			return
		}
		var got glua.LValue = glua.LNil
		switch k {
		case glua.LString("workspace_id"):
			got = ids.Workspace
		case glua.LString("tab_id"):
			got = ids.Tab
		case glua.LString("pane_id"):
			got = ids.Pane
		default:
			if evt != nil {
				got = evt.RawGet(k)
			}
		}
		if got != want {
			ok = false
		}
	})
	return ok
}

// The Lua side: slime.on, wait, sleep, after, every, and the handles.

// luaOn is slime.on(event, fn): fn(ctx, ev) runs for each event the
// pattern names, in a task of its own, until the handle is cancelled.
func (r *Runner) luaOn(L *glua.LState) int {
	event := L.CheckString(1)
	fn := L.CheckFunction(2)
	if event == "" {
		L.ArgError(1, "an event name is needed")
	}
	h := &handle{r: r, fn: fn, ids: r.IDs(), event: event, active: true}
	r.mu.Lock()
	r.hooks = append(r.hooks, h)
	r.live++
	r.mu.Unlock()
	L.Push(r.newHandle(L, h))
	return 1
}

// luaWait is slime.wait(event, filter, timeout): the next event the
// pattern names whose fields match filter (a table, or nil), or nil,
// "timeout" after timeout seconds (none waits until the run ends).
func (r *Runner) luaWait(L *glua.LState) int {
	event := L.CheckString(1)
	if event == "" {
		L.ArgError(1, "an event name is needed")
	}
	filter := L.OptTable(2, nil)
	var timeout <-chan time.Time
	if L.Get(3) != glua.LNil {
		timer := time.NewTimer(seconds(L, 3))
		defer timer.Stop()
		timeout = timer.C
	}
	w := &waiter{event: event, filter: filter, done: make(chan struct{})}
	r.mu.Lock()
	r.waiters = append(r.waiters, w)
	r.mu.Unlock()
	t := r.current
	t.block(func(ctx context.Context) {
		select {
		case <-w.done:
		case <-timeout:
		case <-ctx.Done():
		}
	})
	r.mu.Lock()
	for i, x := range r.waiters {
		if x == w {
			r.waiters = append(r.waiters[:i], r.waiters[i+1:]...)
			break
		}
	}
	r.mu.Unlock()
	if t.ctx.Err() != nil {
		L.RaiseError("cancelled")
		return 0
	}
	if w.result == nil {
		return pushError(L, "timeout", 0)
	}
	L.Push(w.result)
	return 1
}

// luaSleep is slime.sleep(seconds): the task waits; the others run.
func (r *Runner) luaSleep(L *glua.LState) int {
	d := seconds(L, 1)
	t := r.current
	t.block(func(ctx context.Context) {
		timer := time.NewTimer(d)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
		}
	})
	if t.ctx.Err() != nil {
		L.RaiseError("cancelled")
	}
	return 0
}

// luaAfter is slime.after(seconds, fn): fn(ctx) runs once, after the
// delay, unless the handle is cancelled first. luaEvery is
// slime.every(seconds, fn): again after each delay, until cancelled.
func (r *Runner) luaAfter(L *glua.LState) int { return r.timer(L, false) }

func (r *Runner) luaEvery(L *glua.LState) int { return r.timer(L, true) }

func (r *Runner) timer(L *glua.LState, every bool) int {
	d := seconds(L, 1)
	fn := L.CheckFunction(2)
	h := &handle{r: r, fn: fn, ids: r.IDs(), delay: d, every: every, active: true}
	r.mu.Lock()
	r.timers[h] = struct{}{}
	r.live++
	h.timer = time.AfterFunc(d, func() { r.enqueue(item{timer: h}) })
	r.mu.Unlock()
	L.Push(r.newHandle(L, h))
	return 1
}

// seconds is argument i as a duration: a non-negative number of
// seconds.
func seconds(L *glua.LState, i int) time.Duration {
	n := L.CheckNumber(i)
	if n < 0 || n != n {
		L.ArgError(i, "seconds can't be negative")
	}
	return time.Duration(float64(n) * float64(time.Second))
}

// newHandle wraps h for Lua: h:cancel() and h:active().
func (r *Runner) newHandle(L *glua.LState, h *handle) *glua.LUserData {
	ud := L.NewUserData()
	ud.Value = h
	L.SetMetatable(ud, L.GetTypeMetatable(handleType))
	return ud
}

const handleType = "slime.handle"

// installHandles registers the handle type.
func (r *Runner) installHandles() {
	L := r.L
	mt := L.NewTypeMetatable(handleType)
	mt.RawSetString("__index", L.SetFuncs(L.NewTable(), map[string]glua.LGFunction{
		"cancel": handleCancel,
		"active": handleActive,
	}))
}

func checkHandle(L *glua.LState) *handle {
	if h, ok := L.CheckUserData(1).Value.(*handle); ok {
		return h
	}
	L.ArgError(1, "a hook or timer handle")
	return nil
}

// handleCancel ends a hook or timer: it won't run again, and no longer
// keeps the run alive.
func handleCancel(L *glua.LState) int {
	h := checkHandle(L)
	r := h.r
	r.mu.Lock()
	defer r.mu.Unlock()
	if !h.active {
		return 0
	}
	h.active = false
	if h.timer != nil {
		h.timer.Stop()
		delete(r.timers, h)
	} else {
		for i, x := range r.hooks {
			if x == h {
				r.hooks = append(r.hooks[:i], r.hooks[i+1:]...)
				break
			}
		}
	}
	r.unliveLocked()
	return 0
}

func handleActive(L *glua.LState) int {
	h := checkHandle(L)
	h.r.mu.Lock()
	defer h.r.mu.Unlock()
	L.Push(glua.LBool(h.active))
	return 1
}
