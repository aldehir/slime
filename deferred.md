# Deferred

Features and fixes we've chosen to leave for later, and why. Move an
item out when it's done.

## Chrome

The window draws its own title bar and session list (`src/chrome/`) with
Direct2D over the terminal. The list has two layouts behind the title
bar's toggle: a sidebar, which is done, and tabs, which isn't.

- **Tabs in the title bar.** `chrome/tabs.zig` lays out the title bar
  alone; the tabs (titles, close buttons, overflow) aren't drawn.
- **Sidebar scrolling.** Rows past the bottom are clipped.
- **Reordering, renaming,** and a context menu on rows.
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

## Needs app chrome

These wait for UI on top of the chrome (menus, dialogs, banners) rather
than being piecemealed with MessageBox and the like.

- **Clipboard access prompts.** `clipboard-read` and `clipboard-write`
  accept `ask`, Ghostty's default for reads, but treat it as `deny`.
- **Paste protection.** Ghostty asks before pasting text that could run
  commands: unbracketed text with a newline, or any paste containing the
  bracketed-paste terminator `ESC [201~`. We paste without asking. The
  control-byte stripping in `encodePaste` still applies.
- **Config errors on screen.** Unknown keys and bad values only go to
  the log (Ghostty shows them in a banner).
- **Context menu** (copy, paste, select all) on right-click.
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
- **Kitty paste events** (mode 5522). Our paste encodes text itself
  rather than going through libghostty-vt's `handler.paste`, so programs
  that ask for paste events get plain pastes.
- **Large pastes** are written to the pty on the UI thread, which blocks
  until the child reads them.

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
- **Distinct underline styles** (double, curly, dotted, dashed).

## Kitty graphics

Images placed at the cursor are drawn, in kitty's three z layers.

- **Unicode placeholders** (`U=1`, `U+10EEEE` cells) and **relative
  placements** (`P=`/`Q=`). Ghostty's `renderer/image.zig` has the
  placement walk to port; placeholder cells should draw no glyph.
- **Animation.** Nothing calls `ImageStorage.animationTick`, so
  animated images stay on one frame. It returns the next deadline,
  for a UI-thread timer.
- **File and temp-file media.** `image_limits` is left at `.direct`.
  Shared memory is POSIX `shm_open`; Windows would need its own scheme.
- **`image-storage-limit`** config.
- **Device loss.** Image pixels are freed after upload, so recreating
  textures would need them copied from the terminal again.

## Terminal and window

- **PSEUDOCONSOLE_INHERIT_CURSOR.** Skipped because the screen starts
  empty.

## SSH

`command = ssh://[user@]host[:port]` (or `slime ssh://...`) runs sessions
through `slime-ssh.exe` (ssh/), one connection shared by every session
opened from one of its sessions.

The sidebar lists every host connected to before (`hosts` in the config
directory), grouping sessions under them. A host's header button
connects (a plug) or, once connected, opens another channel on the
connection (`+`). A host with no sessions can be forgotten with the ×
that shows on hover.

Icon buttons name themselves in a tooltip once the mouse rests on them
(the system hover time), with the key that does the same where there is
one.

- **Tooltips on the caption buttons.** Left to Windows, whose Snap
  Layouts flyout takes hover over maximize.

- **Reordering hosts.** They're listed in the order first connected to.
- **The mouse in text fields** (`chrome/TextField.zig`): clicking to
  place the caret, dragging to select, double-click for a word. Only
  the keyboard edits them.
- **IME composition in text fields.** Committed text arrives as
  WM_CHAR, but the candidate window isn't placed at the caret.
- **The Connect field's key** to open it from the keyboard.
- **Long keyboard-interactive rounds.** One past eight questions is cut
  short.
- **Notices during login** (`Warning: Permanently added ...`, banners)
  still print in the session's terminal, behind the dialog.
- **Logging in, in the header.** A host shows `+` from the moment its
  helper starts, before it's logged in. Sessions left from a dead
  connection aren't dimmed.
- **Persistent remote sessions.** An SSH session ends with its channel.
  slimed (below) doesn't run on remote hosts yet.
- **The new session key hint** went with the "New session" button.
  Ctrl+Shift+T opens one in the active session's group.
- **More of `~/.ssh/config`.** The helper reads Host blocks and
  Include, and acts on `HostName`, `User`, `Port`, `IdentityFile`,
  `IdentitiesOnly`, `IdentityAgent`, the known hosts settings,
  `ConnectTimeout`, `ServerAlive*`, and `ProxyJump`. `Match` blocks
  never apply, `ProxyCommand` is refused rather than bypassed, and a
  jump host's own `ProxyJump` isn't followed. Certificates
  (`CertificateFile`) and `HostKeyAlias` are ignored.
- **Agent forwarding, port forwarding, SFTP.**
- **Helper logs in GUI builds** go nowhere: there is no stderr to pass.

## Persistent workspaces

`persist-sessions = true` runs local sessions in slimed (ssh/cmd/slimed),
a daemon that holds every pane's ConPTY and terminal state, arranged in
tabs (each a layout tree) and workspaces. A window attaches the workspace
detached last, or a new one, and mirrors it: closing the window detaches
the workspace, closing a pane ends it. Each sidebar row is a tab, drawn as
its tree of panes; the buttons at a pane's top right split it or zoom it,
and dragging the gap between panes resizes them.
`slimed tab new`, `split`, and the rest change a workspace from scripts,
attached or not. Off by default, and only slimed's tabs split.

- **No split bindings** (Ghostty's `new_split`, `goto_split`,
  `resize_split`, `equalize_splits`, `toggle_split_zoom`): splitting,
  zooming, resizing, and moving focus between panes are mouse only.
- **Dragging a divider resizes the ptys on every move**, so shells
  redraw as it goes; ConPTY copes, but a full-screen program may flicker.
  Holding resizes until the drag ends would need the panes drawn
  scaled or cropped meanwhile.
- **Every pane shares the window's font size.** Panes keep their own
  cell size in slimed's layout, but the window draws them all from one
  font grid, and Ctrl+= resizes every pane.
- **Zoom is the window's**, not the workspace's: it's lost on reattach,
  and the zoomed pane's pty takes the whole tab's size meanwhile.
- **A tab a script adds** goes at the end of the Local rows, not where
  slimed lists it.
- **Workspaces have no UI**: no list to attach or detach one, create or
  rename one, or see which window has one. A window takes the most
  recently detached at startup and can't change it.
- **A workspace another window took** ("attached elsewhere") leaves its
  panes saying so; they can only be closed.
- **Daemon copies pile up.** slime runs slimed from a copy in
  `%LOCALAPPDATA%\slime\bin` named for the build, so a running daemon
  doesn't block the next install, and never deletes old ones.
- **A full reset (RIS) in a pane** drops grapheme clustering on the
  daemon's copy of its terminal: libghostty-vt's C API can't set default
  modes, so slimed sets mode 2027's current value only. The next attach
  then shows that pane without clustering.
- **New panes take slimed's environment**, from whichever slime started
  it, not the window's.
- **Several windows on one workspace.** Attaching takes a workspace from
  whoever has it. Sharing needs a rule for whose replies to device
  queries reach the program (clients would send them as their own frame
  type, not input) and whose size each pty takes; a read-only attach
  would sidestep both.

## Configuration

`Config.zig` covers fonts, colors, themes, padding, word characters, and
the command, loaded once at startup.

- **Reloading** while running. Colors can be swapped under the lock;
  font changes need a new `Grid` and atlas.
- **Following light/dark changes** live (`WM_SETTINGCHANGE` with
  "ImmersiveColorSet"), and reporting them with mode 2031
  (`CSI ?997;1n`/`2n`). The mode is read once at startup.
- **Font fallback families.** Ghostty uses every `font-family` after the
  first as a fallback ahead of the system's; we use the first one that's
  installed and fall back through DirectWrite.
- **Key binding config** (`keybind`). `binding.zig` has the actions,
  under Ghostty's names, and the default table a parsed `keybind` would
  extend or override. Triggers are virtual keys only, not Ghostty's
  physical keys, and there are no sequences (`a>b`) or `unbind`.
- **CLI overrides** (`--key=value`) and `+list-themes`.
