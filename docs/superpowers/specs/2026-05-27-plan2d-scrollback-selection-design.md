# flutter_alacritty Plan 2D — Scrollback, Selection, Copy/Paste

**Date:** 2026-05-27
**Status:** Design approved, pending spec review
**Branch:** `feature/d-scrollback-selection` (off `main` with A + C + B merged @ f44ecb6)

Sub-project D, in one spec **staged into three mergeable phases**:

- **D1 — scrollback** (wheel/keys scroll the history view).
- **D2 — selection + copy** (mouse drag/word/line select, `Ctrl+Shift+C`).
- **D3 — middle-click paste** (in-app primary selection).

---

## 1. Goal & Non-Goals

**Goal.** Scroll back through history with the wheel/keys; select text with the mouse
(drag, double-click word, triple-click line); copy the selection; middle-click to paste
the selection — all using Alacritty's grid history + `Selection` so behavior is correct
across the scrollback buffer.

**Non-goals:**
- X11 PRIMARY system-clipboard integration (use an *in-app* primary = the last selection).
- Rectangular/block selection (Alt-drag), vi-mode selection, search/find-highlight (later).
- A draggable scrollbar widget (wheel/keys only for now).

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Selection | **Approach 1**: Rust-side via `alacritty_terminal::selection::Selection` (semantic/line semantics, history-aware `selection_to_string`); the snapshot marks selected cells with a per-cell flag |
| Scrollback render | Display-offset-aware: render the *displayed* region (`grid.display_iter()`); while scrolled (`display_offset > 0`) every `take_damage` returns a **full** update (scrolling is user-paced, so full re-render is fine) |
| Coordinates | Dart sends **display-relative** (viewport) row/col; Rust converts to an absolute grid `Point` using `display_offset` |
| Staging | One spec; D1 (scrollback) → D2 (selection+copy) → D3 (middle-click paste), each TDD + own commit/merge. D2 depends on D1's coordinate mapping |

## 3. Phase D1 — scrollback

**Rust (`engine.rs`):**
- Make rendering display-offset-aware: `full_snapshot` reads the displayed region via
  `term.grid().display_iter()` (which respects `display_offset`), placing each cell by its
  display-relative point. `take_damage` returns a **full** update whenever
  `display_offset > 0` (and the offset-0 path keeps the existing per-line damage).
- `engine_scroll_lines(delta: i32)` → `term.scroll_display(Scroll::Delta(delta))`.
- `engine_scroll_to_bottom()` → `term.scroll_display(Scroll::Bottom)`.
- `RenderUpdate` gains `display_offset: u32` (so Dart knows whether it is scrolled).

**Dart (`terminal_screen.dart` + client):**
- Mouse wheel **when app mouse mode is off**:
  - **alt-screen** (`kModeAltScreen`, e.g. `less`/vim): send arrow-key sequences (3× `ESC O A`/`B`
    per notch — Alacritty's behavior) instead of scrolling history.
  - otherwise: `engine_scroll_lines(±3)` then re-render (the drain's full snapshot when scrolled).
- A key that sends bytes first calls `engine_scroll_to_bottom()` (typing returns to live).
- New output keeps the current scroll position (Alacritty behavior); resize snaps to bottom.

## 4. Phase D2 — selection + copy

**Rust (`engine.rs`):** use `term.selection: Option<Selection>`.
```
engine_selection_start(display_row: i32, col: u16, right_half: bool, kind: u8) // 0 simple,1 semantic,2 lines
engine_selection_update(display_row: i32, col: u16, right_half: bool)
engine_selection_clear()
engine_selection_text() -> Option<String>   // term.selection_to_string()
```
- Convert `display_row` → absolute `Line` with `display_offset`; `Side` from `right_half`.
- Kind maps to `SelectionType::{Simple, Semantic, Lines}`.
- `FLAG_SELECTED = 1 << 8`: `line_cells` sets it when the cell's absolute point is inside
  `selection.to_range(term)`. `cell_flags.dart` adds `kFlagSelected`.
- Selection cells trigger a full update path (selection changes re-render visible region).

**Dart:**
- `terminal_painter.dart`: a cell with `kFlagSelected` gets a selection highlight — a
  translucent selection color drawn over the cell background (Pass 1).
- `terminal_screen.dart` (pointer, when app mouse mode is **off** or **Shift** is held —
  Shift overrides app mouse grabbing, matching Alacritty):
  - down → start selection; kind by click count within ~300 ms (1 simple, 2 semantic, 3 lines).
  - move → update; up → finalize (cache the text as the in-app primary, §5).
  - `right_half` from the pointer x within the cell.
- `Ctrl+Shift+C` → `engine_selection_text()` → `Clipboard.setData`.
- A key that sends bytes clears the selection (`engine_selection_clear()`); selection
  survives output (Alacritty keeps it).

## 5. Phase D3 — middle-click paste

- On selection finalize (D2 pointer-up), cache the text as `_primary` (in-app primary).
- Middle-click (when app mouse mode is off) → `pasteBytes(_primary, modeFlags)` → PTY
  (reuses B3's bracketed-paste encoder, so multi-line primary paste is bracketed).

## 6. Components / files touched (by phase)

```
D1: rust/src/engine.rs (display_iter render + scroll fns + display_offset field);
    rust/src/api/terminal.rs (regen); lib/render/mirror_grid.dart (displayOffset);
    lib/engine/engine_binding.dart; lib/engine/terminal_engine_client.dart (scroll helpers);
    lib/ui/terminal_screen.dart (wheel: scroll / alt-screen arrows; scroll-to-bottom on key)
D2: rust/src/engine.rs (selection_* + FLAG_SELECTED in line_cells); rust/src/api/terminal.rs (regen);
    lib/render/cell_flags.dart (kFlagSelected); lib/render/terminal_painter.dart (highlight);
    lib/ui/terminal_screen.dart (pointer selection + click-count + Ctrl+Shift+C);
    lib/engine/engine_binding.dart (selection passthroughs)
D3: lib/ui/terminal_screen.dart (_primary cache + middle-click paste)
```

## 7. Testing & acceptance

**D1 (Rust):** advance > screen_lines of output (build history); `engine_scroll_lines(-3)` then
`full_snapshot` shows older lines + `display_offset == 3`; `engine_scroll_to_bottom()` → offset 0,
latest content.

**D2 (Rust):** `selection_start`/`update` across a known span → `selection_text` returns the
expected substring (including across a scrolled offset); `line_cells` sets `FLAG_SELECTED` on
in-range cells only.

**D2 (Dart):** click-count → kind mapping (1/2/3 → simple/semantic/lines); painter highlights a
`kFlagSelected` cell.

**D3 (Dart):** finalize caches `_primary`; middle-click writes `pasteBytes(_primary, …)`.

**Manual (Linux):** wheel scrolls back through `ls -la /usr` output and snaps to bottom on a
keypress; `less`/vim wheel scrolls the pager (alt-screen arrows); drag-select + `Ctrl+Shift+C`
pastes elsewhere; double-click selects a word, triple a line; middle-click pastes the selection;
selection highlight is visible and survives streaming output.

## 8. Risks & open questions

- **`display_iter` vs direct indexing:** the snapshot returns to the offset-aware
  `display_iter` path (as the tracer bullet originally used) so scroll position is honored;
  per-line damage stays only for the offset-0 fast path.
- **Selection ↔ display_offset mapping:** absolute `Line` can be negative (history); convert
  carefully and clamp. Resize clears the selection (safe fallback vs. reflow rotation).
- **Click-count timing:** Flutter has no triple-click out of the box — track tap count + a
  ~300 ms timer in the pointer handler.
- **Selection highlight color:** a fixed translucent accent (e.g. `0x553A6EA5`) over the bg;
  tuned during the D2 manual pass.
- **Wheel in alt-screen → arrows:** 3 lines per notch (Alacritty default); only when app mouse
  mode is off.
- **Open:** rectangular/block selection (Alt-drag) and a visible scrollbar are deferred.
