# Lucide icons

SVGs from [Lucide](https://lucide.dev), drawn in the chrome through
Direct2D's SVG renderer (`Painter.Icon`). Only the icons slime uses live
here; browse the full set at https://lucide.dev/icons.

Current version: **1.58.0**. Keep every icon at the same release.

## Adding an icon

1. Download it unmodified from the pinned tag, by its Lucide name:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/lucide-icons/lucide/1.58.0/icons/<name>.svg \
       -o assets/icons/lucide/<name>.svg
   ```

2. Add it to `lucide.zig`, kept alphabetical, with dashes as underscores:

   ```zig
   pub const panel_left = @embedFile("panel-left.svg");
   ```

   The declaration's name becomes a `Painter.Lucide` tag, so it's drawn
   with `c.drawIcon(p, .panel_left, box, color)` from the chrome. The parse
   happens once, when the renderer starts.

3. Size `box` for the icon's 24-unit grid, not its visible extent: most
   Lucide icons leave 2-6 units of margin, so pick the box from the span
   you want (a glyph spanning 14 units drawn 12 px wide needs a ~20 px
   box). Keep box origins on whole pixels.

4. Check it's crisp. `drawIcon` strokes 1 px at 100% (the chrome's
   `stroke()`), so a straight line is sharp only if `box` puts it on a
   pixel center: `panel-left` in a 20 px box has its lines at 2.5, 7.5
   and 17.5; `plus` needs an odd 21 px box to center its lines at 10.5.
   Diagonals don't care. Compare with `scripts\smoke.ps1` screenshots,
   zoomed in, before and after.

## Rules

- Don't edit the SVGs. Painter sets the root's `color` (for
  `currentColor`) and `stroke-width` per draw; anything else must work as
  Lucide ships it. If you need a variant, draw it by hand in `Chrome.zig`.
- Direct2D's SVG renderer has no CSS, `<style>`, `<text>`, filters, or
  masks. Lucide uses plain attributes and basic shapes, so this holds
  today; check a new icon renders before relying on it.
- Updating the version: re-download every icon here from the new tag,
  update the version above and in the URL, and refresh the copyright in
  `THIRD_PARTY_NOTICES.md` if Lucide's `LICENSE` changed.
- Lucide is ISC, with some icons (including `plus`, `terminal`, `x`)
  derived from Feather under MIT. Both notices are in
  `THIRD_PARTY_NOTICES.md`; keep them there.
