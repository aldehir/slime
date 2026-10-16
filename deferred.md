# Deferred

Features and fixes we've chosen to leave for later, and why. Move an
item out when it's done.

## Needs app chrome

We have no UI beyond the terminal grid yet (no menus, dialogs, toasts, or
settings). Rather than piecemeal it with MessageBox and the like, these
wait until there is a proper design for it.

- **Paste protection.** Ghostty asks before pasting text that could run
  commands: unbracketed text with a newline, or any paste containing the
  bracketed-paste terminator `ESC [201~`. We paste without asking. The
  control-byte stripping in `encodePaste` still applies.
- **Configuration.** Font, size, colors, padding, key bindings, word
  boundary characters, and the shell are all constants in the source.
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
- **OSC 52** (programs reading and writing the clipboard).
- **Large pastes** are written to the pty on the UI thread, which blocks
  until the child reads them.

## Rendering

- **Color emoji**: an RGBA atlas and `TranslateColorGlyphRun`.
- **Emoji scaling** to the cell width.
- **Sprite-drawn box drawing** and block elements, so they join
  seamlessly across cells.
- **Gamma and contrast** tuning for text.
- **Per-row dirty caching** in `cells.zig`. Every frame rebuilds every
  row, which costs more now that output streams continuously.
- **Distinct underline styles** (double, curly, dotted, dashed).
- **Selection colors.** Selected cells are inverted, Ghostty's behavior
  without `selection-background`/`selection-foreground` set.

## Terminal and window

- **Window title** from OSC 0/2. It must go through PostMessage: the
  reader thread can't call SetWindowTextW.
- **PSEUDOCONSOLE_INHERIT_CURSOR.** Skipped because the screen starts
  empty.
