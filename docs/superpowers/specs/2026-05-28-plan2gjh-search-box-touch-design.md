# flutter_alacritty Plan 2G·2J·2H — Search, Box-Drawing Long-Tail, Touch Input

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Branch:** `feature/g-search-box-touch` (off `main` @ 7d331f7)

One spec, **three independent phases**, each its own commit (the 2D pattern):

- **2G — search** (`Ctrl+Shift+F` regex find over viewport + scrollback, match highlight, next/prev).
- **2J — box-drawing long-tail** (mixed light/heavy + single/double junctions + dashed lines).
- **2H — touch input** (one-finger scroll, long-press select).

Phases are ordered 2G → 2J → 2H but are independent; 2J touches only `box_drawing.dart`, 2H only
`terminal_screen.dart`, and 2G is additive elsewhere.

---

## 1. Goal & Non-Goals

**Goal.** Three post-config polish features: in-terminal regex search with highlighted matches;
complete the programmatic box-drawing set so it matches alacritty's full U+2500–259F coverage; and
touch-screen input (scroll + selection) for tablets/phones.

**Non-goals (all phases):**
- vi-mode search, search history, incremental match-count over full scrollback (alacritty shows no
  count; scanning 10k lines per keystroke is wasteful — omit it).
- Rectangular/block selection, two-finger pinch-to-zoom (font resize), desktop trackpad gestures.
- Hot-reloading the new config colors (consistent with 2F: load-once).
- Hint/hyperlink colors (alacritty's `colors.hints.*`) — out of scope.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Search engine | `alacritty_terminal::term::search` — `RegexSearch::new(&str)` (regex, alacritty's default) stored on the engine; `Term::search_next(&self, &mut RegexSearch, origin, Direction, Side, Option<usize>) -> Option<Match>` where `Match = RangeInclusive<Point>` |
| Match highlight | **Opaque fg+bg override** (alacritty's behavior, not a translucent overlay). Two pairs from config: `matches` and `focused_match` |
| Search colors (defaults = alacritty) | `matches`: bg `#ac4242` fg `#181818`; `focused_match`: bg `#f4bf75` fg `#181818` |
| Touch model | One-finger vertical drag = **scroll** (with fling inertia); **long-press** = start selection, long-press-drag extends, release finalizes; tap = focus/clear. Mouse keeps the existing `Listener` path |
| Device split | `GestureDetector(supportedDevices: {PointerDeviceKind.touch})` for touch gestures; existing `Listener` handlers gate on `event.kind == PointerDeviceKind.mouse` — clean, non-conflicting |
| Box-drawing | Complete U+2500–256C (all mixed light/heavy + single/double junctions/corners via the arm-weight table) + dashed lines (2504–250B, 254C–254F) via a new `DashOp` |
| Config additions | `[colors.search.matches]` + `[colors.search.focused_match]` — additive schema (proves 2F's forward-compat: old configs still load) |

## 3. Phase 2G — Search

### 3.1 Rust (`engine.rs`, `api/terminal.rs`)

`TerminalEngine` gains:
```rust
search: Option<RegexSearch>,        // compiled pattern (None when search inactive)
current_match: Option<Match>,       // the focused match (for FLAG_MATCH_CURRENT + scroll-into-view)
```

New flag bits (mirror Dart): `FLAG_MATCH = 1 << 9`, `FLAG_MATCH_CURRENT = 1 << 10`.

API (FRB):
- `engine_search_set(pattern: String) -> bool` — `RegexSearch::new(&pattern)`; on `Err` return
  `false` (invalid regex) and leave search cleared; on `Ok` store it, set `current_match` to the
  first match at/after the current viewport top (search right), and scroll it into view.
- `engine_search_next() -> bool` / `engine_search_prev() -> bool` — from `current_match` end/start
  (or viewport edge if none), `Term::search_next(.., Direction::Right/Left, Side::Left, None)`;
  store the result as `current_match`, `scroll_display` to bring its line into the viewport; return
  whether a match was found.
- `engine_search_clear()` — `search = None; current_match = None`.

Snapshot integration: searching mutates the DFA cache (`&mut RegexSearch`), but `full_snapshot`
takes `&self`. **Decision:** add a sibling `engine_full_snapshot_searched(&mut self) -> RenderUpdate`
(FRB sync, `&mut self` like `engine_resize`). It does the normal `full_snapshot` work, then runs
`RegexIter::new(viewport_top, viewport_bottom, Direction::Right, &term, &mut regex)` over **the
visible region only** (cheap — never the whole history), setting `FLAG_MATCH` on cells whose point ∈
any visible match and `FLAG_MATCH_CURRENT` on those ∈ `current_match` (reusing the `point_in_range`
test). The Dart client calls this variant instead of `full_snapshot` while search is active; when
search is cleared it reverts to plain `full_snapshot`. No per-frame clone of `RegexSearch`.

`catch_unwind` wrappers in `api/terminal.rs` unchanged in spirit (search fns wrapped the same way;
`engine_search_set` returns `false` on panic too).

### 3.2 Dart

- `cell_flags.dart`: `kFlagMatch = 1 << 9`, `kFlagMatchCurrent = 1 << 10`, `isMatch`/`isCurrentMatch`.
- `terminal_config.dart`: `TerminalColors` gains `searchMatchFg/Bg`, `searchFocusedFg/Bg` (defaults
  above); `fromTomlString` reads `[colors.search.matches]` + `[colors.search.focused_match]`
  (`foreground`/`background`); getter `searchMatchColors` for the painter.
- `terminal_painter.dart`: a `FLAG_MATCH_CURRENT` cell uses focused fg/bg; a `FLAG_MATCH` cell uses
  matches fg/bg — applied as the **effective** bg (Pass 1) and fg (Pass 2), overriding the cell's
  own colors opaquely (alacritty behavior). Painter gains a `searchColors` param (4 ints).
- `lib/ui/search_bar.dart` (NEW): a bottom overlay `Row` — a `TextField` (autofocus), an
  invalid-regex indicator, ↑/↓ buttons, and a close button. Stateless-ish; callbacks
  `onChanged/onNext/onPrev/onClose`. ~80 lines, no terminal logic.
- `engine_binding.dart`: passthroughs `searchSet(String)->bool`, `searchNext()->bool`,
  `searchPrev()->bool`, `searchClear()`.
- `terminal_engine_client.dart`: `searchSet/next/prev/clear` that call the binding then
  `fullSnapshot()` + `scheduleFrame` (view/flags change — same pattern as `scrollLines`).
- `terminal_screen.dart`: `bool _searchOpen`; `Ctrl+Shift+F` toggles it (intercepted in `_onKey`
  before byte encoding); while open, the search bar owns keyboard — `Enter`→next, `Shift+Enter`→prev,
  `Esc`→clear+close. The bar sits in the existing `Stack` above the painter. Opening pauses
  byte-encoding for terminal keys (the bar's `TextField` has focus).

## 4. Phase 2J — Box-drawing long-tail (`box_drawing.dart` only)

- Extend the `_armWeights` table with every remaining U+2500–254B **mixed light/heavy** junction and
  corner (e.g. `┍ ┎ ┏ ┑ ┒ ┓ … ╅ ╆ … ╋`), each as `[up,down,left,right]` weights (1 light, 2 heavy).
  Reuses the existing `_w(weight, lineWidth)` arm renderer (heavy = 1.8×).
- Extend with U+2552–256B **single/double mixed** junctions/corners (e.g. `╒ ╓ ╕ ╖ ╘ ╙ ╛ ╜ ╞ ╟ ╡ ╢
  ╤ ╥ ╧ ╨ ╪ ╫`), weight `3` = double (already rendered as two parallel arms).
- **Dashed lines**: new `DashOp(Offset a, Offset b, double width, int segments)` op (or a dash list on
  `LineOp`); the painter strokes it as `segments` evenly-spaced dashes. Cover light triple/quad dashes
  `2504 2505 2506 2507 2508 2509 250A 250B` and double dashes `254C 254D 254E 254F` — 3 segments
  (triple), 4 segments (quadruple), horizontal vs vertical by codepoint; heavy variants use 1.8×.
- `box_drawing_test.dart`: representative new cases — a mixed light/heavy tee emits arms with the
  right weights; a single/double mixed corner emits one light + one double arm; `┄` emits a 3-segment
  horizontal `DashOp`; `┋` emits a 4-segment vertical heavy dash.

No Rust/engine/config change. Pure renderer + tests.

## 5. Phase 2H — Touch input (`terminal_screen.dart` only)

- Wrap the child in a `GestureDetector(supportedDevices: {PointerDeviceKind.touch}, ...)` so touch
  gestures never fire for the mouse; the existing `Listener` mouse handlers add an
  `if (e.kind != PointerDeviceKind.mouse) return;` guard so they ignore touch.
- **Scroll** — `onVerticalDragUpdate`: accumulate `delta.dy`; each whole `cellHeight` of movement →
  `scrollLines(±1)` (when app mouse mode off & not alt-screen → history scroll; alt-screen → 3×
  arrow keys per line, mirroring the wheel path; app-mouse-on → mouse scroll events). `onVerticalDragEnd`:
  if `|velocity| > threshold`, fling — a decaying `Ticker`/`AnimationController` keeps emitting
  `scrollLines` with exponential decay until it falls below 1 line/frame or the user touches again.
- **Select** — `onLongPressStart`: `requestFocus`, `selectionStart(cell, simple)` at the pressed
  cell (always local — touch can't hold Shift), `_selecting = true`. `onLongPressMoveUpdate`:
  `selectionUpdate(cell)` + refresh. `onLongPressEnd`: finalize, cache `_primary`.
- **Tap** — `onTap`: `requestFocus`; if a selection exists, clear it (`selectionClear` + refresh).
- Reuses the existing `_cellAt`, `selection*`, `scrollLines`, `_refreshSelection`, `_primary` — no
  new engine surface.
- Tests (`terminal_lifecycle_test.dart` or a new `touch_test.dart`): with the fake binding, a
  simulated touch vertical drag calls `scrollLines`; a long-press calls `selectionStart`; a tap after
  a selection calls `selectionClear`. (Gesture simulation via `WidgetTester.drag`/`longPress` with a
  touch pointer.)

## 6. Components / files (by phase)

```
2G  rust/src/engine.rs (search state + FLAG_MATCH + search fns + snapshot highlight);
    rust/src/api/terminal.rs (engine_search_* + regen); lib/src/rust/** (regen);
    lib/render/cell_flags.dart (kFlagMatch[Current]); lib/render/terminal_painter.dart (search colors);
    lib/config/terminal_config.dart (+search colors, schema, getter);
    lib/engine/engine_binding.dart (search passthroughs); lib/engine/terminal_engine_client.dart (search+snapshot);
    lib/ui/search_bar.dart (NEW); lib/ui/terminal_screen.dart (toggle/route/overlay)
2J  lib/render/box_drawing.dart (+table rows, +DashOp); test/box_drawing_test.dart
2H  lib/ui/terminal_screen.dart (GestureDetector + mouse-kind guard); test (touch gestures)
```

## 7. Error handling

- Invalid search regex → `engine_search_set` returns `false`; the bar shows an invalid indicator;
  no matches highlighted; never crashes (regex build error is caught, not panicked).
- Search with zero matches → `current_match` stays `None`; next/prev return `false` (no-op); bar may
  show "no matches".
- Search cleared on `Esc`/close → flags removed on the next full snapshot.
- New config colors malformed/missing → per-field default (2F's `fromTomlString` already does this).
- Touch fling never scrolls past history bounds (engine clamps `scroll_display`); a new touch cancels
  an in-flight fling.

## 8. Testing & acceptance

**2G Rust:** advance known text; `engine_search_set("foo")` → first match becomes `current_match`;
`full_snapshot` marks `FLAG_MATCH` on the matched cells and `FLAG_MATCH_CURRENT` on the focused one;
`search_next`/`prev` move the focus across the buffer; invalid regex → `set` returns `false`.

**2G Dart:** `fromTomlString` reads the two search color sections (and defaults when absent); painter
applies focused vs matches colors to flagged cells; `Ctrl+Shift+F` opens the bar; `Esc` clears.

**2J:** new box-drawing cases (above) — arm weights, single/double mix, dash segment counts.

**2H:** simulated touch drag → `scrollLines`; long-press(+move) → `selectionStart`/`Update`; tap →
`selectionClear`.

**Manual (Linux + a touch device or emulator):**
- Search: `Ctrl+Shift+F`, type a regex, matches highlight, `Enter`/`Shift+Enter` jump and scroll into
  view, `Esc` closes; invalid regex shows the indicator.
- Box-drawing: a `vim`/`htop`/`tmux` frame using mixed and dashed glyphs renders crisp, aligned (no
  font fallback for the now-covered range).
- Touch: one-finger drag scrolls (with fling); long-press + drag selects; tap clears; mouse wheel and
  drag-select still work unchanged.

**Regression:** the existing suite passes; after any Rust/FRB change, rebuild native
(`flutter build linux --debug`) before `flutter test` (see 2F findings — `flutter test` does not
rebuild the dylib).

## 9. Risks & open questions

- **`RegexSearch` mutability in the snapshot:** searching mutates the DFA cache (`&mut RegexSearch`).
  The snapshot path that highlights matches must take `&mut self`; the client calls the `&mut` entry
  while search is active. Verify FRB exposes a `&mut TerminalEngine` snapshot variant or reuse
  `advance_and_take_damage`'s `&mut`. *(Confirm in 2G Task 1.)*
- **Search perf:** highlight iterates the **visible** region only; jump uses `search_next` with
  `max_lines = None` (whole history) but only on Enter, not per keystroke — acceptable.
- **Touch gesture arena:** long-press vs vertical-drag must not both win. Flutter resolves a
  stationary hold to long-press and movement to drag; verify long-press-then-drag still extends the
  selection (`onLongPressMoveUpdate`) rather than starting a scroll.
- **Fling implementation:** a `Ticker` with exponential decay; cap to avoid runaway; cancel on new
  pointer-down. Inertia constants tuned in the 2H manual pass.
- **Dashed stroke:** even spacing within the cell; ensure dashes don't overflow the cell rect and
  align visually with adjacent solid lines.
