# Deferred

Features and fixes we've chosen to leave for later, and why. Move an
item out when it's done.

## Needs app chrome

We have no UI beyond the terminal grid yet (no menus, dialogs, toasts, or
settings). Rather than piecemeal it with MessageBox and the like, these
wait until there is a proper design for it.

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

- **Color emoji**: an RGBA atlas and `TranslateColorGlyphRun`.
- **Emoji scaling** to the cell width.
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
- **Key bindings** (`keybind`).
- **CLI overrides** (`--key=value`) and `+list-themes`.
