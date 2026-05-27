# flutter_alacritty Plan 2C — Rendering Fidelity (box-drawing, attributes, cursor)

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/c-rendering-fidelity` (off `main` with A + C-1 merged @ d9d1d86)

This covers **all remaining of sub-project C** after C-1 (wide-char/CJK), in one cohesive
spec but **staged into three independently-mergeable implementation phases**:

- **P1 — box-drawing / block elements** (fixes the broken-border seam).
- **P2 — text attributes** (bold/italic/underline/inverse/dim/strikeout).
- **P3 — cursor shapes + blink**.

The painter's new structure is designed once here so the three phases don't re-architect it.

---

## 1. Goal & Non-Goals

**Goal.** Bring per-cell rendering to fidelity: box-drawing/block characters drawn
programmatically so borders tile seamlessly; SGR text attributes rendered; cursor drawn by
its shape with blink.

**Non-goals:**
- Line-spacing/metrics polish (the programmatic box-drawing makes borders seamless
  regardless of line-height, so this is now purely cosmetic — deferred).
- `hidden`/conceal (SGR 8), underline variants beyond a single solid line
  (double/curl/dotted/dashed render as solid), combining marks / complex emoji.
- Selection / scrollback / copy-paste (sub-project D), input/mouse (B), robustness (E).

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Box-drawing | Programmatic per-cell geometry (Approach 1): a `box_drawing.dart` module the painter delegates to for U+2500–259F; fills the exact cell → seamless regardless of font/line-height (mirrors Alacritty's built-in box font) |
| Attributes | Effective-color computation in the painter (inverse swaps fg/bg, dim darkens fg); bold/italic fold into the glyph (and the cache key); underline/strikeout drawn as canvas lines |
| Cursor | Shape + blinking sourced from `term.cursor_style()`; painter draws block/beam/underline; blink driven by a timer + `Listenable.merge([grid, blinkOn])` repaint |
| Execution | One spec, three mergeable phases (P1 box, P2 attributes, P3 cursor), each TDD + own commit/merge |

## 3. Shared painter structure (designed once)

The painter keeps two-pass painting and adds attribute-aware effective colors, box-drawing
interception, decorations, and shape/blink cursor:

```
effectiveColors(flags, rawFg, rawBg):
    (efg, ebg) = (flags&INVERSE) ? (rawBg, rawFg) : (rawFg, rawBg)
    if flags&DIM: efg = darken(efg, 0.66)
    return (efg, ebg)

Pass 1 — backgrounds:    for each cell → drawRect(cellRect, effectiveColors(...).ebg)
Pass 2 — glyphs/geometry: for each cell (skip WIDE_SPACER, blank):
    efg = effectiveColors(...).efg
    if isBoxDrawing(cp):  paintBoxGlyph(canvas, cellRect, cp, efg, lineWidth)   [P1]
    else:                 drawParagraph(glyphCache.tryGet(cp, efg,
                              bold: flags&BOLD, italic: flags&ITALIC, wide: flags&WIDE)) [P2]
    if flags&UNDERLINE:   draw horizontal line near cell bottom, efg              [P2]
    if flags&STRIKEOUT:   draw horizontal line at cell middle, efg               [P2]
Pass 3 — cursor:         if cursorVisible && (!blinking || blinkOn):
    draw by cursorShape (block / beam / underline), spanning 2 cells on a wide char  [P3]
```
`lineWidth = max(1.0, (cellHeight * 0.08))` (tunable; shared by box-drawing, underline,
strikeout, beam/underline cursor).

## 4. Phase P1 — box-drawing / block elements

**New `lib/render/box_drawing.dart`:**
- `bool isBoxDrawing(int cp)` → `cp >= 0x2500 && cp <= 0x259F`.
- `List<BoxOp> boxOps(int cp, Rect cell, double lineWidth)` — **pure, unit-testable**. `BoxOp`
  is a small union: `LineOp(Offset a, Offset b, double width)`, `RectOp(Rect r, double alphaMul)`,
  `ArcOp(Rect bounds, double startAngle, double sweep, double width)`.
- `void paintBoxGlyph(Canvas, Rect cell, int cp, Color fg, double lineWidth)` — renders the ops.

**Coverage = full U+2500–259F** (partial coverage leaves uncovered chars on the font with
seams). Structure:
- **Lines/junctions (U+2500–254B):** table mapping cp → four arm weights
  (none/light/heavy/double) for up/down/left/right; one routine draws arms from cell center
  to edges. Dashes (┄┅┈┉╌╍) draw segmented arms.
- **Rounded corners (U+256D–2570 ╭╮╰╯):** quarter-circle `ArcOp`.
- **Diagonals (U+2571–2573 ╱╲╳):** corner-to-corner `LineOp`s.
- **Blocks/halves (U+2580–2590 █▀▄▌▐ etc.):** fractional `RectOp` (full/half/eighths).
- **Shades (U+2591–2593 ░▒▓):** full-cell `RectOp` with `alphaMul` 0.25/0.5/0.75 of fg.
- **Quadrants (U+2594–259F ▘▝▖▗▚▞ etc.):** combinations of sub-cell `RectOp`.

**Painter:** in Pass 2, `if (isBoxDrawing(cp)) { paintBoxGlyph(...); continue; }` before the
glyph-cache path.

## 5. Phase P2 — text attributes

- **Rust `engine.rs`:** add `FLAG_DIM` and `FLAG_STRIKEOUT`; `map_flags` emits them from
  `Flags::DIM` / `Flags::STRIKEOUT`. (`BOLD/ITALIC/UNDERLINE/INVERSE` already bridged.)
- **`cell_flags.dart`:** add `kFlagDim`, `kFlagStrikeout` (bits matching Rust).
- **Painter:** `effectiveColors` (inverse swap, dim darken) used by both passes; underline /
  strikeout lines (§3). `darken(rgb, 0.66)` scales each channel.
- **Glyph cache:** key adds bold/italic bits:
  `key = (cp << 27) ^ (bold<<26) ^ (italic<<25) ^ (wide<<24) ^ (efg & 0xFFFFFF)`;
  `tryGet(cp, fg, {bold, italic, wide})`; `_build` applies `FontWeight.bold` / `FontStyle.italic`.

## 6. Phase P3 — cursor shapes + blink

- **Rust:** `cursor_fields` also returns `cursor_style()` → shape + blinking; `RenderUpdate`
  gains `cursor_shape: u8` (0 block, 1 underline, 2 beam, 3 hollow, 4 hidden) and
  `cursor_blinking: bool`. FFI + `MirrorGrid` carry them.
- **Painter Pass 3:** draw by shape — block (filled rect, current behavior), beam (left
  vertical bar `2*lineWidth` wide), underline (bottom horizontal bar), hollow (rect stroke),
  hidden (none). Spans two cells on a wide char (carried from C-1).
- **Blink:** `TerminalScreen` owns a `ValueNotifier<bool> _blinkOn` and a ~530 ms periodic
  timer that toggles it **only when** the snapshot's `cursor_blinking` is true (else steady on).
  The painter's `repaint` becomes `Listenable.merge([grid, blinkOn])` and it reads
  `blinkOn.value`; cursor drawn iff `cursorVisible && (!blinking || blinkOn)`. Timer cancelled
  in `dispose`. (Optional: pause blink when unfocused.)

## 7. Components / files touched (by phase)

```
P1: lib/render/box_drawing.dart (NEW); lib/render/terminal_painter.dart (intercept + lineWidth)
P2: rust/src/engine.rs (FLAG_DIM/STRIKEOUT + map_flags); lib/render/cell_flags.dart;
    lib/render/glyph_cache.dart (bold/italic key + _build); lib/render/terminal_painter.dart
    (effectiveColors + underline/strikeout)
P3: rust/src/engine.rs (cursor shape/blinking in RenderUpdate); rust/src/api/terminal.rs (fields);
    lib/render/mirror_grid.dart (cursorShape/cursorBlinking); lib/render/terminal_painter.dart
    (shape draw + blink); lib/ui/terminal_screen.dart (blink timer + merged repaint)
```

## 8. Testing & acceptance

**P1 (box-drawing):**
- Unit: `isBoxDrawing` boundaries (0x24FF no, 0x2500/0x259F yes, 0x25A0 no); `boxOps` for
  representative cps returns expected ops — `│`→one full-height vertical `LineOp` centered;
  `─`→one horizontal; `┌`→right+down arms; `┼`→all four arms; `═`→two horizontals (double);
  `╭`→one `ArcOp`; `█`→full-cell `RectOp(alpha 1)`; `▀`→top-half `RectOp`; `▌`→left-half;
  `▒`→full-cell `RectOp(alpha 0.5)`; `▗`→bottom-right quadrant `RectOp`.
- Manual: Claude Code rounded border is seamless; `├──┤` and double-line tables continuous;
  htop bars/shades render.

**P2 (attributes):**
- Rust: advance `\x1b[1m` (bold) / `\x1b[2m` (dim) / `\x1b[4m` (underline) / `\x1b[7m`
  (inverse) / `\x1b[9m` (strikeout) + a char; assert the cell flags.
- Dart: `effectiveColors` — inverse swaps, dim darkens; `GlyphCache` bold/italic keys distinct.
- Manual: `ls --color`, `man`/`git diff` (bold/underline/reverse) render correctly.

**P3 (cursor):**
- Rust: `\x1b[5 q` (blinking bar) / `\x1b[2 q` (steady block) set the expected shape + blinking.
- Dart: painter draws the right primitive per shape (recording-canvas/op assertion); blink
  notifier toggles cursor visibility.
- Manual: beam/underline cursors show; blinking cursor blinks; steady doesn't.

## 9. Risks & open questions

- **box_drawing table size/correctness.** 160 codepoints; the arm-weight table covers the
  bulk, with corners/diagonals/blocks/shades/quadrants as structured groups. Per-group tests
  guard correctness; visual acceptance covers the rest.
- **Flag-bit drift** between `engine.rs` and `cell_flags.dart` (manual sync, comment-guarded).
- **Glyph-cache key width:** `cp << 27` stays within JS-safe 53 bits (cp ≤ 0x10FFFF), so web
  is unaffected.
- **Blink repaint cost:** one repaint per ~530 ms when blinking; negligible. Merged Listenable
  must be disposed/cancelled with the widget.
- **Open:** exact `lineWidth` and beam/underline thickness — tuned during P1/P3 against the
  acceptance screenshots.
