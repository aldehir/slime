# Slime icon

| File | What it is |
|---|---|
| `slime.svg` | Full icon: slime on the cream-to-pink rounded-square background. Used above 48px. |
| `slime-small.svg` | Small-size cut: slime only, transparent background, tight crop, no shadow or sparkle dots, bolder smile. Used for 48px and below. |

The build renders both with `src/build/icon.zig` into `slime.ico`
(16-256px, linked into the exe through `src/slime.rc`). `zig build icons`
also writes `slime-16.png` through `slime-1024.png` to `zig-out/icons`.

## Editing

Edit both SVGs if you change the slime itself (body, eyes, shine, colors).
The small SVG is the full one with the background, ground shadow and
sparkle dots removed, the smile stroke raised from 15 to 20, and the viewBox
cropped to `108 158 808 808`. Keep the root `width`/`height` at 1024: the
renderer scales from that.
