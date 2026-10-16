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
