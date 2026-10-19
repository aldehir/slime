# Deferred

Features and fixes we've chosen to leave for later, and why. Move an
item out when it's done.

## Chrome

The window draws its own title bar and session list with Direct2D over
the terminal, from a tree of widgets (`clients/gui/src/ui/`) that
`clients/gui/src/view.zig` builds from the app's state each frame. The
list has two layouts behind the title bar's toggle: a sidebar, which is
done, and tabs, which isn't. The sidebar is a tree: each tab's row folds
open to a row per pane, with what its programs report doing (OSC 7501,
`clients/gui/src/ProgramStatus.zig`), which slime keeps while no window
is attached.

- **Tabs in the title bar.** The toggle only hides the sidebar; the
  tabs (titles, close buttons, overflow) aren't drawn in the bar.
- **Sidebar scrolling.** Rows past the bottom are clipped.
- **Reordering and renaming** tab rows. Rows have a context menu
  (`clients/gui/src/ui/Menu.zig`, built in `App.openMenu`); a tab's
  only closes it.
- **Right-click goes to the program** that tracks the mouse: the frame
  carries only whether it wants motion (`Flags.motion`), not that it
  tracks buttons, so a right click in a pane opens the menu as well as
  reporting. Ghostty gives the click to the program and keeps the menu
  for shift+right-click.
- **The Menu key** opens the focused pane's menu; shift+F10 goes to the
  program. Menus can't be opened on rows from the keyboard.
- **Closing a window with several sessions** doesn't ask.
- **A session whose child exits** closes its row at once, whatever the
  exit status. The mockups keep a failed one open with its status.
- **Keyboard access** to the chrome (focusing the list, UI Automation),
  a key for the toggle, and jumping to a session by number.
- **The chrome's colors** come from the configured background and
  foreground at startup. They don't follow a program's OSC 10/11, and
  switching between a light/dark theme pair waits on following the
  system's mode live (see Configuration).
- **Remembering the layout** (sidebar or tabs) and the sidebar width.
  Folding a tab's panes isn't remembered either, nor kept by slime.
- **Pane rows have no close button**; a pane closes from its terminal.
- **Program status shows only its state.** A report's message, title,
  progress, and kind (what a blocked program needs) aren't shown, say in
  a tooltip; nor are records other than the most pressing, and `done`
  stays until the program replaces or clears it, with no notion of the
  user having seen it.

## Needs app chrome

These wait for UI on top of the chrome (menus, dialogs, banners) rather
than being piecemealed with MessageBox and the like.

- **Clipboard access prompts.** `clipboard-read` and `clipboard-write`
  accept `ask`, Ghostty's default for reads, but treat it as `deny`.
- **Paste protection.** Ghostty asks before pasting text that could run
  commands: unbracketed text with a newline, or any paste containing the
  bracketed-paste terminator `ESC [201~`. We paste without asking. The
  control-byte stripping in `encodePaste` still applies.
- **Config errors on screen.** Unknown keys and bad values, and an
  `init.lua` that failed to load, only go to the log and `slime config
  show` (Ghostty shows them in a banner).
- **Select all** in a pane's context menu: slime has no event for it.
- **A field's context menu** (cut, copy, paste) on the host field and a
  workspace's name being edited; a right click there does nothing.
- **Scrollbar.**

## Clipboard and selection

- **HTML clipboard format.** Ghostty's copy puts styled HTML on the
  clipboard alongside plain text (`copy_to_clipboard = mixed`). We copy
  plain text only.
- **Copy on select.** Windows has no selection clipboard, so Ghostty's
  default doesn't carry over directly.
- **Clear selection on copy** (`selection-clear-on-copy`), off by default
  in Ghostty too.
- **Double-click a URL selects the whole URL**, and link detection in
  general (OSC 8 hyperlinks, regex links, ctrl+click to open).
- **Ctrl+triple-click selects a command's output.** Needs shell
  integration (OSC 133).
- **Kitty paste events** (mode 5522). slime encodes pastes itself
  rather than going through libghostty-vt's `handler.paste`, so programs
  that ask for paste events get plain pastes.
- **Large pastes** go to slime as one event, so one over 8 MiB (the
  protocol's largest message) is dropped. slime writes them to the pty
  outside the pane's lock, but its connection reader waits until the
  child reads them.
- **OSC 52 reads** aren't answered. The terminal is in slime, which
  would have to ask the window for the clipboard and wait for it inside
  the program's write.

## Rendering

- **Emoji scaling** to the cell width.
- **Default emoji presentation.** A codepoint like U+2B50 (⭐) is drawn
  by the primary font whenever it has the glyph; only U+FE0F asks for
  Segoe UI Emoji. Ghostty picks emoji presentation from the codepoint.
- **Color layers in the text color** (palette index 0xFFFF) are drawn
  white: color glyphs are cached without their cell's colors.
- **Bitmap and COLRv1 color fonts** (PNG, SVG, gradients) need
  `IDWriteFactory4::TranslateColorGlyphRun`; we only composite COLRv0
  layers. Segoe UI Emoji has those.
- **ClearType's pixel geometry** is always RGB. BGR panels would need the
  subpixels swapped, from the monitor's rendering params or a setting.
- **The system's font smoothing setting** isn't followed:
  `font-antialias` defaults to grayscale whatever Windows uses.
- **Gamma and contrast** tuning for text.
- **ClearType over browser panes.** While a browser pane is placed,
  menus, dialogs, and tooltips draw into a transparent overlay chain,
  where Direct2D can't blend ClearType, so their text is grayscale. A
  tab or zoom that hides every browser pane removes the overlay, so its
  UI draws with ClearType again; the cost is that hiding and showing
  tears the overlay chain down and recreates it (two clear presents).
- **Independent flip for the composition chain.** Its `Present` takes
  `ALLOW_TEARING`, but whether DWM still promotes it to an independent
  flip (maximized, VRR) is unmeasured; it needs a display, not a remote
  session.
- **Distinct underline styles** (double, curly, dotted, dashed).

## Kitty graphics

slime's terminals keep the images (PNGs decoded by Go's `image/png`,
Ghostty's default storage limit of 320 MB a screen). Each image a frame
places goes to the window once, deflated, in pieces (wire.go's `Image`),
and every frame carries the placements in the viewport (`frame.zig`'s
`ImageSender`), which `renderer/image.zig` lays out on the window's grid
for the renderer to draw in kitty's three z layers. Placements at a
cell and Unicode placeholders (`U=1`, `U+10EEEE` cells) are drawn.

- **Relative placements** (`P=`/`Q=`). Ghostty's `renderer/image.zig`
  has the placement walk to port; `ImageSender.gather` skips them.
- **Animation.** Nothing calls `ImageStorage.animationTick` in slime,
  so animated images stay on one frame. Advancing one changes the
  image's generation, which resends it whole.
- **File and temp-file media.** `image_limits` is left at `.direct`.
  Shared memory is POSIX `shm_open`; Windows would need its own scheme.
- **`image-storage-limit`** config; slime's is fixed.
- **Device loss.** Image pixels are freed after upload, so recreating
  textures would need slime to send them again, which nothing asks.
- **A placement's pixel size comes from slime**, from the cell size
  the window last sent, so a font size change draws images at the old
  size until the resize comes back.
- **Images inflate on the connection's reader thread**, which holds
  every pane's frames for the tens of milliseconds a big one takes.

## Terminal and window

- **PSEUDOCONSOLE_INHERIT_CURSOR.** Skipped because the screen starts
  empty.

## SSH

`command = ssh://[user@]host[:port]` (or `slime-gui ssh://...`) opens a
host: the local slime logs in (internal/sshbridge), puts its Linux
build of slime there from `remote/` beside the exe, and bridges the
window to it. The connection is the daemon's: every window shares it,
and it stays when the last window closes, so the next one finds the
host connected without logging in. `slime host connect|ls|disconnect`
drive it from a console.

The sidebar lists every host connected to before (`hosts` in the config
directory), and any the daemon is connecting (from a console, or another
window), each a section like Local: once the daemon has the host
connected, every window bridges to the host's slime to list its
workspaces, each a row that shows, hides, renames, and kills as a local
one does, with the ones the last window showed there attached
(`workspaces` keeps a list per host). A host's header button connects
(a plug) or, once connected, makes a workspace there (`+`); its menu
also disconnects the host. A host nothing uses can be forgotten with
the × that shows on hover.

Icon buttons name themselves in a tooltip once the mouse rests on them
(the system hover time), with the key that does the same where there is
one.

- **Tooltips on the caption buttons.** Left to Windows, whose Snap
  Layouts flyout takes hover over maximize.

- **Reordering hosts.** They're listed in the order first connected to.
- **The mouse in text fields** (`ui/TextField.zig`): clicking to
  place the caret, dragging to select, double-click for a word. Only
  the keyboard edits them.
- **IME composition in text fields.** Committed text arrives as
  WM_CHAR, but the candidate window isn't placed at the caret.
- **The Connect field's key** to open it from the keyboard.
- **Long keyboard-interactive rounds.** One past eight questions is cut
  short.

- **Logging in, in the header.** A host shows `+` from the moment the
  daemon starts connecting, before it's logged in. Sessions left from a
  dead connection aren't dimmed, and sit flat under the host (their
  workspace rows go with the connection) until a new connection there
  shows a tab, which replaces them; one that lists the host but shows
  nothing leaves them.
- **A bridge that fails with nobody waiting** (the window listing a
  connected host's workspaces at startup, say against a host daemon
  from another build) says so only in the log; the host's header shows
  it connected, and the next `+` there tries again with a stand-in that
  shows why.
- **The new session key hint** went with the "New session" button.
  Ctrl+Shift+T opens one in the active session's group.
- **More of `~/.ssh/config`.** The daemon reads Host blocks and
  Include, and acts on `HostName`, `User`, `Port`, `IdentityFile`,
  `IdentitiesOnly`, `IdentityAgent`, the known hosts settings,
  `ConnectTimeout`, `ServerAlive*`, and `ProxyJump`. `Match` blocks
  never apply, `ProxyCommand` is refused rather than bypassed, and a
  jump host's own `ProxyJump` isn't followed. Certificates
  (`CertificateFile`) and `HostKeyAlias` are ignored.
- **Agent forwarding, port forwarding, SFTP.** Only the `ssh -D`
  piece exists: while a host is connected the daemon runs a SOCKS5
  proxy over its connection, on loopback with no auth (`slime host ls`
  shows it; `curl --proxy socks5h://127.0.0.1:<port> http://intranet/`
  reaches what the host reaches, names resolved there; `host.proxy =
  false` turns it off). A reconnect asks for the same port, remembered
  only while the daemon lives. A host's browser panes browse through
  it (Browser panes). `-L` and `-R` forwards, the agent, and SFTP are
  still to do.
- **Launching with an `ssh://` URL** attaches the local workspace too,
  since hosts are reached through the local daemon; the host opens
  beside it.

## Persistent workspaces

Every session runs in slime (cmd/slime), a daemon that holds each
pane's ConPTY and terminal, arranged in tabs (each a layout tree) and
workspaces. The window draws what it sends: frames of each pane's screen
(internal/vt/frame.zig), with scrollback, selection, and copying
done in the daemon; keys, the mouse, and the wheel go back as events
(event.zig). A window attaches the workspace detached last, or a new
one, and mirrors it: closing the window detaches the workspace, closing
a pane ends it. Any number of windows can attach one workspace; each
gets its own frames, a pane takes the smallest window's size, input
comes from any of them, and the active tab, focused pane, and zoom are
the daemon's, shared by all. Each sidebar row is a tab, drawn as its tree of panes,
each under a title strip whose buttons split it or zoom it. Dragging the
gap between panes resizes them, and dragging a corner where gaps meet
resizes both ways; dragging a pane by its strip moves it beside another,
along a side of the tab, or into another's place.
`slime tab new`, `split`, and the rest change a workspace from scripts,
attached or not. If slime can't be started, a tab says why.

On SSH hosts it's the same daemon, built for Linux on x86-64 and
carried in `remote/` beside the exe. The local slime installs it as
`~/.cache/slime/bin/<build>/slime` and splices a second connection from
each window to `slime connect` there (its socket is
`/tmp/slime-<uid>/sock`), which lists the host's workspaces as the
first lists the local ones. While a user waits for a pane there, a
session stands in for the host's panes, where logging in asks what it
needs. Where slime can't run (another OS, no gzip, a full disk),
connecting fails and the stand-in says why; ssh.exe in a local tab
still reaches the host. A dropped connection leaves its panes saying
so; the host's button reconnects, reattaches, and replaces them.

- **Losing the local slime** leaves its panes saying so, and new local
  tabs say so too until the next window, which starts a new daemon.
- **Frames pace to the display the window started on.** The refresh period
  goes to slime when connecting, not when the window moves to another
  display.
- **A frame that fails to apply** (out of memory, or a bad one) leaves
  the pane wrong until the next full frame, which nothing asks for.
- **The pwd (OSC 7) and the bell** come from slime but aren't used: a
  new tab doesn't start in the focused pane's directory, and the bell
  does nothing.
- **Search and link detection** would run in slime, over the terminal
  it holds, with matches marked in frames as the selection is.

- **A pane can't be dragged to another tab**, or out into a tab of its
  own, in the window: `pane.move` (`slime pane move`) does it in slime,
  but the drag has no drop target for it.
- **Pane keys unzoom.** Moving focus or resizing from the keyboard while
  a pane is zoomed shows every pane again; there's no Ghostty
  `split-preserve-zoom`, which keeps the newly focused pane zoomed.
- **Dragging a divider resizes the ptys on every move**, so shells
  redraw as it goes; ConPTY copes, but a full-screen program may flicker.
  Holding resizes until the drag ends would need the panes drawn
  scaled or cropped meanwhile.
- **Every pane shares the window's font size.** Panes keep their own
  cell size in slime's layout, but the window draws them all from one
  font grid, and Ctrl+= resizes every pane.
- **A zoomed pane's pty takes the whole tab's size** while it's zoomed,
  so the others reflow when it's unzoomed.
- **`SLIME_WORKSPACE` names a local workspace only.** On a host the
  window lists what the last one showed there, or everything.
- **`SLIME_WORKSPACE` is in every pane's shell**, so a `slime-gui`
  started from a pane shows that pane's workspace alone, as the
  variable has always meant, rather than what the last window showed.
- **A new workspace is named `default`**, as the daemon names one made
  without a name, so two made from the sidebar look alike until
  renamed. The daemon could number them.
- **Hidden workspaces say nothing but a tab count.** Their tabs' titles
  and activity aren't shown (the window isn't attached, so it has no
  panes), and nothing says which window has one shown beyond an eye.
- **A tab can't move to another workspace**; `pane.move` stays within
  one, and there is no `tab.move`.
- **The window's workspace actions have no keys**: showing, hiding,
  making, renaming, and killing are the sidebar's buttons only, and a
  hidden workspace can't be switched to from the keyboard.
- **An empty shown workspace goes when the window hides it** or closes:
  the daemon drops a workspace with no tabs once no window views it, so
  one emptied by closing its tabs lives only while shown.
- **Daemon copies pile up.** slime-gui runs slime from a copy in
  `%LOCALAPPDATA%\slime\bin\<build>\slime.exe`, so a running daemon
  doesn't block the next install, and never deletes old ones.

- **New panes take slime's environment**, from whichever slime-gui started
  it, not the window's (`SLIME_PANE`, `SLIME_WORKSPACE`, `SLIME_EXE`,
  `SLIME_INSTANCE`, and the daemon's directory leading `PATH` added, and
  whatever `env` a `tab.new` or `pane.split` carries; the window sends
  none). A shell profile that resets `PATH` loses `slime`; `SLIME_EXE`
  still names it.
- **Only Linux hosts on x86-64.** Others get a tab saying slime can't
  run there: slime would need libghostty-vt built for them with Zig,
  and `remote/` carries none.
- **Nothing shows while a host's slime starts.** The stand-in is blank
  between logging in and the panes coming, which on a first install
  includes sending about 3 MiB.
- **Builds pile up on hosts**, one `~/.cache/slime/bin/<build>/slime` per
  slime-gui build, never removed.
- **A host's daemon from an older build keeps serving.** A slime-gui whose
  protocol or frame layout differs can't attach there until that daemon
  exits, which is when its panes have all ended.

- **Hosts can still end the daemon.** It runs in a session of its own,
  but systemd-logind with `KillUserProcesses=yes` ends it with the
  user's last login, as it does tmux.
- **A host's panes take the environment of the SSH session that started
  its daemon**, so `SSH_CONNECTION` and the like go stale once that
  connection's gone.
- **Login notices** (banners, "Permanently added") go to slime's log,
  there being no terminal yet to print them in.
- **Nothing reconnects by itself** when a host's connection drops. The
  daemon has the destination and could retry and reopen the bridges.
- **Idle hosts stay connected** for as long as the daemon runs, even
  with no window showing them.
- **Windows sharing a workspace share its colors.** Each window's
  `settings` event sets the terminal's default colors and palette, so
  with two windows on different themes the last to send wins for both.
  Per-window colors would be a remap when the frame is cut.
- **Windows sharing a workspace share its tab.** Both show the active
  tab; per-window views (tmux's grouped sessions) are the model if
  that's wanted. A window showing several workspaces has its own
  current tab among them, so this only bites windows on the same one.

## Browser panes

A pane is a terminal or a browser (`slime pane split --browser <url>`, or
Open browser in a pane's context menu: a blank one split off its right,
its URL bar ready to type in).
The daemon keeps a browser's url and title; the window fills the pane
with WebView2 in visual mode (`Web.zig`), under its title strip (the
page's title, and the split and zoom buttons) and an address row with
back, forward, reload (stop while loading), and a URL bar (a click
selects it all, Enter sends `pane.navigate`, Escape puts it back); only
the strip drags the pane. The mouse is forwarded to the page (a right
click opens the page's own menu, not slime's; the strip and row open
slime's), its keys go to it but for the app's bindings,
and a pane without a browser (no runtime, or one that failed) shows its
title and url and why (`.plans/browser-pane-plan.md`). The URL bar shows
the site's favicon (a globe without one), a dragged pane's picture has
the page in it (`CapturePreview` at drag start), and a page opening a
window on a click (`target=_blank`, `window.open`) splits its pane with
a browser pane to the right, or navigates in place where the pane can't
be split; one its script opens by itself (a timer, on load) opens
nothing. A window that follows a url slime sent shows where the page
lands but reports only the title, so two windows on a site that bounces
to a fresh url each load don't send each other round.
A browser hidden (tab switched away, another pane zoomed) longer than
`browser.idle` seconds (600; 0 never) is closed, and opens its url again
when shown. Camera, microphone, and location requests are denied
without asking; other permissions (notifications, clipboard read, ...)
ask in the window's dialog, "<site> wants to <...>" with Deny and Allow,
one question at a time per pane (a second while one is open is denied,
as is one while another dialog is up). A clicked Allow or Deny is kept
for the site, as browsers keep them; Escape, or the dialog going any
other way (replaced, its pane gone), denies that request alone
(`SavesInProfile` false), so the site asks again next time.

A browser pane in a host's workspace browses the host's network: its
WebView2 environment is the host's
(`%LOCALAPPDATA%\slime\webview\host-<hash of dest>`, cookies apart from
local's and kept per destination), started with `--proxy-server=` the daemon's SOCKS proxy
plus `--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"`,
`--proxy-bypass-list="<-loopback>"`, and
`--force-webrtc-ip-handling-policy=disable_non_proxied_udp` (SOCKS
carries TCP only; WebRTC must not send UDP from here), so every
connection and name lookup happens on the host, localhost and
127.0.0.0/8 included (a dev server on the host is
`http://localhost:3000`). With the proxy
off (`host.proxy = false`) the folder is still the host's but pages go
out locally. A browser keeps the arguments it started with, and a
second environment on the folder silently joins it, so when a host is
lost, disconnected, or comes back on another port, the window closes
its views, waits for the browser process to exit
(`BrowserProcessExited`), and the panes say "Reconnecting the host's
browser…" until the next one starts by itself.

- **A host's browser is untested against a real host.** The arguments
  were tried in a throwaway WebView2 harness against `internal/socks`
  on loopback: a name only the proxy knew loaded, example.com went
  through it by name, a second environment on a running folder with
  other arguments joined the old browser (pid 0, never navigated), and
  after the views closed `BrowserProcessExited` came within 250 ms and
  the next environment used its new proxy. The window's reconnect path
  (`Web.hostChanged`, `retire`) ran only in unit tests of its decision.
- **WebView2's own traffic goes through the host too**: SmartScreen,
  `config.edge.skype.com`, and `edge.microsoft.com` lookups are dialed
  through the proxy, so a host without internet makes them fail.
- **No `browser.follow`**: two windows on one browser pane always
  follow each other's navigation (the plan's open question).
- **A host browser's pid is a guess while it starts**: the window learns
  it from its first WebView; an environment retired before any (or
  after a crash it hasn't heard of), or whose pid is no longer a
  running `msedgewebview2.exe`, is dropped at once, not waited on.
- **A browser that never exits** (another window with a WebView on the
  same host's folder, or a hung one) leaves the panes saying
  "Reconnecting…": a click there stops waiting, lets the old
  environment go, and the next placement makes a new one, which may
  join the old browser and its old proxy if it still runs.
- **No find in page**: `ICoreWebView2Find` waits for the terminal's
  own search (Persistent workspaces: "Search and link detection"), so
  both use one find bar rather
  than the browser getting one of its own.
- **An idle-closed browser comes back as a new page**: its url opens
  again, but its history (back and forward), scroll, and form state are
  gone. A browser asking a permission question isn't closed while it
  asks.
- **Permission answers are WebView2's to keep**: a clicked Allow or
  Deny is saved in the profile and the site isn't asked again; there's
  no list of sites' permissions to change one. A kind WebView2 can't name (`unknown`, or
  newer than its 1.0.4258.31 header) is denied. A page in a pane whose
  tab isn't shown still asks, over the tab that is.
- **A narrow URL bar has no site icon**: under four icons' width of
  text, the favicon (or globe) goes; the sidebar always shows a globe.
- **A dragged browser pane's picture is its strip over an empty box**
  until `CapturePreview` comes back (tens of ms); the page in it is as
  it was when the drag began.
- **A failed browser comes back on a click** in its stand-in or Enter
  in its URL bar; a crash shows only the last page's title and url.
- **Untried on a real display**: modifier chords into a page (posted
  keys can't fake the modifier state; bindings reach the keymap through
  `AcceleratorKeyPressed`, tried with an unmodified F-key), IME in a
  page, the page's cursor, and a DPI change across monitors
  (`RasterizationScale`) were checked only by reading the code.
- **A narrow pane's URL bar** is cut short with an ellipsis; at rest it
  drops `https://`, so the host comes first; when the bar itself would
  be under 140 DIPs the history buttons go (a half-width pane at 1300
  px wide loses them; zoom the pane to get them back).

## Scripting

`slime do` runs Lua in the daemon (internal/lua, gopher-lua): the
`slime` table calls any method of the control plane in process, with
the pane, tab, and workspace the script runs for filled into the ids
it leaves out. `init.lua` (internal/config) is a state of its own that
lives as long as the daemon: `slime.config` sets the settings, `slime.bind`
the keys, and `slime.action` the actions that `slime do <name>`, bound
keys, and `slime.invoke` run (`action.invoke`, which runs as a script).
Scripts and `init.lua` see the daemon's events (`slime.on`, `slime.wait`),
sleep and set timers, run programs (`slime.exec`), and ask the windows on
their workspace to act (`slime.client.queue`): each hook or timer call is
a task on a goroutine with a thread of the state, and a baton lets one
run Lua at a time, so a blocking call lets the others run.

- **An event nobody waits for yet is dropped**: a script that causes an
  event and then calls `slime.wait` could miss one that came in between,
  if the cause were as quick as a few Lua instructions. Keeping recent
  events for a late `wait` would need a rule for how recent.
- **`slime.wait` filters are tables of equal fields** only; a function
  filter would need to run under the baton in the dispatcher.
- **A run ending kills the processes it started**, and a running process
  doesn't keep a run alive: `slime.exec.start` then returning kills it.
  A `detach` option could leave it running.
- **`slime.exec` kills the process alone**, not what it started (a
  killed `cmd.exe`'s `ping` runs on, holding the pipes for up to a
  second).
- **`pane.clipboard`** (OSC 52 writes) isn't an event; viewers get the
  Notice.
- **A `client.action` runs in every window viewing the workspace**, on
  each one's own focus, so `client.queue` refuses the actions that
  change the workspace (`rpc.DaemonActions`: their methods do it once,
  for the pane named) and takes the window-local ones: clipboard and
  font size. Sending one to a single viewer (the one that last sent
  input, say) would need the daemon to track that.
- **Hooks in `init.lua` can't fall back to a window**: `slime.on` runs
  in the daemon; there's no `client.on`.

- **`ctx.client_id`** isn't filled in: connections have no ids, so an
  action can't tell which window pressed its key.
- **A key's action runs for the local daemon only.** A function binding
  pressed while a host's pane is focused runs with no pane, since the
  local `init.lua` doesn't know the host's panes; the host's `init.lua`
  governs only what runs there.
- **Bound keys can't fall through** to the program: a function binding
  or an action binding always consumes its key, since the key has left
  the window by the time Lua runs.
- **A failed `init.lua` is reported in the log and by `slime config
  show`** only; a window started under one shows the defaults with no
  banner (see Needs app chrome).
- **Lists come back as objects when empty**: an action returning
  `slime.workspace.list{}.workspaces` with no workspaces prints `{}`.

- **No `io` library.** `print` is a script's stdout and `slime.log` its
  stderr, one `script.output` each; there's no `io.write`, `io.read`,
  or file access beyond `dofile` and `require`.
- **`pcall` catches `slime.stop`**, which ends a run by raising a
  sentinel error, so a script that wraps it in `pcall` runs on.
- **Empty Lua tables are JSON objects**, so a method that takes a list
  can't be given an empty one; `tabs = {}` fails where no tabs would.
- **`slime.layout.pane{name}`** is passed through and ignored: panes
  have no name.
- **A script's `workspace.new` needs tabs.** With none, the workspace
  would have no viewer to keep it; `slime.tab.new` can't add to it
  first.

## Configuration

The daemon's `init.lua` (`slime config path`) is the configuration:
`slime.config{...}` is one table the daemon hands every window
(`config.get`), which `Config.zig` maps onto its fields (fonts, colors,
themes, padding, word characters, clipboard, ssh) once at startup; the
daemon keeps `shell.command`. Themes stay Ghostty theme files, looked
up beside `init.lua` and beside the exe. `slime.bind` lays bindings
over `binding.zig`'s defaults, which every window takes up again on
`slime config reload`.

- **Reloading the settings** while running: a reload changes the keys
  at once, but the fonts, colors, and the rest wait for the next window.
  Colors can be swapped under the lock; font changes need a new `Grid`
  and atlas.
- **Following light/dark changes** live (`WM_SETTINGCHANGE` with
  "ImmersiveColorSet"), and reporting them with mode 2031
  (`CSI ?997;1n`/`2n`). The mode is read once at startup.
- **Font fallback families.** Ghostty uses every `font.family` after the
  first as a fallback ahead of the system's; we use the first one that's
  installed and fall back through DirectWrite.
- **Key modes** (Rex's `resize/left`, entered and left by actions), and
  Ghostty's physical-key triggers: chords are virtual keys with
  modifiers only.
- **A sequence under way shows nothing**: Rex hints the keys that can
  follow; a strip or tooltip here needs chrome. And a key that's not
  in the sequence is dropped with it, not sent on.
- **Unbinding by prefix** (`slime.unbind("ctrl+b>*")`), and `ctx` for a
  function bound to a sequence doesn't say which keys ran it (Rex's
  `ev.prefix`): one function per sequence for now.
- **`chrome.layout`** (sidebar or tabs) waits on the tabs layout.
- **A window attached to a host keeps the local settings**; a host's
  `init.lua` can't restyle the panes drawn from it.
- **CLI overrides** (`--key=value`) and `+list-themes`.
