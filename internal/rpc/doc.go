package rpc

// The control plane documents itself here, beside its definition, for
// `slime help methods` and `slime help events`: one entry per method,
// event, and error code, and the shapes they share. A method added to
// the table gets its line here.

// MethodDoc is one method: its params and result as the Lua tables and
// JSON objects look, with ? marking an optional field, and a note on
// what it does beyond the obvious.
type MethodDoc struct {
	Name   string
	Params string
	Result string
	Note   string
}

// MethodDocs lists every method, grouped as their names are.
var MethodDocs = []MethodDoc{
	{WorkspaceList, "none", "{workspaces: [WorkspaceDesc], panes: [PaneDesc]}", ""},
	{WorkspaceNew, "{name?, tabs?: [Layout], attach?: workspace id}", "Workspace",
		"a connection calling it becomes a viewer; a script must give tabs; the viewers of attach get workspace.open once the tabs are up"},
	{WorkspaceAttach, "{id, area?}", "Workspace", "windows only: frames follow"},
	{WorkspaceDetach, "{id}", "{}", ""},
	{WorkspaceKill, "{id}", "{}", "ends every pane in it"},
	{WorkspaceRename, "{id, name}", "{}", ""},
	{WorkspaceResize, "{id, area}", "{}", "a viewer's tab area in pixels"},
	{WorkspaceFocus, "{tab?, pane?, zoomed?}", "{}",
		"tab becomes active, pane its focus (and names the tab if tab is left out), zoomed the zoomed pane (\"\" unzooms)"},
	{WorkspaceInfo, "{id}", "WorkspaceDesc", ""},
	{TabNew, "{workspace, name?, layout?: Layout, command?, cwd?, env?, size?}", "Created",
		"pane is the first pane, which names the tab"},
	{TabClose, "{id}", "{}", ""},
	{TabRename, "{id, name}", "{}", ""},
	{TabLayout, "{id, tree: Node}", "{}", "same panes, new shares (a divider drag)"},
	{TabInfo, "{id}", "Tab", ""},
	{PaneSplit, "{pane, direction: right|down|left|up, share?: 1..9999, command?, cwd?, env?}", "Created",
		"share is the new pane's, in basis points (5000 default)"},
	{PaneMove, "{pane, tab?, side?: right|down|left|up}", "Created",
		"into tab along side, or a new tab of its own without tab; the result is the pane's new id, and its old ids keep finding it"},
	{PaneKill, "{id}", "{}", ""},
	{PaneWrite, "{id, text}", "{}", "as typed; no newline is added, a \"\\r\" presses enter"},
	{PaneText, "{id, vt?: bool}", "{text}", "the screen and scrollback: plain, or the VT that redraws it"},
	{PaneInfo, "{id}", "PaneDesc", "a moved pane is found under its old id and described under its current one"},
	{ScriptRun, "{source, name?, args?: object, pane?, detach?}", "{id}",
		"returns at once; the script's output and end arrive as script.output and script.done"},
	{ScriptCancel, "{id}", "{}", ""},
	{ScriptList, "none", "{scripts: [{id, name, pane, started, detached}]}", ""},
	{Subscribe, "{events: [\"pane.exited\", \"host.*\", \"*\"]}", "{}", "needs a connection (not from Lua)"},
	{HostConnect, "{dest}", "Host", "prompts arrive as host.prompt, answered with host.answer"},
	{HostAnswer, "{host, choice: accept|cancel|skip, answers?}", "{}", ""},
	{HostDisconnect, "{host}", "{}", ""},
	{HostList, "none", "{hosts: [Host]}", ""},
}

// ShapesDoc names the objects the methods and events pass.
const ShapesDoc = `A workspace id is an integer; a tab id is the string "w.t" and a pane id
"w.t.p"; "" is none where one is optional. Times are unix milliseconds.

  Layout         {pane: {command?, cwd?, env?}}
                 | {split: {axis: row|column, children: [{share?, node: Layout}]}}
                 shares in basis points summing to 10000, or all absent for equal parts
  Node           {pane: "w.t.p"} | {split: {axis, children: [{share, node: Node}]}}
                 (a built tab's tree)
  Workspace      {id, name, active_tab: "w.t", tabs: [Tab]}
  WorkspaceDesc  Workspace plus {attached, viewers?, detached_at?}
  Tab            {id: "w.t", name?, tree: Node, focus?: "w.t.p", zoomed?: "w.t.p"}
  PaneDesc       {id: "w.t.p", command, title?, pwd?, cols, rows, created, pid,
                  status?: [{id, state, progress}]}
  Created        {pane: "w.t.p"}
  Host           {id, dest, state: connecting|connected|failed|lost|gone, text?}`

// EventDoc is one notification and its params.
type EventDoc struct {
	Name   string
	Params string
}

// EventDocs lists every notification. A workspace's viewers get their
// workspace's without subscribing; a script's owner gets script.* for
// its scripts; anyone else subscribes.
var EventDocs = []EventDoc{
	{EvWorkspaceCreated, "{id, name}"},
	{EvWorkspaceDestroyed, "{id}"},
	{EvWorkspaceChanged, "Workspace (structure and focus)"},
	{EvWorkspaceDetached, "{id, reason}"},
	{EvWorkspaceOpen, "{id, name}: to the viewers of the workspace a workspace.new named in attach, which open it too"},
	{EvWorkspaceViewerJoined, "{id, viewers}"},
	{EvWorkspaceViewerLeft, "{id, viewers}"},
	{EvTabCreated, "{id, name?}"},
	{EvTabClosed, "{id}"},
	{EvTabRenamed, "{id, name}"},
	{EvTabSelected, "{id}"},
	{EvPaneCreated, "{id}"},
	{EvPaneMoved, "{id, from}: to another tab, under a new id"},
	{EvPaneAttached, "{id, moved_from?, command, status?} (viewers only; frames follow)"},
	{EvPaneExited, "{id, status}"},
	{EvScriptOutput, "{id, stream: stdout|stderr, data}"},
	{EvScriptDone, "{id, ok, result?, error?}"},
	{EvHostChanged, "Host"},
	{EvHostPrompt, "{host, kind, title?, text?, detail?, error?, questions?}"},
}

// CodeDoc is one error code.
type CodeDoc struct {
	Code    int
	Meaning string
}

// CodeDocs lists the error codes a call can fail with.
var CodeDocs = []CodeDoc{
	{CodeMethodNotFound, "no such method"},
	{CodeInvalidParams, "bad params"},
	{CodeNotFound, "no such workspace, tab, pane, host, or script"},
	{CodeUnsupported, "unsupported on this daemon (hosts on Linux)"},
	{CodeFailed, "the op ran and failed (a child didn't start)"},
}
