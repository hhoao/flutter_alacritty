# flutter_alacritty Plan 2C-1 — Wide-Char / CJK Rendering

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/c1-wide-char-cjk` (off `main` @ Plan 2A merged)

This is the **first slice of sub-project C (rendering fidelity)**, narrowed to the
highest-impact visible defect: CJK (double-width) text renders garbled — wide glyphs
squeezed into single-width cells and overlapping, with no CJK-capable font. The rest of
C — text attributes (bold/italic/underline/inverse/dim/strikeout/hidden), cursor
styles + blink, line-spacing — is deferred to later C slices (C-2, C-3), each its own
spec → plan.

---

## 1. Goal & Non-Goals

**Goal.** Render double-width characters correctly: the lead cell's glyph drawn at
two-cell width, the trailing spacer cell skipped, and a CJK-capable monospace font in the
fallback chain — so CJK (and basic single-codepoint wide emoji) align on the grid without
overlap.

**In scope (C-1):**
- Carry per-cell flags into the Dart mirror (currently only codepoint/fg/bg).
- Detect `WIDE_CHAR` (draw at 2× width) and `WIDE_CHAR_SPACER` (skip glyph) in the painter.
- Two-pass painting (all backgrounds, then all glyphs) so a wide glyph isn't overwritten
  by the spacer cell's background.
- Wide-aware glyph cache key + layout width.
- A CJK monospace font in the font fallback chain.
- Cursor on a wide char spans two cells.

**Non-goals (deferred):**
- Text attributes — bold/italic/underline/inverse/dim/strikeout/hidden (C-2).
- Cursor shapes (beam/underline) + blink (C-3).
- Line-spacing/metrics polish (C-3).
- Combining marks / complex emoji (ZWJ sequences, skin-tone modifiers): `line_cells`
  reads only `cell.c` (the primary codepoint); alacritty's `CellExtra.zerowidth`
  combiners are ignored. Single-codepoint wide glyphs render; multi-codepoint graphemes
  are a known limitation for a later slice.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Rendering model | **Approach 1**: per-cell glyph cache + exact grid positioning (mirrors Alacritty's glyph-atlas model) |
| Wide detection | Carry `WIDE_CHAR` / `WIDE_CHAR_SPACER` via the existing `CellData.flags`; add a per-cell flags lane to the Dart mirror |
| Paint order | **Two-pass**: backgrounds first, glyphs second (prevents the spacer cell's bg from erasing a wide glyph's right half) |
| Glyph cache | Key includes a `wide` bit; wide glyphs laid out at `2 * cellWidth` |
| Font | A CJK monospace font (chosen via `fc-match` at implementation time) added to the fallback chain |

## 3. Architecture & data flow

The pipeline from Plan 2A is unchanged (PTY → coalescing client → `engine_advance_and_take_damage` → `MirrorGrid.apply` → `CustomPaint(repaint: grid)`). C-1 widens the cell payload with **flags** and teaches the painter to interpret them.

```
Rust Term cell.flags ──(map_flags)──► CellData.flags : u16  [WIDE_CHAR | WIDE_CHAR_SPACER | …]
        │ FRB
        ▼
FrbEngineBinding._lineCells ── fills ──► LineCells.flags : Uint16List
        ▼
MirrorGrid (new flags lane) ── flagsAt(row,col) ──►
        ▼
TerminalPainter (two-pass):
   pass 1: for every cell → draw bg rect
   pass 2: for every cell →
            spacer?  → skip
            wide?    → glyph at 2×cellWidth (cache key wide=true), spans [c, c+1]
            else     → glyph at cellWidth
   cursor: width = onWideChar ? 2*cellWidth : cellWidth
```

### Flag bits (shared contract)
Rust `engine.rs` already defines `FLAG_BOLD=1<<0 … FLAG_WIDE=1<<4`. C-1 adds:
```
FLAG_WIDE_SPACER = 1 << 5
```
A new `lib/render/cell_flags.dart` mirrors these as Dart consts (kept in sync by a header
comment referencing `engine.rs`). C-1 only *reads* `FLAG_WIDE` and `FLAG_WIDE_SPACER`;
the other bits ride along unused until C-2.

### Glyph cache key
```
key = (codepoint << 25) ^ ((wide ? 1 : 0) << 24) ^ (fg & 0xFFFFFF)
```
(`codepoint` shifted by 25 to leave bit 24 for the wide flag above the 24-bit color.)
`tryGet(codepoint, fg, {required bool wide})`; `_build` lays out with
`width = wide ? 2 * cellWidth : cellWidth`.

### Font
Add a CJK monospace family to the fallback chain, in both `kTerminalTextStyle.fontFamilyFallback`
(used by `CellMetrics`) and `GlyphCache.fontFamilyFallback`. Implementation determines the
installed family via `fc-match` for a CJK codepoint; candidate order:
`Noto Sans Mono CJK SC` → `Noto Sans CJK SC` → `WenQuanYi Micro Hei Mono` → `monospace`.
Cell grid alignment is preserved by forcing layout width to `2*cellWidth` regardless of the
CJK font's natural advance.

## 4. Components / files touched

```
rust/src/engine.rs            add FLAG_WIDE_SPACER; map_flags emits WIDE_CHAR_SPACER
lib/render/cell_flags.dart    NEW — Dart mirror of the flag bits
lib/render/mirror_grid.dart   add flags lane (Uint16List/line) + flagsAt(); LineCells/GridUpdate gain flags
lib/engine/engine_binding.dart  _lineCells fills flags from CellData.flags
lib/render/glyph_cache.dart   wide-aware key + layout width
lib/render/terminal_painter.dart  two-pass paint; wide draw; skip spacer; wide cursor
lib/ui/terminal_screen.dart   CJK font in the fallback chain
lib/render/terminal_painter.dart (kTerminalTextStyle)  add CJK fallback family
```

## 5. Testing & acceptance

**Rust unit:**
- Advance `"中"`; assert the lead cell carries `FLAG_WIDE` and the next cell carries
  `FLAG_WIDE_SPACER`, and the lead cell's codepoint is `中`.

**Dart unit:**
- `MirrorGrid` stores and returns per-cell flags via `flagsAt`; partial/full apply preserve them.
- `GlyphCache`: `tryGet(cp, fg, wide: true)` and `tryGet(cp, fg, wide: false)` return
  distinct cached paragraphs (different keys).
- Painter two-pass: a widget/golden-ish test that a `WIDE_CHAR` cell followed by a
  `WIDE_CHAR_SPACER` paints one glyph (the wide one) and no glyph in the spacer column —
  verified via a counting/stub painter where feasible (else covered by manual acceptance).

**Manual acceptance (Linux):**
- [ ] `echo 中文测试` renders aligned, no overlap.
- [ ] `ls` of a directory with CJK filenames aligns into columns.
- [ ] The `hello` mistype message (the screenshot case) renders cleanly.
- [ ] A line mixing CJK + Latin stays grid-aligned.
- [ ] Cursor positioned on a CJK char covers two cells.
- [ ] A basic single-codepoint wide emoji renders (if the fallback font has it); ZWJ/combining
      sequences are knowingly not handled.

## 6. Risks & open questions

- **CJK font availability.** If none of the candidates is installed, CJK falls back to
  whatever the platform provides (possibly non-monospace). Implementation runs `fc-match`
  and, if needed, documents an install (`apt install fonts-noto-cjk` / `fonts-wqy-microhei`).
- **Wide-glyph advance vs 2×Latin width.** A CJK font's natural glyph advance may differ
  slightly from `2 * cellWidth`; we force the layout box to `2*cellWidth` and position by
  cell, so the grid stays aligned (glyph may be marginally narrower/wider within its box).
- **Flag-bit drift.** The Rust `FLAG_*` consts and `cell_flags.dart` must stay in sync;
  guarded by a cross-referencing comment (FRB does not bridge consts).
- **Open:** whether `WIDE_CHAR_SPACER` cells ever carry a non-space `cell.c` that should be
  suppressed — confirmed during implementation by inspecting the snapshot of `"中"`.
