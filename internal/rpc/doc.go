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
	{TabNew, "{workspace, name?, layout?: Layout, kind?, url?, command?, cwd?, env?, size?}", "Created",
		"pane is the first pane, which names the tab; without a layout, one pane as PaneSpec says"},
	{TabClose, "{id}", "{}", ""},
	{TabRename, "{id, name}", "{}", ""},
	{TabLayout, "{id, tree: Node}", "{}", "same panes, new shares (a divider drag)"},
	{TabInfo, "{id}", "Tab", ""},
	{PaneSplit, "{pane, direction: right|down|left|up, share?: 1..9999, kind?, url?, command?, cwd?, env?}", "Created",
		"share is the new pane's, in basis points (5000 default); the rest is the new pane's PaneSpec. A terminal without a cwd starts in pane's shell's directory, the last it reported (OSC 7 or 9;9; slime shell-integration), if that shell is on this host"},
	{PaneMove, "{pane, tab?, side?: right|down|left|up}", "Created",
		"into tab along side, or a new tab of its own without tab; the result is the pane's new id, and its old ids keep finding it"},
	{PaneKill, "{id}", "{}", ""},
	{PaneWrite, "{id, text}", "{}", "as typed; no newline is added, a \"\\r\" presses enter; not a browser's"},
	{PaneText, "{id, vt?: bool}", "{text}", "the screen and scrollback: plain, or the VT that redraws it; not a browser's"},
	{PaneInfo, "{id}", "PaneDesc", "a moved pane is found under its old id and described under its current one"},
	{PaneNavigate, "{pane, url}", "{}", "sends a browser pane to url: every window showing it follows (pane.url), and the last page's title is dropped (pane.title) until one reports the new one's"},
	{PaneVisited, "{pane, url, title?}", "{}",
		"a window's browser reports where it went: the daemon keeps url and title, the pane's other viewers and subscribers get pane.url and pane.title"},
	{ScriptRun, "{source, name?, args?: object, pane?, detach?}", "{id}",
		"returns at once; the script's output and end arrive as script.output and script.done"},
	{ScriptCancel, "{id}", "{}", ""},
	{ScriptList, "none", "{scripts: [{id, name, pane, started, detached}]}", ""},
	{ActionInvoke, "{name?, args?: object, lua?, pane?, origin?: key|cli|script|api}", "{id}",
		"runs an action init.lua defined (name) or a function it bound (lua) for pane; answers as script.run does, with script.output and script.done following"},
	{ConfigGet, "none", "Config", "the daemon's init.lua as last evaluated"},
	{ConfigReload, "none", "Config",
		"evaluates init.lua again, as a change to it or a .lua beside it does by itself: on success it replaces the settings, keymap, and actions and config.changed goes out; on failure the last good ones stay and errors says why (to config.changed too)"},
	{ConfigCheck, "{path?}", "Config", "evaluates init.lua (or path) without applying it"},
	{Subscribe, "{events: [\"pane.exited\", \"host.*\", \"*\"]}", "{}", "needs a connection (not from Lua, which has slime.on)"},
	{ClientQueue, "{workspace, name, args?: object}", "{}",
		"sends client.action to the workspace's viewers: each window performs its action name with args (copy_to_clipboard, paste_from_clipboard, increase_font_size {amount}, decrease_font_size, reset_font_size); one that changes the workspace (new_split, new_tab, close_surface, next_tab, goto_split, toggle_split_zoom, resize_split, ...) is refused, as it would run once per window: its method does it once"},
	{DaemonStop, "none", "{}",
		"ends the daemon: the caller gets its reply, then every pane's program is killed and the process exits; windows see it hang up"},
	{HostConnect, "{dest}", "Host", "prompts arrive as host.prompt, answered with host.answer"},
	{HostAnswer, "{host, choice: accept|cancel|skip, answers?}", "{}", ""},
	{HostDisconnect, "{host}", "{}", ""},
	{HostList, "none", "{hosts: [Host]}", ""},
}

// ShapesDoc names the objects the methods and events pass.
const ShapesDoc = `A workspace id is an integer; a tab id is the string "w.t" and a pane id
"w.t.p"; "" is none where one is optional. Times are unix milliseconds.

  Layout         {pane: PaneSpec}
                 | {split: {axis: row|column, children: [{share?, node: Layout}]}}
                 shares in basis points summing to 10000, or all absent for equal parts
  Node           {pane: "w.t.p"} | {split: {axis, children: [{share, node: Node}]}}
                 (a built tab's tree)
  PaneSpec       {kind?: browser, url?, command?, cwd?, env?}: a terminal (no kind)
                 runs command (the shell if none); a browser shows url, which it
                 needs, and takes no command
  Workspace      {id, name, active_tab: "w.t", tabs: [Tab]}
  WorkspaceDesc  Workspace plus {attached, viewers?, detached_at?}
  Tab            {id: "w.t", name?, tree: Node, focus?: "w.t.p", zoomed?: "w.t.p"}
  PaneDesc       {id: "w.t.p", kind?, url?, command, title?, pwd?, cols, rows, created,
                  pid, status?: [{id, state, progress}]}: a browser has kind, url,
                  and title, and zeros for the terminal's
  Created        {pane: "w.t.p"}
  Host           {id, dest, state: connecting|connected|failed|lost|gone, text?, proxy?}
                 proxy is "socks5://127.0.0.1:<port>" while connected: a tunnel
                 into the host's network, names resolved there; none if host.proxy
                 was false when the host connected
  Config         {path, settings: object, keymap: [Binding], actions: [{name, title?, args?}],
                  errors?: [string]}
                 settings is slime.config's table (see slime help lua); errors is why
                 the last evaluation failed, the rest then being the last good config
  Binding        {key, action?, args?, lua?, repeat?}: a chord ("ctrl+shift+d") or a
                 sequence of them ("ctrl+b>c"), and a window
                 action by name with args, a config action to invoke, or lua, a
                 function the window runs with action.invoke{lua}; neither unbinds;
                 repeat keeps a sequence's earlier keys pressed once it runs, so its
                 last key again runs it again`

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
	{EvPaneAttached, "{id, moved_from?, kind?, url?, command, status?} (viewers only; a terminal's frames follow, a browser's nothing)"},
	{EvPaneExited, "{id, status}"},
	{EvPaneTitle, "{id, title}: the program set the title, or a browser's page is titled so (subscribers, and a browser pane's viewers but the one that reported it; a terminal's viewers have it in the pane's notices)"},
	{EvPaneURL, "{id, url}: a browser pane was sent to url (pane.navigate, or another window's pane.visited); its viewers' browsers follow"},
	{EvPanePwd, "{id, pwd}: the shell reported its directory (OSC 7)"},
	{EvPaneBell, "{id}"},
	{EvPaneStatus, "{id, status: [{id, state, progress}]}: a program's status report changed (OSC 7501); every record now"},
	{EvScriptOutput, "{id, stream: stdout|stderr, data}"},
	{EvScriptDone, "{id, ok, result?, error?}"},
	{EvHostChanged, "Host"},
	{EvHostPrompt, "{host, kind, title?, text?, detail?, error?, questions?}"},
	{EvConfigChanged, "Config: after config.reload, or the file changing on disk, whether it succeeded (errors says)"},
	{EvClientAction, "{workspace, name, args?}: a script asked the workspace's viewers to perform a window action (client.queue)"},
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
