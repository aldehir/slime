// Package rpc is the control plane's vocabulary: the JSON-RPC 2.0
// objects that ride in the daemon's Call, Reply, and Notify envelopes,
// and the params and results of every method and notification. The
// ops live with the daemon (internal/daemon); clients in Go use these
// types, and clients in other languages read them as the definition.
//
// Every method is one entry in the daemon's table: a name here, a
// params struct, a result struct, and the op. A client that omits an id
// a method needs gets an error; the daemon fills nothing from context
// yet.
package rpc

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Request is a Call's payload. ID is the caller's; a Reply echoes it.
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      uint32          `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Response is a Reply's payload: Result or Error, never both.
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      uint32          `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Notification is a Notify's payload: an event, with no id and no
// reply.
type Notification struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Error is a failed call's answer.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

// Error codes: JSON-RPC's, and the daemon's own from 1000.
const (
	CodeParse          = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternal       = -32603
	// CodeNotFound: no such workspace, tab, pane, or host.
	CodeNotFound = 1000
	// CodeUnsupported: this daemon can't (hosts on a non-Windows daemon).
	CodeUnsupported = 1001
	// CodeFailed: the op ran and didn't work (a child didn't start).
	CodeFailed = 1002
)

// Errorf makes an Error with code.
func Errorf(code int, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Methods, as the wire names them. The daemon's table has one op per
// name.
const (
	WorkspaceList   = "workspace.list"
	WorkspaceNew    = "workspace.new"
	WorkspaceAttach = "workspace.attach"
	WorkspaceDetach = "workspace.detach"
	WorkspaceKill   = "workspace.kill"
	WorkspaceRename = "workspace.rename"
	WorkspaceResize = "workspace.resize"
	WorkspaceFocus  = "workspace.focus"
	WorkspaceInfo   = "workspace.info"
	TabNew          = "tab.new"
	TabClose        = "tab.close"
	TabRename       = "tab.rename"
	TabLayout       = "tab.layout"
	TabInfo         = "tab.info"
	PaneSplit       = "pane.split"
	PaneMove        = "pane.move"
	PaneKill        = "pane.kill"
	PaneWrite       = "pane.write"
	PaneText        = "pane.text"
	PaneInfo        = "pane.info"
	Subscribe       = "subscribe"
	HostConnect     = "host.connect"
	HostAnswer      = "host.answer"
	HostDisconnect  = "host.disconnect"
	HostList        = "host.list"
	ScriptRun       = "script.run"
	ScriptCancel    = "script.cancel"
	ScriptList      = "script.list"
	ConfigGet       = "config.get"
	ConfigReload    = "config.reload"
	ConfigCheck     = "config.check"
	ActionInvoke    = "action.invoke"
	ClientQueue     = "client.queue"
)

// Notifications. A workspace's viewers get their workspace's without
// subscribing; everyone else subscribes to what it wants.
const (
	EvWorkspaceCreated      = "workspace.created"
	EvWorkspaceDestroyed    = "workspace.destroyed"
	EvWorkspaceChanged      = "workspace.changed"
	EvWorkspaceDetached     = "workspace.detached"
	EvWorkspaceOpen         = "workspace.open"
	EvWorkspaceViewerJoined = "workspace.viewer_joined"
	EvWorkspaceViewerLeft   = "workspace.viewer_left"
	EvTabCreated            = "tab.created"
	EvTabClosed             = "tab.closed"
	EvTabRenamed            = "tab.renamed"
	EvTabSelected           = "tab.selected"
	EvPaneCreated           = "pane.created"
	EvPaneMoved             = "pane.moved"
	EvPaneAttached          = "pane.attached"
	EvPaneExited            = "pane.exited"
	EvPaneTitle             = "pane.title"
	EvPanePwd               = "pane.pwd"
	EvPaneBell              = "pane.bell"
	EvPaneStatus            = "pane.status"
	EvHostChanged           = "host.changed"
	EvHostPrompt            = "host.prompt"
	EvScriptOutput          = "script.output"
	EvScriptDone            = "script.done"
	EvConfigChanged         = "config.changed"
	EvClientAction          = "client.action"
)

// MatchEvent says whether event name is one pattern asks for: the name
// itself, its group ("host.*"), or everything ("*"). Subscriptions and
// a script's hooks are lists of patterns.
func MatchEvent(pattern, name string) bool {
	switch {
	case pattern == "*", pattern == name:
		return true
	case strings.HasSuffix(pattern, ".*") && strings.HasPrefix(name, pattern[:len(pattern)-1]):
		return true
	}
	return false
}

// Size is a terminal's grid and, if known, its cell size in pixels.
type Size struct {
	Cols  uint16 `json:"cols"`
	Rows  uint16 `json:"rows"`
	CellW uint32 `json:"cell_width,omitempty"`
	CellH uint32 `json:"cell_height,omitempty"`
}

// Area is a tab's space in pixels, which a layout's shares divide, and
// the cell size for panes that haven't reported their own.
type Area struct {
	Width  uint32 `json:"width"`
	Height uint32 `json:"height"`
	CellW  uint32 `json:"cell_width"`
	CellH  uint32 `json:"cell_height"`
}

// Whole is 100% of a split, in basis points.
const Whole = 10000

// Axis is the way a split lays out its children: "row" left to right,
// sharing the width; "column" top to bottom, sharing the height.
type Axis uint8

const (
	Row    Axis = 1
	Column Axis = 2
)

var axisNames = map[Axis]string{Row: "row", Column: "column"}

func (a Axis) String() string {
	if s, ok := axisNames[a]; ok {
		return s
	}
	return fmt.Sprintf("axis %d", uint8(a))
}

func (a Axis) MarshalText() ([]byte, error) {
	s, ok := axisNames[a]
	if !ok {
		return nil, fmt.Errorf("rpc: bad axis %d", uint8(a))
	}
	return []byte(s), nil
}

func (a *Axis) UnmarshalText(b []byte) error {
	for k, v := range axisNames {
		if v == string(b) {
			*a = k
			return nil
		}
	}
	return fmt.Errorf("rpc: axis is row or column, not %q", b)
}

// Direction is where a split puts the new pane beside the old.
type Direction uint8

const (
	Right Direction = 1
	Down  Direction = 2
	Left  Direction = 3
	Up    Direction = 4
)

var directionNames = map[Direction]string{Right: "right", Down: "down", Left: "left", Up: "up"}

func (d Direction) String() string {
	if s, ok := directionNames[d]; ok {
		return s
	}
	return fmt.Sprintf("direction %d", uint8(d))
}

func (d Direction) MarshalText() ([]byte, error) {
	s, ok := directionNames[d]
	if !ok {
		return nil, fmt.Errorf("rpc: bad direction %d", uint8(d))
	}
	return []byte(s), nil
}

func (d *Direction) UnmarshalText(b []byte) error {
	for k, v := range directionNames {
		if v == string(b) {
			*d = k
			return nil
		}
	}
	return fmt.Errorf("rpc: direction is right, down, left, or up, not %q", b)
}

// Axis is the axis a split in direction d lies along.
func (d Direction) Axis() Axis {
	if d == Right || d == Left {
		return Row
	}
	return Column
}

// Node is a tab's layout tree: a pane (Pane set) or a split whose
// children each have a share of it in basis points, summing to Whole.
// On the wire a pane is {"pane": "1.2.3"} and a split {"split":
// {"axis": "row", "children": [{"share": 5000, "node": ...}, ...]}}:
// the shape a tagged union takes in Zig's std.json.
type Node struct {
	Pane     PaneID
	Axis     Axis
	Children []Child
}

type Child struct {
	Share uint16 `json:"share"`
	Node  *Node  `json:"node"`
}

// MaxDepth bounds a tree's nesting, on the wire and in the daemon.
const MaxDepth = 32

var ErrTooDeep = errors.New("rpc: layout nested too deep")

func (n *Node) IsLeaf() bool { return !n.Pane.IsZero() }

// Panes lists the tree's panes in order: left to right, top to bottom.
func (n *Node) Panes() []PaneID {
	if n == nil {
		return nil
	}
	if n.IsLeaf() {
		return []PaneID{n.Pane}
	}
	var ids []PaneID
	for _, c := range n.Children {
		ids = append(ids, c.Node.Panes()...)
	}
	return ids
}

// Clone copies the tree, so a copy can go out while the original changes.
func (n *Node) Clone() *Node {
	if n == nil {
		return nil
	}
	c := &Node{Pane: n.Pane, Axis: n.Axis}
	for _, ch := range n.Children {
		c.Children = append(c.Children, Child{ch.Share, ch.Node.Clone()})
	}
	return c
}

type splitJSON struct {
	Axis     Axis    `json:"axis"`
	Children []Child `json:"children"`
}

type nodeJSON struct {
	Pane  *PaneID    `json:"pane,omitempty"`
	Split *splitJSON `json:"split,omitempty"`
}

func (n *Node) MarshalJSON() ([]byte, error) {
	if n.IsLeaf() {
		return json.Marshal(nodeJSON{Pane: &n.Pane})
	}
	return json.Marshal(nodeJSON{Split: &splitJSON{Axis: n.Axis, Children: n.Children}})
}

func (n *Node) UnmarshalJSON(b []byte) error {
	return n.unmarshal(b, 0)
}

func (n *Node) unmarshal(b []byte, depth int) error {
	if depth > MaxDepth {
		return ErrTooDeep
	}
	var raw struct {
		Pane  *PaneID `json:"pane"`
		Split *struct {
			Axis     Axis `json:"axis"`
			Children []struct {
				Share uint16          `json:"share"`
				Node  json.RawMessage `json:"node"`
			} `json:"children"`
		} `json:"split"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	switch {
	case raw.Pane != nil && raw.Split == nil && !raw.Pane.IsZero():
		*n = Node{Pane: *raw.Pane}
	case raw.Split != nil && raw.Pane == nil:
		*n = Node{Axis: raw.Split.Axis}
		for _, c := range raw.Split.Children {
			child := &Node{}
			if err := child.unmarshal(c.Node, depth+1); err != nil {
				return err
			}
			n.Children = append(n.Children, Child{Share: c.Share, Node: child})
		}
	default:
		return errors.New("rpc: a layout node is a pane or a split")
	}
	return nil
}

// Workspace is a workspace's structure: what workspace.new and
// workspace.attach return, and what workspace.changed carries. Focus
// is the daemon's, shared by every viewer: ActiveTab is the tab shown,
// and each tab has the pane that gets input and the one zoomed.
type Workspace struct {
	ID        uint32 `json:"id"`
	Name      string `json:"name"`
	ActiveTab TabID  `json:"active_tab,omitzero"`
	Tabs      []Tab  `json:"tabs"`
}

// Tab is one tab's layout and focus.
type Tab struct {
	ID   TabID  `json:"id"`
	Name string `json:"name,omitempty"` // empty unless renamed
	Tree *Node  `json:"tree"`
	// Focus is the pane that gets input; Zoomed the pane filling the
	// tab, or none.
	Focus  PaneID `json:"focus,omitzero"`
	Zoomed PaneID `json:"zoomed,omitzero"`
}

// Layout is a tab to build: a tree whose leaves say what to run,
// which tab.new and workspace.new take. On the wire a leaf is
// {"pane": {"command": ..., "cwd": ..., "env": {...}}} and a split
// {"split": {"axis": "row", "children": [{"share": 5000, "node": ...},
// ...]}}, as Node is. Shares that are all zero divide a split equally.
type Layout struct {
	Pane     *PaneSpec
	Axis     Axis
	Children []LayoutChild
}

type LayoutChild struct {
	Share uint16  `json:"share,omitempty"`
	Node  *Layout `json:"node"`
}

// PaneSpec says what a new pane runs: Command (CreateProcessW syntax
// on Windows; empty for the default shell) in Cwd, with Env added to
// the daemon's environment.
type PaneSpec struct {
	Command string            `json:"command,omitempty"`
	Cwd     string            `json:"cwd,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

func (l *Layout) IsLeaf() bool { return l.Pane != nil }

// Leaves lists the layout's panes in order: left to right, top to
// bottom.
func (l *Layout) Leaves() []*PaneSpec {
	if l == nil {
		return nil
	}
	if l.IsLeaf() {
		return []*PaneSpec{l.Pane}
	}
	var out []*PaneSpec
	for _, c := range l.Children {
		out = append(out, c.Node.Leaves()...)
	}
	return out
}

// Validate checks a layout: splits have at least two children, and
// shares either all zero or summing to Whole. It fills in equal shares
// for the zeros.
func (l *Layout) Validate() error {
	if l == nil {
		return errors.New("rpc: empty layout")
	}
	if l.IsLeaf() {
		return nil
	}
	if l.Axis != Row && l.Axis != Column {
		return fmt.Errorf("rpc: bad split axis %d", uint8(l.Axis))
	}
	if len(l.Children) < 2 {
		return errors.New("rpc: a split with fewer than two children")
	}
	var sum int
	for _, c := range l.Children {
		if c.Node == nil {
			return errors.New("rpc: an empty split child")
		}
		sum += int(c.Share)
		if err := c.Node.Validate(); err != nil {
			return err
		}
	}
	switch {
	case sum == 0:
		n := len(l.Children)
		left := Whole
		for i := range l.Children {
			share := Whole / n
			if i == n-1 {
				share = left
			}
			l.Children[i].Share = uint16(share)
			left -= share
		}
	case sum != Whole:
		return fmt.Errorf("rpc: split shares sum to %d, not %d", sum, Whole)
	}
	return nil
}

type layoutSplitJSON struct {
	Axis     Axis          `json:"axis"`
	Children []LayoutChild `json:"children"`
}

type layoutJSON struct {
	Pane  *PaneSpec        `json:"pane,omitempty"`
	Split *layoutSplitJSON `json:"split,omitempty"`
}

func (l *Layout) MarshalJSON() ([]byte, error) {
	if l.IsLeaf() {
		return json.Marshal(layoutJSON{Pane: l.Pane})
	}
	return json.Marshal(layoutJSON{Split: &layoutSplitJSON{Axis: l.Axis, Children: l.Children}})
}

func (l *Layout) UnmarshalJSON(b []byte) error {
	return l.unmarshal(b, 0)
}

func (l *Layout) unmarshal(b []byte, depth int) error {
	if depth > MaxDepth {
		return ErrTooDeep
	}
	var raw struct {
		Pane  *PaneSpec `json:"pane"`
		Split *struct {
			Axis     Axis `json:"axis"`
			Children []struct {
				Share uint16          `json:"share"`
				Node  json.RawMessage `json:"node"`
			} `json:"children"`
		} `json:"split"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	switch {
	case raw.Pane != nil && raw.Split == nil:
		*l = Layout{Pane: raw.Pane}
	case raw.Split != nil && raw.Pane == nil:
		*l = Layout{Axis: raw.Split.Axis}
		for _, c := range raw.Split.Children {
			child := &Layout{}
			if err := child.unmarshal(c.Node, depth+1); err != nil {
				return err
			}
			l.Children = append(l.Children, LayoutChild{Share: c.Share, Node: child})
		}
	default:
		return errors.New("rpc: a layout node is a pane or a split")
	}
	return nil
}

// WorkspaceListResult answers workspace.list.
type WorkspaceListResult struct {
	Workspaces []WorkspaceDesc `json:"workspaces"`
	Panes      []PaneDesc      `json:"panes"`
}

// WorkspaceDesc is a workspace as workspace.list and workspace.info
// describe it.
type WorkspaceDesc struct {
	ID   uint32 `json:"id"`
	Name string `json:"name"`
	// Attached: it has viewers, Viewers of them.
	Attached bool `json:"attached"`
	Viewers  int  `json:"viewers,omitempty"`
	// DetachedAt is when its last viewer left, in unix milliseconds;
	// zero while attached or if it never was.
	DetachedAt int64 `json:"detached_at,omitempty"`
	ActiveTab  TabID `json:"active_tab,omitzero"`
	Tabs       []Tab `json:"tabs"`
}

// PaneDesc is a pane as workspace.list and pane.info describe it. ID
// names its tab and workspace too.
type PaneDesc struct {
	ID      PaneID `json:"id"`
	Command string `json:"command"`
	Title   string `json:"title,omitempty"`
	Pwd     string `json:"pwd,omitempty"`
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
	Created int64  `json:"created"` // unix milliseconds
	PID     uint32 `json:"pid"`
	// Status is what the pane's programs report doing (OSC 7501),
	// oldest update first.
	Status []StatusRecord `json:"status,omitempty"`
}

// StatusRecord is one program status record: its id (empty for the
// program itself), state (vt.StatusState: idle, working, done, blocked,
// or error), and progress (0 to 100, or -1 for none).
type StatusRecord struct {
	ID       string `json:"id"`
	State    uint8  `json:"state"`
	Progress int8   `json:"progress"`
}

// Created answers tab.new, pane.split, and pane.move with the pane it
// made or moved, which names its tab: the tab's first pane for a
// tab.new of several, and a moved pane's new id.
type Created struct {
	Pane PaneID `json:"pane"`
}

// WorkspaceNewParams: the name ("default" if empty) and the tabs to
// start it with, one layout each; a connection calling it becomes a
// viewer. With no tabs, a connection that then hangs up loses the
// empty workspace. Attach names a workspace whose viewers are to open
// the new one too: once its tabs are up, they get workspace.open, and
// a window attaches it beside what it shows. A script run from a pane
// fills it with the pane's workspace.
type WorkspaceNewParams struct {
	Name   string    `json:"name,omitempty"`
	Tabs   []*Layout `json:"tabs,omitempty"`
	Attach uint32    `json:"attach,omitempty"`
}

// WorkspaceAttachParams adds the caller to workspace ID's viewers,
// beside any it has. Area is what the window gives a tab, which the
// daemon sizes its panes to; zero leaves them as they are. The viewer
// gets pane.attached per pane, then the Workspace result: panes come
// before the structure that refers to them. Each pane's frames follow,
// starting with a full one. Where viewers differ in size a pane takes
// the smallest's, as tmux does.
type WorkspaceAttachParams struct {
	ID   uint32 `json:"id"`
	Area Area   `json:"area,omitempty"`
}

// WorkspaceFocusParams moves a workspace's focus, for every viewer:
// Tab becomes the active tab, Pane the focus of its tab (which is Tab
// if that's given, else the pane's own), and Zoomed, if given, the
// pane zoomed in that tab ("" for none). The other viewers get
// workspace.changed; the caller doesn't, having made the change.
type WorkspaceFocusParams struct {
	Tab    TabID   `json:"tab,omitzero"`
	Pane   PaneID  `json:"pane,omitzero"`
	Zoomed *PaneID `json:"zoomed,omitempty"`
}

// WorkspaceParams names a workspace: detach, kill, info.
type WorkspaceParams struct {
	ID uint32 `json:"id"`
}

type WorkspaceRenameParams struct {
	ID   uint32 `json:"id"`
	Name string `json:"name"`
}

// WorkspaceResizeParams tells the daemon the caller's tab area, for
// estimating pane sizes in its tabs. The window still resizes each pane
// itself.
type WorkspaceResizeParams struct {
	ID   uint32 `json:"id"`
	Area Area   `json:"area"`
}

// TabNewParams adds a tab: Layout's panes, or one running Command
// (CreateProcessW syntax on Windows; empty for the default shell) in
// Cwd with Env, sized Size if given. Name names the tab. The
// workspace's viewers get pane.attached and workspace.changed, then
// the caller gets Created; a viewer's own call focuses the new tab.
type TabNewParams struct {
	Workspace uint32            `json:"workspace"`
	Name      string            `json:"name,omitempty"`
	Layout    *Layout           `json:"layout,omitempty"`
	Command   string            `json:"command,omitempty"`
	Cwd       string            `json:"cwd,omitempty"`
	Env       map[string]string `json:"env,omitempty"`
	Size      Size              `json:"size,omitempty"`
}

// TabParams names a tab: close, info.
type TabParams struct {
	ID TabID `json:"id"`
}

type TabRenameParams struct {
	ID   TabID  `json:"id"`
	Name string `json:"name"`
}

// TabLayoutParams replaces a tab's tree, which must hold the same panes:
// a divider was dragged. The viewer gets workspace.changed back.
type TabLayoutParams struct {
	ID   TabID `json:"id"`
	Tree *Node `json:"tree"`
}

// PaneSplitParams starts a pane beside Pane, on side Direction, taking
// Share basis points of its space (half if zero). Replies as tab.new
// does; a viewer's own call focuses the new pane.
type PaneSplitParams struct {
	Pane      PaneID            `json:"pane"`
	Direction Direction         `json:"direction"`
	Share     uint16            `json:"share,omitempty"`
	Command   string            `json:"command,omitempty"`
	Cwd       string            `json:"cwd,omitempty"`
	Env       map[string]string `json:"env,omitempty"`
}

// PaneMoveParams moves Pane to tab Tab of its workspace, along its
// whole Side (right if zero), taking half of it; with no Tab, into a
// new tab after its own. A tab left empty closes. The pane takes its
// new tab's next number: Created names it, and the old id forwards to
// it for as long as the pane lives, so a shell's SLIME_PANE still
// finds it. The viewers see the old id detach and the new attach
// (pane.attached with moved_from); a viewer's own call focuses the
// pane.
type PaneMoveParams struct {
	Pane PaneID    `json:"pane"`
	Tab  TabID     `json:"tab,omitzero"`
	Side Direction `json:"side,omitempty"`
}

// PaneParams names a pane: kill, info.
type PaneParams struct {
	ID PaneID `json:"id"`
}

// PaneWriteParams writes Text to the pane's child as typed.
type PaneWriteParams struct {
	ID   PaneID `json:"id"`
	Text string `json:"text"`
}

// PaneTextParams asks for the text of a pane's screen and scrollback
// without taking it: plain, or with VT the sequences that redraw it.
type PaneTextParams struct {
	ID PaneID `json:"id"`
	VT bool   `json:"vt,omitempty"`
}

type PaneTextResult struct {
	Text string `json:"text"`
}

// SubscribeParams says which notifications this connection wants
// beyond its own workspaces': names, "group.*" for a group, or "*" for
// all. It replaces the last subscription.
type SubscribeParams struct {
	Events []string `json:"events"`
}

// Empty is the result of a method that has nothing to say.
type Empty struct{}

// WorkspaceCreatedParams: workspace.created.
type WorkspaceCreatedParams struct {
	ID   uint32 `json:"id"`
	Name string `json:"name"`
}

// WorkspaceOpenParams: workspace.open, to the viewers of the workspace
// a workspace.new named in attach: workspace ID is for them to attach
// as well.
type WorkspaceOpenParams struct {
	ID   uint32 `json:"id"`
	Name string `json:"name"`
}

// WorkspaceDestroyedParams: workspace.destroyed.
type WorkspaceDestroyedParams struct {
	ID uint32 `json:"id"`
}

// WorkspaceDetachedParams ends a viewer's hold on a workspace it didn't
// let go of: killed.
type WorkspaceDetachedParams struct {
	ID     uint32 `json:"id"`
	Reason string `json:"reason"`
}

// WorkspaceViewerParams: workspace.viewer_joined and
// workspace.viewer_left, with how many viewers the workspace has now.
type WorkspaceViewerParams struct {
	ID      uint32 `json:"id"`
	Viewers int    `json:"viewers"`
}

// TabEventParams: tab.created, tab.closed, tab.renamed, and
// tab.selected (the workspace's active tab changed).
type TabEventParams struct {
	ID   TabID  `json:"id"`
	Name string `json:"name,omitempty"`
}

// PaneCreatedParams: pane.created.
type PaneCreatedParams struct {
	ID PaneID `json:"id"`
}

// PaneMovedParams: pane.moved, to another tab, under a new id.
type PaneMovedParams struct {
	ID   PaneID `json:"id"`
	From PaneID `json:"from"`
}

// PaneAttachedParams starts a pane's attachment to the viewer it goes
// to: its frames follow, the first a full one, with a Notice for its
// title and pwd if it has them. ID places it, for a viewer of several
// workspaces. MovedFrom is the id it had, if it just moved tabs: the
// viewer's attachment under that id is over.
type PaneAttachedParams struct {
	ID        PaneID `json:"id"`
	MovedFrom PaneID `json:"moved_from,omitzero"`
	// Command is what the pane runs, for a client that didn't start it.
	Command string         `json:"command"`
	Status  []StatusRecord `json:"status,omitempty"`
}

// PaneExitedParams says the pane's child exited. The viewer gets
// workspace.changed after, with the pane gone from its tab.
type PaneExitedParams struct {
	ID     PaneID `json:"id"`
	Status uint32 `json:"status"`
}

// PaneTitleParams: pane.title, the pane's title as the program set it
// (OSC 0/2).
type PaneTitleParams struct {
	ID    PaneID `json:"id"`
	Title string `json:"title"`
}

// PanePwdParams: pane.pwd, the pane's working directory as the shell
// reported it (OSC 7; a file:// URI as sent).
type PanePwdParams struct {
	ID  PaneID `json:"id"`
	Pwd string `json:"pwd"`
}

// PaneBellParams: pane.bell, the program rang the bell.
type PaneBellParams struct {
	ID PaneID `json:"id"`
}

// PaneStatusParams: pane.status, a program's status report changed
// (OSC 7501): Status is every record now, oldest update first, as
// PaneDesc carries them.
type PaneStatusParams struct {
	ID     PaneID         `json:"id"`
	Status []StatusRecord `json:"status"`
}

// ClientQueueParams: client.queue asks the viewers of Workspace to
// perform the window action Name (copy_to_clipboard, increase_font_size,
// ...) with Args, a JSON object or nothing: the daemon sends them
// client.action, and every window showing the workspace performs it.
// So an action that changes the workspace is refused: it has a method
// that does it once, for the pane named (DaemonActions). Lua's
// slime.client.queue fills Workspace from what the script runs for.
type ClientQueueParams struct {
	Workspace uint32          `json:"workspace"`
	Name      string          `json:"name"`
	Args      json.RawMessage `json:"args,omitempty"`
}

// DaemonActions are the window actions client.queue refuses, each with
// the method that does the same for one pane, once: a window's own
// would run in every viewer.
var DaemonActions = map[string]string{
	"new_tab":           TabNew,
	"new_split":         PaneSplit,
	"close_surface":     PaneKill,
	"next_tab":          WorkspaceFocus,
	"previous_tab":      WorkspaceFocus,
	"goto_split":        WorkspaceFocus,
	"toggle_split_zoom": WorkspaceFocus,
	"resize_split":      TabLayout,
	"equalize_splits":   TabLayout,
}

// ClientActionParams: client.action, to a workspace's viewers.
type ClientActionParams struct {
	Workspace uint32          `json:"workspace"`
	Name      string          `json:"name"`
	Args      json.RawMessage `json:"args,omitempty"`
}

// Hosts: SSH hosts the daemon connects to, on Windows. A host's id is
// stable for its destination while the daemon lives, so a window can
// group by it across reconnects.

// HostState is a host's state as the daemon reports it.
type HostState string

const (
	// HostConnecting: logging in or installing slime.
	HostConnecting HostState = "connecting"
	HostConnected  HostState = "connected"
	// HostFailed: logging in or installing didn't work.
	HostFailed HostState = "failed"
	// HostLost: the connection dropped.
	HostLost HostState = "lost"
	// HostGone: disconnected on request.
	HostGone HostState = "gone"
)

// Host describes a host: host.connect's result, host.list's items, and
// host.changed. Text is a status line while connecting (the server's,
// or ours: "installing slime"), or why it failed, was lost, or went.
// Proxy is the SOCKS5 proxy into the host's network while it's
// connected ("socks5://127.0.0.1:<port>"; names resolve on the host),
// unless the config's host.proxy is false.
type Host struct {
	ID    uint32    `json:"id"`
	Dest  string    `json:"dest"`
	State HostState `json:"state"`
	Text  string    `json:"text,omitempty"`
	Proxy string    `json:"proxy,omitempty"`
}

// HostConnectParams logs in to Dest (ssh://[user@]host[:port],
// [user@]host, or a Host alias), puts slime there, and answers with the
// host as it is then; host.changed follows as it goes. A host already
// connected or connecting answers at once with its state. Prompts while
// logging in go to the caller only, as host.prompt; if it hangs up,
// logging in is cancelled.
type HostConnectParams struct {
	Dest string `json:"dest"`
}

// NormalizeDest is a destination as the daemon names hosts: with its
// ssh:// scheme, so one spelled bare is the same host.
func NormalizeDest(dest string) string {
	if strings.Contains(dest, "://") {
		return dest
	}
	return "ssh://" + dest
}

// HostParams names a host: disconnect.
type HostParams struct {
	Host uint32 `json:"host"`
}

// HostListResult answers host.list.
type HostListResult struct {
	Hosts []Host `json:"hosts"`
}

// Choice is the button a prompt was answered with.
type Choice string

const (
	// ChoiceCancel gives up: on logging in for most prompts, on the
	// host for host key prompts.
	ChoiceCancel Choice = "cancel"
	// ChoiceAccept submits the answers, or trusts the host key.
	ChoiceAccept Choice = "accept"
	// ChoiceSkip moves on without this key (passphrase prompts).
	ChoiceSkip Choice = "skip"
)

// HostAnswerParams replies to the last host.prompt for Host: the button
// pressed, and one answer per question. A cancel with no prompt waiting
// gives up on logging in.
type HostAnswerParams struct {
	Host    uint32   `json:"host"`
	Choice  Choice   `json:"choice"`
	Answers []string `json:"answers,omitempty"`
}

// PromptKind says what a host.prompt asks.
type PromptKind string

const (
	PromptPassword    PromptKind = "password"
	PromptPassphrase  PromptKind = "passphrase"
	PromptInteractive PromptKind = "interactive"
	PromptUnknownHost PromptKind = "unknown_host"
	PromptChangedHost PromptKind = "changed_host"
)

// HostPromptParams asks the client whose host.connect is logging in to
// Host something: a password, a passphrase, a keyboard-interactive
// round, or whether to trust a host key (no questions; accept trusts
// it). Text is the body, Detail is shown in a monospace box (a key's
// path, fingerprints), and Error says why the last answer didn't work.
// The reply is host.answer.
type HostPromptParams struct {
	Host      uint32     `json:"host"`
	Kind      PromptKind `json:"kind"`
	Title     string     `json:"title,omitempty"`
	Text      string     `json:"text,omitempty"`
	Detail    string     `json:"detail,omitempty"`
	Error     string     `json:"error,omitempty"`
	Questions []Question `json:"questions,omitempty"`
}

// Question is one field to fill in. Label may run over several lines,
// as keyboard-interactive prompts do; its last line names the field.
type Question struct {
	Label string `json:"label"`
	Echo  bool   `json:"echo,omitempty"`
}

// Scripts: Lua the daemon runs (internal/lua), each in a state of its
// own, against its own method table in process.

// ScriptRunParams starts a script: Source, compiled as chunk Name (a
// file name, for error messages), with Args as slime.args (a JSON
// object). Pane is the pane it runs for, filled into slime.pane_id and,
// through it, tab_id and workspace_id; none for none. The caller gets
// script.output and script.done for it without subscribing, and a
// caller that hangs up before it's done cancels it unless Detach is set.
// The reply comes as soon as it's started; the result comes with
// script.done.
type ScriptRunParams struct {
	Source string          `json:"source"`
	Name   string          `json:"name,omitempty"`
	Args   json.RawMessage `json:"args,omitempty"`
	Pane   PaneID          `json:"pane,omitzero"`
	Detach bool            `json:"detach,omitempty"`
}

// ScriptRunResult answers script.run with the script's id.
type ScriptRunResult struct {
	ID uint32 `json:"id"`
}

// ScriptParams names a script: cancel.
type ScriptParams struct {
	ID uint32 `json:"id"`
}

// ScriptListResult answers script.list.
type ScriptListResult struct {
	Scripts []ScriptDesc `json:"scripts"`
}

// ScriptDesc is a running script.
type ScriptDesc struct {
	ID      uint32 `json:"id"`
	Name    string `json:"name,omitempty"`
	Pane    PaneID `json:"pane,omitzero"`
	Started int64  `json:"started"` // unix milliseconds
	// Detached: it outlives the connection that started it.
	Detached bool `json:"detached,omitempty"`
}

// ScriptOutputParams: script.output, what a script printed. Stream is
// "stdout" (print) or "stderr" (slime.log).
type ScriptOutputParams struct {
	ID     uint32 `json:"id"`
	Stream string `json:"stream"`
	Data   string `json:"data"`
}

// ScriptDoneParams: script.done. OK with Result (what the chunk
// returned, as JSON; null for nothing) when it ran to the end or called
// slime.stop; otherwise Error says what went wrong, with the Lua stack
// trace, or that it was cancelled.
type ScriptDoneParams struct {
	ID     uint32          `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// Config: the daemon's init.lua (internal/config), evaluated at start
// and on config.reload. What it set is described to clients, which
// take the settings they understand and the key bindings; its actions
// run in the daemon.

// ConfigDesc answers config.get and config.check, and config.changed
// carries it after a reload. Path is the file (evaluated or not).
// Settings is the one table slime.config was given, merged, as JSON:
// the daemon takes shell.command, a window the rest. Keymap lists the
// bindings in the order made; Actions the actions. Errors is why the
// last evaluation failed, if it did (what's described is then the last
// good config, or nothing): a missing file isn't an error.
type ConfigDesc struct {
	Path     string          `json:"path"`
	Settings json.RawMessage `json:"settings"`
	Keymap   []Binding       `json:"keymap"`
	Actions  []ActionDesc    `json:"actions"`
	Errors   []string        `json:"errors,omitempty"`
}

// Binding is one slime.bind: Key as it was written (a chord such as
// "ctrl+shift+d", which the window parses), and what it runs: Action
// with Args, a window action by name (new_split, copy_to_clipboard,
// ...) or else a config action to invoke; or Lua, a function the config
// file gave, which the window runs with action.invoke{lua}. Neither is
// an unbind: the key does nothing, even if the window had a default.
type Binding struct {
	Key    string          `json:"key"`
	Action string          `json:"action,omitempty"`
	Args   json.RawMessage `json:"args,omitempty"`
	Lua    uint32          `json:"lua,omitempty"`
}

// ActionDesc is one slime.action: Args is its argument spec as given
// ({file = "string"}), for listing.
type ActionDesc struct {
	Name  string          `json:"name"`
	Title string          `json:"title,omitempty"`
	Args  json.RawMessage `json:"args,omitempty"`
}

// ConfigCheckParams evaluates Path (the daemon's own file if empty)
// without applying it, answering with what it would set, or the errors.
type ConfigCheckParams struct {
	Path string `json:"path,omitempty"`
}

// ActionInvokeParams runs a config action, Name with Args, or the
// function binding Lua, for Pane (none if zero): the ids its calls fill
// in, and its ctx. Origin says who asked: key (a window), cli (slime
// do), script (slime.invoke), or api. Like script.run, it answers at
// once with a script id, and the run's output and end come as
// script.output and script.done.
type ActionInvokeParams struct {
	Name   string          `json:"name,omitempty"`
	Lua    uint32          `json:"lua,omitempty"`
	Args   json.RawMessage `json:"args,omitempty"`
	Pane   PaneID          `json:"pane,omitzero"`
	Origin string          `json:"origin,omitempty"`
}
