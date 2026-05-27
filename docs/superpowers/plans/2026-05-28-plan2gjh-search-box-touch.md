# flutter_alacritty Plan 2G·2J·2H — Search, Box-Drawing Long-Tail, Touch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-terminal regex search with highlighted matches (2G), complete the programmatic box-drawing set to alacritty's full coverage (2J), and add touch-screen scroll + selection (2H).

**Architecture:** Three independent phases, each its own commit (the 2D pattern). 2G: alacritty's `term::search` resolved in Rust, a new `&mut self` snapshot variant highlights visible matches via flags, a Dart bottom search bar drives it. 2J: pure `box_drawing.dart` table + a new dashed-line op. 2H: a touch-only `GestureDetector` layered with the mouse `Listener`, reusing existing scroll/selection engine calls.

**Tech Stack:** Rust (`alacritty_terminal`), flutter_rust_bridge 2.12, Flutter/Dart.

**Spec:** `docs/superpowers/specs/2026-05-28-plan2gjh-search-box-touch-design.md`
**Branch:** `feature/g-search-box-touch` off `main` @ `67954b1`.

**Verified facts:**
- `alacritty_terminal::index::Direction::{Left, Right}`; `Term::scroll_to_point(&mut self, Point)`; `Term::search_next(&self, &mut RegexSearch, origin: Point, Direction, Side, Option<usize>) -> Option<Match>`; `Match = RangeInclusive<Point>`; `RegexSearch::new(&str) -> Result<RegexSearch, Box<BuildError>>` (`Clone`, owns its DFAs); `RegexIter::new(start, end, Direction, &Term, &mut RegexSearch)` yields `Match`.
- `engine.rs` already has `point_in_range`, `viewport_to_point`, `Side`, `Column`, `Line`, `Point`, `Scroll` imported; flag consts go up to `FLAG_SELECTED = 1 << 8`.
- `box_drawing.dart`: `_armOps(arms [up,down,left,right], cell, lineWidth)` renders junctions (weight 1 light, 2 heavy=`_w` 1.8×, 3 double=parallel); `boxOps` dispatches arm-table → rounded → diagonal → block; `paintBoxGlyph` switches `LineOp`/`RectOp`/`ArcOp`.
- After any Rust/FRB change, **`flutter build linux --debug` before `flutter test`** (flutter test does not rebuild the dylib — see 2F findings).

---

## File Structure

```
PHASE 2G
  rust/src/engine.rs              search state, FLAG_MATCH[_CURRENT], search_set/next/prev/clear,
                                    full_snapshot_searched, point_in_match
  rust/src/api/terminal.rs        engine_search_* + engine_full_snapshot_searched (regen)
  lib/src/rust/**                 regen
  lib/render/cell_flags.dart      kFlagMatch / kFlagMatchCurrent + isMatch / isCurrentMatch
  lib/config/terminal_config.dart TerminalColors +4 search ints, copyWith, defaults, fromTomlString, getter
  lib/render/terminal_painter.dart  searchColors param + opaque match fg/bg override
  lib/engine/engine_binding.dart  searchSet/Next/Prev/Clear + fullSnapshotSearched
  lib/engine/terminal_engine_client.dart  _searchActive + search methods + refreshView
  lib/ui/search_bar.dart          NEW bottom search bar widget
  lib/ui/terminal_screen.dart     _searchOpen, Ctrl+Shift+F, overlay, key routing
PHASE 2J
  lib/render/box_drawing.dart     +_armWeights rows, +DashOp + paint case + dash dispatch
  test/box_drawing_test.dart      new cases
PHASE 2H
  lib/ui/terminal_screen.dart     GestureDetector(touch) + mouse-kind guards + fling
```

---

## Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git checkout main && git checkout -b feature/g-search-box-touch
git rev-parse --abbrev-ref HEAD   # expect: feature/g-search-box-touch
```

---

# PHASE 2G — Search

## Task 1: Rust search engine

**Files:**
- Modify: `rust/src/engine.rs`
- Modify: `rust/src/api/terminal.rs`
- Regen: `rust/src/frb_generated.rs`, `lib/src/rust/**`

- [ ] **Step 1: Write the failing Rust tests** — append to the `tests` module in `rust/src/engine.rs`:

```rust
    #[test]
    fn search_set_marks_matches_and_focuses_first() {
        let mut e = engine(20, 5);
        e.advance(b"foo bar foo".to_vec());
        assert!(e.search_set("foo".to_string()));
        let u = e.full_snapshot_searched();
        // First "foo" at col 0..2 is the focused match.
        assert_ne!(u.lines[0].cells[0].flags & FLAG_MATCH, 0);
        assert_ne!(u.lines[0].cells[0].flags & FLAG_MATCH_CURRENT, 0);
        // Second "foo" at col 8..10 is a non-focused match.
        assert_ne!(u.lines[0].cells[8].flags & FLAG_MATCH, 0);
        assert_eq!(u.lines[0].cells[8].flags & FLAG_MATCH_CURRENT, 0);
        // A non-match cell (space at col 3) carries neither flag.
        assert_eq!(u.lines[0].cells[3].flags & (FLAG_MATCH | FLAG_MATCH_CURRENT), 0);
    }

    #[test]
    fn search_next_moves_focus_to_the_second_match() {
        let mut e = engine(20, 5);
        e.advance(b"foo bar foo".to_vec());
        e.search_set("foo".to_string());
        assert!(e.search_next());
        let u = e.full_snapshot_searched();
        assert_ne!(u.lines[0].cells[8].flags & FLAG_MATCH_CURRENT, 0); // second focused
        assert_eq!(u.lines[0].cells[0].flags & FLAG_MATCH_CURRENT, 0); // first no longer
    }

    #[test]
    fn invalid_regex_returns_false_and_highlights_nothing() {
        let mut e = engine(20, 5);
        e.advance(b"foo".to_vec());
        assert!(!e.search_set("(".to_string())); // unbalanced group
        let u = e.full_snapshot_searched();
        assert_eq!(u.lines[0].cells[0].flags & FLAG_MATCH, 0);
    }

    #[test]
    fn search_clear_removes_highlight() {
        let mut e = engine(20, 5);
        e.advance(b"foo".to_vec());
        e.search_set("foo".to_string());
        e.search_clear();
        let u = e.full_snapshot_searched();
        assert_eq!(u.lines[0].cells[0].flags & FLAG_MATCH, 0);
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd rust && cargo test search_ 2>&1 | tail -20
```
Expected: FAIL — `FLAG_MATCH` / `search_set` / `full_snapshot_searched` not found.

- [ ] **Step 3: Add imports + flag constants** — in `rust/src/engine.rs`, change the index import and add the search import (top of file):

```rust
use alacritty_terminal::index::{Column, Direction, Line, Point, Side};
use alacritty_terminal::term::search::{Match, RegexIter, RegexSearch};
```

and after `pub const FLAG_SELECTED: u16 = 1 << 8;` add:

```rust
pub const FLAG_MATCH: u16 = 1 << 9;
pub const FLAG_MATCH_CURRENT: u16 = 1 << 10;
```

- [ ] **Step 4: Add a point-in-match helper** — next to `point_in_range` in `rust/src/engine.rs`:

```rust
fn point_in_match(p: Point, m: &Match) -> bool {
    let (start, end) = (m.start(), m.end());
    let after_start =
        p.line > start.line || (p.line == start.line && p.column >= start.column);
    let before_end = p.line < end.line || (p.line == end.line && p.column <= end.column);
    after_start && before_end
}
```

- [ ] **Step 5: Add the search fields** — extend the `TerminalEngine` struct and its `new`:

```rust
pub struct TerminalEngine {
    term: Term<EventProxy>,
    parser: Processor,
    events: EventQueue,
    palette: [u32; 18],
    search: Option<RegexSearch>,
    current_match: Option<Match>,
}
```

In `new(...)`, add to the constructed value (after `palette`):
```rust
            palette,
            search: None,
            current_match: None,
```

- [ ] **Step 6: Add the search methods** — inside `impl TerminalEngine` (near `selection_*`):

```rust
    pub fn search_set(&mut self, pattern: String) -> bool {
        match RegexSearch::new(&pattern) {
            Ok(re) => {
                self.search = Some(re);
                self.current_match = None;
                self.search_step(Direction::Right);
                true
            }
            Err(_) => {
                self.search = None;
                self.current_match = None;
                false
            }
        }
    }

    pub fn search_next(&mut self) -> bool {
        self.search_step(Direction::Right)
    }

    pub fn search_prev(&mut self) -> bool {
        self.search_step(Direction::Left)
    }

    pub fn search_clear(&mut self) {
        self.search = None;
        self.current_match = None;
    }

    fn search_step(&mut self, direction: Direction) -> bool {
        if self.search.is_none() {
            return false;
        }
        let off = self.term.grid().display_offset();
        let rows = self.term.screen_lines();
        let cols = self.term.columns();
        // Origin: just past the current match in the search direction; else the
        // appropriate viewport corner.
        let origin = match (&self.current_match, direction) {
            (Some(m), Direction::Right) => *m.end(),
            (Some(m), Direction::Left) => *m.start(),
            (None, Direction::Right) => viewport_to_point(off, Point::new(0, Column(0))),
            (None, Direction::Left) => {
                viewport_to_point(off, Point::new(rows - 1, Column(cols - 1)))
            }
        };
        let re = self.search.as_mut().unwrap();
        let found = self.term.search_next(re, origin, direction, Side::Left, None);
        match found {
            Some(m) => {
                self.term.scroll_to_point(*m.start());
                self.current_match = Some(m);
                true
            }
            None => false,
        }
    }

    pub fn full_snapshot_searched(&mut self) -> RenderUpdate {
        let mut update = self.full_snapshot();
        if self.search.is_none() {
            return update;
        }
        let off = self.term.grid().display_offset();
        let rows = self.term.screen_lines();
        let cols = self.term.columns();
        let current = self.current_match.clone();
        let top = viewport_to_point(off, Point::new(0, Column(0)));
        let bottom = viewport_to_point(off, Point::new(rows - 1, Column(cols - 1)));
        let re = self.search.as_mut().unwrap();
        let matches: Vec<Match> =
            RegexIter::new(top, bottom, Direction::Right, &self.term, re).collect();
        for line in update.lines.iter_mut() {
            for col in 0..line.cells.len() {
                let p = viewport_to_point(off, Point::new(line.line as usize, Column(col)));
                if matches.iter().any(|m| point_in_match(p, m)) {
                    line.cells[col].flags |= FLAG_MATCH;
                }
                if let Some(m) = &current {
                    if point_in_match(p, m) {
                        line.cells[col].flags |= FLAG_MATCH_CURRENT;
                    }
                }
            }
        }
        update
    }
```

- [ ] **Step 7: Run the Rust tests**

```bash
cd rust && cargo test 2>&1 | tail -25
```
Expected: all pass (4 new + existing). If a borrow error appears on `search_step`/`full_snapshot_searched`, confirm `self.search.as_mut()` is taken *after* the `self.term` reads above it (the plan's order is borrow-safe: `term` reads first into locals, then `&mut search`, then `&self.term` in the iter — disjoint fields).

- [ ] **Step 8: Add the FRB surface** — in `rust/src/api/terminal.rs` (after the selection fns):

```rust
#[frb(sync)]
pub fn engine_search_set(engine: &mut TerminalEngine, pattern: String) -> bool {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.search_set(pattern))).unwrap_or(false)
}

#[frb(sync)]
pub fn engine_search_next(engine: &mut TerminalEngine) -> bool {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.search_next())).unwrap_or(false)
}

#[frb(sync)]
pub fn engine_search_prev(engine: &mut TerminalEngine) -> bool {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.search_prev())).unwrap_or(false)
}

#[frb(sync)]
pub fn engine_search_clear(engine: &mut TerminalEngine) {
    engine.search_clear();
}

#[frb(sync)]
pub fn engine_full_snapshot_searched(engine: &mut TerminalEngine) -> RenderUpdate {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.full_snapshot_searched()))
        .unwrap_or_else(|_| engine.full_snapshot())
}
```

- [ ] **Step 9: Regenerate FRB + build native**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter_rust_bridge_codegen generate 2>&1 | tail -10
grep -n "engineSearchSet\|engineFullSnapshotSearched" lib/src/rust/api/terminal.dart | head
flutter build linux --debug 2>&1 | tail -3   # rebuild dylib so flutter test sees the new ABI
```
Expected: new `engineSearchSet/Next/Prev/Clear`, `engineFullSnapshotSearched` in the Dart bindings; build succeeds.

- [ ] **Step 10: Commit**

```bash
git add rust/src/engine.rs rust/src/api/terminal.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(rust): regex search (search_set/next/prev/clear + searched snapshot)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 2: Match flags + search colors (Dart)

**Files:**
- Modify: `lib/render/cell_flags.dart`
- Modify: `lib/config/terminal_config.dart`
- Test: `test/cell_flags_test.dart` (if present) and `test/terminal_config_test.dart`

- [ ] **Step 1: Write the failing config test** — append to `test/terminal_config_test.dart`'s `main()`:

```dart
  test('search colors default to alacritty values', () {
    final c = TerminalConfig.defaults().colors;
    expect(c.searchMatchBg, 0xAC4242);
    expect(c.searchMatchFg, 0x181818);
    expect(c.searchFocusedBg, 0xF4BF75);
    expect(c.searchFocusedFg, 0x181818);
  });

  test('fromTomlString reads search colors', () {
    const toml = '''
[colors.search.matches]
background = "#112233"
foreground = "#445566"
[colors.search.focused_match]
background = "#778899"
foreground = "#aabbcc"
''';
    final c = TerminalConfig.fromTomlString(toml).colors;
    expect(c.searchMatchBg, 0x112233);
    expect(c.searchMatchFg, 0x445566);
    expect(c.searchFocusedBg, 0x778899);
    expect(c.searchFocusedFg, 0xAABBCC);
  });
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -8
```
Expected: FAIL — `searchMatchBg` not defined.

- [ ] **Step 3: Add the flag bits** — in `lib/render/cell_flags.dart`, after the `kFlagSelected` line:

```dart
const int kFlagMatch = 1 << 9;
const int kFlagMatchCurrent = 1 << 10;

bool isMatch(int flags) => flags & kFlagMatch != 0;
bool isCurrentMatch(int flags) => flags & kFlagMatchCurrent != 0;
```

- [ ] **Step 4: Add search colors to `TerminalColors`** — in `lib/config/terminal_config.dart`, extend the `TerminalColors` class. Add fields + constructor params + copyWith:

```dart
class TerminalColors {
  const TerminalColors({
    required this.background,
    required this.foreground,
    required this.selection,
    required this.ansi,
    required this.searchMatchBg,
    required this.searchMatchFg,
    required this.searchFocusedBg,
    required this.searchFocusedFg,
  });

  final int background;
  final int foreground;
  final int selection;
  final List<int> ansi; // length 16
  final int searchMatchBg;
  final int searchMatchFg;
  final int searchFocusedBg;
  final int searchFocusedFg;

  TerminalColors copyWith({
    int? background,
    int? foreground,
    int? selection,
    List<int>? ansi,
    int? searchMatchBg,
    int? searchMatchFg,
    int? searchFocusedBg,
    int? searchFocusedFg,
  }) =>
      TerminalColors(
        background: background ?? this.background,
        foreground: foreground ?? this.foreground,
        selection: selection ?? this.selection,
        ansi: ansi ?? this.ansi,
        searchMatchBg: searchMatchBg ?? this.searchMatchBg,
        searchMatchFg: searchMatchFg ?? this.searchMatchFg,
        searchFocusedBg: searchFocusedBg ?? this.searchFocusedBg,
        searchFocusedFg: searchFocusedFg ?? this.searchFocusedFg,
      );
}
```

- [ ] **Step 5: Add defaults** — in `TerminalConfig.defaults()`'s `TerminalColors(...)`, add the four fields (alacritty defaults):

```dart
        colors: TerminalColors(
          background: 0x181818,
          foreground: 0xD8D8D8,
          selection: 0x3A6EA5,
          ansi: [
            0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
            0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
          ],
          searchMatchBg: 0xAC4242,
          searchMatchFg: 0x181818,
          searchFocusedBg: 0xF4BF75,
          searchFocusedFg: 0x181818,
        ),
```

- [ ] **Step 6: Parse search colors in `fromTomlString`** — in `lib/config/terminal_config.dart`, inside `fromTomlString`, after the existing `selectionM` block add:

```dart
    final searchM = section(colorsM, 'search');
    final matchesM = section(searchM, 'matches');
    final focusedM = section(searchM, 'focused_match');
```

and in the returned `TerminalColors(...)`, add the four fields:

```dart
      colors: TerminalColors(
        background: color(primary, 'background', d.colors.background),
        foreground: color(primary, 'foreground', d.colors.foreground),
        selection: color(selectionM, 'background', d.colors.selection),
        ansi: ansi,
        searchMatchBg: color(matchesM, 'background', d.colors.searchMatchBg),
        searchMatchFg: color(matchesM, 'foreground', d.colors.searchMatchFg),
        searchFocusedBg: color(focusedM, 'background', d.colors.searchFocusedBg),
        searchFocusedFg: color(focusedM, 'foreground', d.colors.searchFocusedFg),
      ),
```

- [ ] **Step 7: Run to verify it passes**

```bash
flutter test test/terminal_config_test.dart 2>&1 | tail -8
```
Expected: PASS (incl. the 2 new tests). The existing `TerminalColors` usages compile (only `defaults()` and `fromTomlString` construct it; both updated).

- [ ] **Step 8: Commit**

```bash
git add lib/render/cell_flags.dart lib/config/terminal_config.dart test/terminal_config_test.dart
git commit -m "feat(config): match flags + alacritty search colors

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 3: Painter match highlight

**Files:**
- Modify: `lib/render/terminal_painter.dart`
- Test: `test/terminal_painter_test.dart`

- [ ] **Step 1: Write the failing test** — append to `test/terminal_painter_test.dart` (it already has a "selected cell gets a highlight overlay" test showing the harness). Add:

```dart
  test('current-match cell paints the focused search background', () {
    final grid = MirrorGrid()
      ..apply(GridUpdate(
        full: true, rows: 1, columns: 1,
        lines: [
          LineCells(
            line: 0,
            codepoints: Int32List.fromList([0x41]), // 'A'
            fg: Int32List.fromList([0xD8D8D8]),
            bg: Int32List.fromList([0x181818]),
            flags: Uint16List.fromList([kFlagMatch | kFlagMatchCurrent]),
          )
        ],
        cursorRow: 0, cursorCol: 0, cursorVisible: false,
      ));
    final rec = PictureRecorder();
    final canvas = Canvas(rec);
    TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8),
      cellWidth: 8,
      cellHeight: 16,
      blinkOn: ValueNotifier(true),
      selectionColor: 0x553A6EA5,
      searchColors: const SearchColors(
        matchBg: 0xAC4242, matchFg: 0x181818, focusedBg: 0xF4BF75, focusedFg: 0x181818),
    ).paint(canvas, const Size(8, 16));
    // Smoke: painting a current-match cell does not throw and draws (picture non-null).
    expect(rec.endRecording(), isNotNull);
  });
```

(If the existing painter test already imports `MirrorGrid`/`GridUpdate`/typed_data/`cell_flags`, reuse those imports; otherwise add them.)

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_painter_test.dart 2>&1 | tail -8
```
Expected: FAIL — `SearchColors` / `searchColors` param not defined.

- [ ] **Step 3: Add a `SearchColors` holder + painter param** — in `lib/render/terminal_painter.dart`, add near the top (after imports):

```dart
/// Opaque fg/bg pairs for search matches (alacritty replaces the cell colors).
class SearchColors {
  const SearchColors({
    required this.matchBg,
    required this.matchFg,
    required this.focusedBg,
    required this.focusedFg,
  });
  final int matchBg;
  final int matchFg;
  final int focusedBg;
  final int focusedFg;
}
```

and add the field + constructor param to `TerminalPainter`:

```dart
    required this.blinkOn,
    required this.selectionColor,
    required this.searchColors,
  })  : _paintGeneration = grid.generation,
        super(repaint: Listenable.merge([grid, blinkOn]));
```
```dart
  final int selectionColor;
  final SearchColors searchColors;
```

- [ ] **Step 4: Apply the override** — add a helper to `TerminalPainter` and use it in both passes. Add the method:

```dart
  /// Search match overrides the cell's effective colors opaquely (focused wins).
  ({int fg, int bg}) _withSearch(int flags, ({int fg, int bg}) ec) {
    if (flags & kFlagMatchCurrent != 0) {
      return (fg: searchColors.focusedFg, bg: searchColors.focusedBg);
    }
    if (flags & kFlagMatch != 0) {
      return (fg: searchColors.matchFg, bg: searchColors.matchBg);
    }
    return ec;
  }
```

In Pass 1 (backgrounds), wrap the `effectiveColors(...)` result:
```dart
        final ec = _withSearch(
          grid.flagsAt(row, col),
          effectiveColors(
            grid.flagsAt(row, col),
            grid.fgAt(row, col),
            grid.bgAt(row, col),
          ),
        );
        bgPaint.color = Color(0xFF000000 | ec.bg);
```

In Pass 2 (glyphs), wrap likewise where `ec` is computed:
```dart
        final ec = _withSearch(flags, effectiveColors(flags, grid.fgAt(row, col), grid.bgAt(row, col)));
```

(The cursor pass keeps using `effectiveColors` directly — the cursor is never a search match cell in practice; leaving it avoids extra churn.)

- [ ] **Step 5: Run to verify it passes**

```bash
flutter test test/terminal_painter_test.dart 2>&1 | tail -8
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/render/terminal_painter.dart test/terminal_painter_test.dart
git commit -m "feat(render): opaque search-match color override in painter

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 4: Binding + client search methods

**Files:**
- Modify: `lib/engine/engine_binding.dart`
- Modify: `lib/engine/terminal_engine_client.dart`
- Test: `test/engine_client_test.dart`

- [ ] **Step 1: Write the failing client test** — append to `test/engine_client_test.dart` (it has a fake binding pattern; if its fake doesn't yet implement the new methods, this test drives adding them). Add a minimal recording fake or extend the existing one. Example using a local fake:

```dart
  test('searchSet activates the searched snapshot and refreshes', () async {
    final binding = _SearchFake();
    final grid = MirrorGrid();
    final client = TerminalEngineClient(binding: binding, grid: grid, schedule: (cb) => cb());
    client.searchSet('foo');
    expect(binding.lastSet, 'foo');
    expect(binding.searchedSnapshots, 1); // refreshView used the searched variant
    client.searchClear();
    expect(binding.cleared, isTrue);
  });
```

with the fake (top of file, implementing the full `EngineBinding`; only the new bits matter — others throw/return empty):

```dart
class _SearchFake implements EngineBinding {
  String? lastSet;
  int searchedSnapshots = 0;
  bool cleared = false;
  GridUpdate _empty() => GridUpdate(full: true, rows: 0, columns: 0, lines: const [],
      cursorRow: 0, cursorCol: 0, cursorVisible: false);
  @override bool searchSet(String p) { lastSet = p; return true; }
  @override bool searchNext() => true;
  @override bool searchPrev() => true;
  @override void searchClear() { cleared = true; }
  @override GridUpdate fullSnapshotSearched() { searchedSnapshots++; return _empty(); }
  @override GridUpdate fullSnapshot() => _empty();
  @override Future<void> advance(Uint8List b) async {}
  @override Future<GridUpdate> takeDamage() async => _empty();
  @override Future<GridUpdate> advanceAndTakeDamage(Uint8List b) async => _empty();
  @override void pumpEvents() {}
  @override void resize(int c, int r) {}
  @override Future<void> scrollLines(int d) async {}
  @override Future<void> scrollToBottom() async {}
  @override void selectionStart(int r, int c, bool rh, int k) {}
  @override void selectionUpdate(int r, int c, bool rh) {}
  @override void selectionClear() {}
  @override String? selectionText() => null;
  @override void dispose() {}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/engine_client_test.dart 2>&1 | tail -8
```
Expected: FAIL — `searchSet`/`fullSnapshotSearched` not on `EngineBinding`; `client.searchSet` missing.

- [ ] **Step 3: Extend the `EngineBinding` interface** — in `lib/engine/engine_binding.dart`, add to the abstract class:

```dart
  bool searchSet(String pattern);
  bool searchNext();
  bool searchPrev();
  void searchClear();
  GridUpdate fullSnapshotSearched();
```

- [ ] **Step 4: Implement them on `FrbEngineBinding`** — in the same file:

```dart
  @override
  bool searchSet(String pattern) => engineSearchSet(engine: _engine, pattern: pattern);

  @override
  bool searchNext() => engineSearchNext(engine: _engine);

  @override
  bool searchPrev() => engineSearchPrev(engine: _engine);

  @override
  void searchClear() => engineSearchClear(engine: _engine);

  @override
  GridUpdate fullSnapshotSearched() =>
      _toGridUpdate(engineFullSnapshotSearched(engine: _engine));
```

- [ ] **Step 5: Add client search methods** — in `lib/engine/terminal_engine_client.dart`, add a field and methods:

```dart
  bool _searchActive = false;

  /// Re-applies the current viewport (searched snapshot while search is active),
  /// used by selection refresh and search navigation. Search highlight changes
  /// FLAG_MATCH on cells whose content didn't change, so a full snapshot is needed.
  void refreshView() {
    _grid.apply(_searchActive ? _binding.fullSnapshotSearched() : _binding.fullSnapshot());
    SchedulerBinding.instance.scheduleFrame();
  }

  bool searchSet(String pattern) {
    _searchActive = _binding.searchSet(pattern);
    refreshView();
    return _searchActive;
  }

  bool searchNext() {
    final ok = _binding.searchNext();
    refreshView();
    return ok;
  }

  bool searchPrev() {
    final ok = _binding.searchPrev();
    refreshView();
    return ok;
  }

  void searchClear() {
    _binding.searchClear();
    _searchActive = false;
    refreshView();
  }
```

- [ ] **Step 6: Route scroll refresh through the searched snapshot** — in `lib/engine/terminal_engine_client.dart`, change `scrollLines` and `scrollToBottom` to reuse `refreshView()` so matches stay highlighted while scrolling during search:

```dart
  Future<void> scrollLines(int delta) async {
    await _binding.scrollLines(delta);
    refreshView();
  }

  Future<void> scrollToBottom() async {
    await _binding.scrollToBottom();
    refreshView();
  }
```

- [ ] **Step 7: Run to verify it passes**

```bash
flutter test test/engine_client_test.dart 2>&1 | tail -8
```
Expected: PASS. Note: the existing `terminal_lifecycle_test`/`engine_bindings_test` fakes implement `EngineBinding` and now need the 5 new members — add them to those fakes (returning `false`/empty) in this step if the suite flags missing overrides:

```bash
flutter test 2>&1 | tail -6   # if other fakes fail to compile, add the 5 stubs to them
```

- [ ] **Step 8: Commit**

```bash
git add lib/engine/engine_binding.dart lib/engine/terminal_engine_client.dart test/
git commit -m "feat(engine): search passthroughs + searched-snapshot refresh

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

## Task 5: Search bar widget + screen wiring

**Files:**
- Create: `lib/ui/search_bar.dart`
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart` (toggle test)

- [ ] **Step 1: Create the search bar widget** — `lib/ui/search_bar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bottom search bar: a text field plus prev/next/close. Pure UI — all terminal
/// logic stays in TerminalScreen via the callbacks.
class TerminalSearchBar extends StatefulWidget {
  const TerminalSearchBar({
    required this.onChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
    super.key,
  });

  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  State<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends State<TerminalSearchBar> {
  final FocusNode _node = FocusNode();
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _node.requestFocus();
  }

  @override
  void dispose() {
    _node.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      HardwareKeyboard.instance.isShiftPressed ? widget.onPrev() : widget.onNext();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xEE202020),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: Color(0xFFBBBBBB)),
          const SizedBox(width: 8),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _ctrl,
                focusNode: _node,
                autofocus: true,
                style: const TextStyle(color: Color(0xFFEDEDED), fontSize: 14),
                cursorColor: const Color(0xFFEDEDED),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'search (regex)',
                  hintStyle: TextStyle(color: Color(0xFF888888)),
                ),
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onNext(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onPrev,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onNext,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Write the failing toggle test** — append to `test/terminal_lifecycle_test.dart` (reuses `_FakePty`/`_FakeBinding`; ensure those fakes implement the 5 new EngineBinding members from Task 4):

```dart
  testWidgets('Ctrl+Shift+F toggles the search bar', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns, required rows, required onPtyWrite, required onTitle,
          required onBell, required onClipboard, required engineConfig,
        }) => _FakeBinding(),
      ),
    ));
    await tester.pump();
    expect(find.byType(TerminalSearchBar), findsNothing);
    // Open with Ctrl+Shift+F.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byType(TerminalSearchBar), findsOneWidget);
    title.dispose();
  });
```

- [ ] **Step 3: Run to verify it fails**

```bash
flutter test test/terminal_lifecycle_test.dart 2>&1 | tail -10
```
Expected: FAIL — `TerminalSearchBar` not found / never shown.

- [ ] **Step 4: Wire the screen** — in `lib/ui/terminal_screen.dart`:

Add the import:
```dart
import 'search_bar.dart';
```

Add state field (near `_searchOpen` siblings):
```dart
  bool _searchOpen = false;
```

In `_onKey`, intercept Ctrl+Shift+F **before** the byte-encoding (right after the existing Ctrl+Shift+C block):
```dart
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      setState(() => _searchOpen = !_searchOpen);
      if (!_searchOpen) _client?.searchClear();
      return KeyEventResult.handled;
    }
```

Add the handlers:
```dart
  void _searchChanged(String pattern) {
    if (pattern.isEmpty) {
      _client?.searchClear();
    } else {
      _client?.searchSet(pattern);
    }
  }

  void _closeSearch() {
    setState(() => _searchOpen = false);
    _client?.searchClear();
  }
```

In `build`, add the bar to the existing `Stack` (after the overlay banner child):
```dart
                  if (_searchOpen)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: TerminalSearchBar(
                        onChanged: _searchChanged,
                        onNext: () => _client?.searchNext(),
                        onPrev: () => _client?.searchPrev(),
                        onClose: _closeSearch,
                      ),
                    ),
```

Pass `searchColors` to the painter (in the `TerminalPainter(...)` construction):
```dart
                      selectionColor: _config.selectionOverlay,
                      searchColors: SearchColors(
                        matchBg: _config.colors.searchMatchBg,
                        matchFg: _config.colors.searchMatchFg,
                        focusedBg: _config.colors.searchFocusedBg,
                        focusedFg: _config.colors.searchFocusedFg,
                      ),
```

- [ ] **Step 5: Run to verify it passes + full suite**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -6
```
Expected: analyze clean; all green (2G done).

- [ ] **Step 6: Commit**

```bash
git add lib/ui/search_bar.dart lib/ui/terminal_screen.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): search bar + Ctrl+Shift+F wiring

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 2J — Box-drawing long-tail

## Task 6: Mixed junctions + dashed lines

**Files:**
- Modify: `lib/render/box_drawing.dart`
- Test: `test/box_drawing_test.dart`

- [ ] **Step 1: Write the failing tests** — append to `test/box_drawing_test.dart` (it has `boxOps`/`LineOp`/`DashOp` patterns; reuse its helpers):

```dart
  test('mixed light/heavy tee has a heavy arm and light arms', () {
    // ┝ U+251D: up light, down light, right heavy (left none).
    final ops = boxOps(0x251D, const Rect.fromLTWH(0, 0, 10, 20), 1.0);
    final lines = ops.whereType<LineOp>().toList();
    expect(lines.length, greaterThanOrEqualTo(3));
    // The right arm is heavy (width 1.8), the vertical arms are light (1.0).
    expect(lines.any((l) => l.width == 1.8), isTrue);
    expect(lines.any((l) => l.width == 1.0), isTrue);
  });

  test('single/double mixed corner emits a light and a double arm', () {
    // ╒ U+2552: down single (light), right double.
    final ops = boxOps(0x2552, const Rect.fromLTWH(0, 0, 10, 20), 1.0);
    final lines = ops.whereType<LineOp>().toList();
    // double arm = two parallel strokes → at least 3 line ops total.
    expect(lines.length, greaterThanOrEqualTo(3));
  });

  test('light triple dash horizontal emits a 3-segment DashOp', () {
    final ops = boxOps(0x2504, const Rect.fromLTWH(0, 0, 12, 20), 1.0); // ┄
    final dash = ops.whereType<DashOp>().single;
    expect(dash.segments, 3);
    expect(dash.a.dy, dash.b.dy); // horizontal
  });

  test('heavy quadruple dash vertical is a 4-segment heavy DashOp', () {
    final ops = boxOps(0x250B, const Rect.fromLTWH(0, 0, 12, 20), 1.0); // ┋
    final dash = ops.whereType<DashOp>().single;
    expect(dash.segments, 4);
    expect(dash.a.dx, dash.b.dx); // vertical
    expect(dash.width, 1.8);      // heavy
  });
```

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/box_drawing_test.dart 2>&1 | tail -10
```
Expected: FAIL — `DashOp` undefined; mixed glyphs return empty ops.

- [ ] **Step 3: Add the `DashOp` type** — in `lib/render/box_drawing.dart`, add to the sealed `BoxOp` family (next to `LineOp`):

```dart
class DashOp extends BoxOp {
  const DashOp(this.a, this.b, this.width, this.segments);
  final Offset a;
  final Offset b;
  final double width;
  final int segments;
}
```

- [ ] **Step 4: Add dashed dispatch + builder** — in `lib/render/box_drawing.dart`, in `boxOps`, add a dashed check **before** the arm-table lookup:

```dart
List<BoxOp> boxOps(int cp, Rect cell, double lineWidth) {
  final dash = _dashedOps(cp, cell, lineWidth);
  if (dash.isNotEmpty) return dash;
  // ... existing arm-table / rounded / diagonal / block dispatch unchanged ...
}
```

and add the builder:

```dart
// Dashed lines: 2504-250B (light/heavy triple/quadruple) + 254C-254F (double).
List<BoxOp> _dashedOps(int cp, Rect cell, double lineWidth) {
  // (segments, heavy, vertical) by codepoint.
  const table = <int, (int, bool, bool)>{
    0x2504: (3, false, false), 0x2505: (3, true, false), // ┄ ┅ horizontal triple
    0x2506: (3, false, true), 0x2507: (3, true, true), //   ┆ ┇ vertical triple
    0x2508: (4, false, false), 0x2509: (4, true, false), // ┈ ┉ horizontal quad
    0x250A: (4, false, true), 0x250B: (4, true, true), //   ┊ ┋ vertical quad
    0x254C: (2, false, false), 0x254D: (2, true, false), // ╌ ╍ horizontal double
    0x254E: (2, false, true), 0x254F: (2, true, true), //   ╎ ╏ vertical double
  };
  final spec = table[cp];
  if (spec == null) return const [];
  final (segments, heavy, vertical) = spec;
  final cx = cell.center.dx, cy = cell.center.dy;
  final w = heavy ? lineWidth * 1.8 : lineWidth;
  final a = vertical ? Offset(cx, cell.top) : Offset(cell.left, cy);
  final b = vertical ? Offset(cx, cell.bottom) : Offset(cell.right, cy);
  return [DashOp(a, b, w, segments)];
}
```

- [ ] **Step 5: Paint `DashOp`** — in `paintBoxGlyph`'s `switch (op)`, add a case:

```dart
      case DashOp(:final a, :final b, :final width, :final segments):
        stroke.strokeWidth = width;
        // Each segment occupies 2/3 of its slot, leaving a 1/3 gap.
        final dx = (b.dx - a.dx) / segments;
        final dy = (b.dy - a.dy) / segments;
        for (var i = 0; i < segments; i++) {
          final s = Offset(a.dx + dx * i, a.dy + dy * i);
          final e = Offset(a.dx + dx * (i + 0.66), a.dy + dy * (i + 0.66));
          canvas.drawLine(s, e, stroke);
        }
```

- [ ] **Step 6: Add the mixed light/heavy + single/double table rows** — in `lib/render/box_drawing.dart`, extend the `_armWeights` map with the remaining glyphs. Add these entries (weights `[up, down, left, right]`; 1 light, 2 heavy, 3 double):

```dart
  // Mixed light/heavy junctions & corners (U+2500-254B long-tail).
  0x250D: [0, 1, 0, 2], 0x250E: [0, 2, 0, 1], 0x250F: [0, 2, 0, 2], // ┍ ┎ ┏
  0x2511: [0, 1, 2, 0], 0x2512: [0, 2, 1, 0], 0x2513: [0, 2, 2, 0], // ┑ ┒ ┓
  0x2515: [1, 0, 0, 2], 0x2516: [2, 0, 0, 1], 0x2517: [2, 0, 0, 2], // ┕ ┖ ┗
  0x2519: [1, 0, 2, 0], 0x251A: [2, 0, 1, 0], 0x251B: [2, 0, 2, 0], // ┙ ┚ ┛
  0x251D: [1, 1, 0, 2], 0x251E: [2, 1, 0, 1], 0x251F: [1, 2, 0, 1], // ┝ ┞ ┟
  0x2520: [2, 2, 0, 1], 0x2521: [2, 1, 0, 2], 0x2522: [1, 2, 0, 2], 0x2523: [2, 2, 0, 2], // ┠ ┡ ┢ ┣
  0x2525: [1, 1, 2, 0], 0x2526: [2, 1, 1, 0], 0x2527: [1, 2, 1, 0], // ┥ ┦ ┧
  0x2528: [2, 2, 1, 0], 0x2529: [2, 1, 2, 0], 0x252A: [1, 2, 2, 0], 0x252B: [2, 2, 2, 0], // ┨ ┩ ┪ ┫
  0x252D: [0, 1, 2, 1], 0x252E: [0, 1, 1, 2], 0x252F: [0, 1, 2, 2], // ┭ ┮ ┯
  0x2530: [0, 2, 1, 1], 0x2531: [0, 2, 2, 1], 0x2532: [0, 2, 1, 2], 0x2533: [0, 2, 2, 2], // ┰ ┱ ┲ ┳
  0x2535: [1, 0, 2, 1], 0x2536: [1, 0, 1, 2], 0x2537: [1, 0, 2, 2], // ┵ ┶ ┷
  0x2538: [2, 0, 1, 1], 0x2539: [2, 0, 2, 1], 0x253A: [2, 0, 1, 2], 0x253B: [2, 0, 2, 2], // ┸ ┹ ┺ ┻
  0x253D: [1, 1, 2, 1], 0x253E: [1, 1, 1, 2], 0x253F: [1, 1, 2, 2], // ┽ ┾ ┿
  0x2540: [2, 1, 1, 1], 0x2541: [1, 2, 1, 1], 0x2542: [2, 2, 1, 1], // ╀ ╁ ╂
  0x2543: [2, 1, 2, 1], 0x2544: [2, 1, 1, 2], 0x2545: [1, 2, 2, 1], 0x2546: [1, 2, 1, 2], // ╃ ╄ ╅ ╆
  0x2547: [2, 1, 2, 2], 0x2548: [1, 2, 2, 2], 0x2549: [2, 2, 2, 1], 0x254A: [2, 2, 1, 2], 0x254B: [2, 2, 2, 2], // ╇ ╈ ╉ ╊ ╋
  // Single/double mixed junctions & corners (U+2552-256B; 1 light, 3 double).
  0x2552: [0, 1, 0, 3], 0x2553: [0, 3, 0, 1], // ╒ ╓
  0x2555: [0, 1, 3, 0], 0x2556: [0, 3, 1, 0], // ╕ ╖
  0x2558: [1, 0, 0, 3], 0x2559: [3, 0, 0, 1], // ╘ ╙
  0x255B: [1, 0, 3, 0], 0x255C: [3, 0, 1, 0], // ╛ ╜
  0x255E: [1, 1, 0, 3], 0x255F: [3, 3, 0, 1], // ╞ ╟
  0x2561: [1, 1, 3, 0], 0x2562: [3, 3, 1, 0], // ╡ ╢
  0x2564: [0, 1, 3, 3], 0x2565: [0, 3, 1, 1], // ╤ ╥
  0x2567: [1, 0, 3, 3], 0x2568: [3, 0, 1, 1], // ╧ ╨
  0x256A: [1, 1, 3, 3], 0x256B: [3, 3, 1, 1], // ╪ ╫
```

- [ ] **Step 7: Run to verify it passes**

```bash
flutter test test/box_drawing_test.dart 2>&1 | tail -10
```
Expected: PASS (4 new + existing). The mixed-weight arms render via the existing `_armOps` (its `arm()` already handles per-arm weights 1/2/3); double single-mixed via weight 3.

- [ ] **Step 8: Commit**

```bash
git add lib/render/box_drawing.dart test/box_drawing_test.dart
git commit -m "feat(render): box-drawing long-tail — mixed junctions + dashed lines

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

# PHASE 2H — Touch input

## Task 7: Touch gestures

**Files:**
- Modify: `lib/ui/terminal_screen.dart`
- Test: `test/terminal_lifecycle_test.dart` (or new `test/touch_test.dart`)

- [ ] **Step 1: Write the failing touch tests** — append to `test/terminal_lifecycle_test.dart`. The `_FakeBinding` must record `scrollLines`/`selectionStart`/`selectionClear`; if it doesn't already, add counters to it:

```dart
  testWidgets('one-finger drag scrolls; long-press selects', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding(); // with int scrollCalls; int selStartCalls; recorded
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns, required rows, required onPtyWrite, required onTitle,
          required onBell, required onClipboard, required engineConfig,
        }) => binding,
      ),
    ));
    await tester.pump();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    // Touch vertical drag → scroll.
    final g = await tester.startGesture(center, kind: PointerDeviceKind.touch);
    await g.moveBy(const Offset(0, -60));
    await g.up();
    await tester.pump();
    expect(binding.scrollCalls, greaterThan(0));
    // Long-press → selection start.
    await tester.longPressAt(center); // helper below, or tester.startGesture + delay
    await tester.pump();
    expect(binding.selStartCalls, greaterThan(0));
    title.dispose();
  });
```

(If `longPressAt` is unavailable, use `final lp = await tester.startGesture(center, kind: PointerDeviceKind.touch); await tester.pump(const Duration(milliseconds: 600)); await lp.up();`.)

- [ ] **Step 2: Run to verify it fails**

```bash
flutter test test/terminal_lifecycle_test.dart 2>&1 | tail -10
```
Expected: FAIL — no touch handling; `scrollCalls`/`selStartCalls` stay 0 (and/or fake lacks counters).

- [ ] **Step 3: Guard the mouse `Listener` to mouse-only** — in `lib/ui/terminal_screen.dart`, add at the top of each of `onPointerDown`, `onPointerMove`, `onPointerUp` in the `Listener`:

```dart
              onPointerDown: (e) {
                if (e.kind != PointerDeviceKind.mouse) return; // touch handled by GestureDetector
                // ... existing body ...
              },
```
(Apply the same `if (e.kind != PointerDeviceKind.mouse) return;` to `onPointerMove` and `onPointerUp`. `onPointerSignal` is wheel = mouse only; leave it.)

- [ ] **Step 4: Add touch state + fling** — in `_TerminalScreenState`, add fields:

```dart
  double _touchScrollAccum = 0;
  Timer? _flingTimer;
```

and a scroll helper that mirrors the wheel logic for one line of delta:

```dart
  void _touchScrollBy(double dy) {
    _touchScrollAccum += dy;
    final lines = _touchScrollAccum ~/ _metrics.height;
    if (lines == 0) return;
    _touchScrollAccum -= lines * _metrics.height;
    // Dragging content down (positive dy) reveals older lines → scroll up.
    final up = lines > 0;
    final n = lines.abs();
    if (anyMouse(_grid.modeFlags)) {
      for (var i = 0; i < n; i++) {
        _reportMouse(Offset.zero, 0, up ? MouseAction.scrollUp : MouseAction.scrollDown);
      }
    } else if (_grid.modeFlags & kModeAltScreen != 0) {
      final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
      for (var i = 0; i < n; i++) {
        _pty?.write(Uint8List.fromList(arrow));
      }
    } else {
      _client?.scrollLines(up ? n : -n);
    }
  }

  void _stopFling() {
    _flingTimer?.cancel();
    _flingTimer = null;
  }
```

- [ ] **Step 5: Wrap the child in a touch `GestureDetector`** — in `build`, wrap the existing `Stack` (the `Listener`'s `child`) with a `GestureDetector` restricted to touch:

```dart
            child: GestureDetector(
              supportedDevices: const {PointerDeviceKind.touch},
              behavior: HitTestBehavior.translucent,
              onTapDown: (_) => _stopFling(),
              onTap: () {
                _focus.requestFocus();
                if (_client != null) {
                  _client!.binding.selectionClear();
                  _client!.refreshView();
                }
              },
              onVerticalDragStart: (_) {
                _stopFling();
                _touchScrollAccum = 0;
              },
              onVerticalDragUpdate: (e) => _touchScrollBy(e.delta.dy),
              onVerticalDragEnd: (e) {
                var v = e.primaryVelocity ?? 0; // px/s; +down
                if (v.abs() < 200) return;
                _flingTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
                  v *= 0.92; // decay
                  if (v.abs() < 40) {
                    _stopFling();
                    return;
                  }
                  _touchScrollBy(v * 0.016);
                });
              },
              onLongPressStart: (e) {
                _stopFling();
                _focus.requestFocus();
                if (_client == null) return;
                final (r, c, rh) = _cellAt(e.localPosition);
                _client!.binding.selectionStart(r, c, rh, 0);
                _selecting = true;
                _refreshSelection();
              },
              onLongPressMoveUpdate: (e) {
                if (_client == null) return;
                final (r, c, rh) = _cellAt(e.localPosition);
                _client!.binding.selectionUpdate(r, c, rh);
                _refreshSelection();
              },
              onLongPressEnd: (e) {
                if (_client == null) return;
                _selecting = false;
                _primary = _client!.binding.selectionText() ?? '';
              },
              child: Stack(
                children: [
                  // ... existing CustomPaint + overlay + search bar ...
                ],
              ),
            ),
```

- [ ] **Step 6: Cancel the fling on dispose** — in `dispose()`, add `_flingTimer?.cancel();` near `_blinkTimer?.cancel();`.

- [ ] **Step 7: Run to verify it passes + full suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -6
```
Expected: analyze clean; all green. If the touch drag test is flaky on velocity, assert on `scrollCalls > 0` after `moveBy` only (the move itself triggers `_touchScrollBy`).

- [ ] **Step 8: Commit**

```bash
git add lib/ui/terminal_screen.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): touch input — one-finger scroll + long-press select

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Acceptance gate

**Files:**
- Create: `docs/superpowers/plans/2026-05-28-plan2gjh-findings.md`
- Modify: `flutter_alacritty.toml.example` (document the new search colors)

- [ ] **Step 1: Document the new config keys** — append to `flutter_alacritty.toml.example`:

```toml

[colors.search.matches]
background = "#ac4242"
foreground = "#181818"

[colors.search.focused_match]
background = "#f4bf75"
foreground = "#181818"
```

- [ ] **Step 2: Full acceptance run**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
(cd rust && cargo test 2>&1 | tail -6)
flutter build linux --debug 2>&1 | tail -3   # ensure dylib current for native tests
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -6
```
Expected: cargo green; build ok; analyze clean; flutter test green.

- [ ] **Step 3: Manual smoke (Linux + touch device/emulator)** — record results in findings:
  - Search: `Ctrl+Shift+F`, type a regex, matches highlight (focused in gold), `Enter`/`Shift+Enter` jump & scroll into view, `Esc` closes; invalid regex highlights nothing.
  - Box-drawing: a `tmux`/`vim` frame with mixed/dashed glyphs renders without font fallback for U+2500–256C.
  - Touch: one-finger drag scrolls (with fling), long-press+drag selects, tap clears; mouse wheel/drag still work.

- [ ] **Step 4: Write findings** — `docs/superpowers/plans/2026-05-28-plan2gjh-findings.md`: what shipped per phase, the new FLAG bits + `engine_full_snapshot_searched` protocol, the additive search-color config, manual results, deferred items (live-output re-highlight during active search uses next snapshot; fling constants).

- [ ] **Step 5: Commit**

```bash
git add flutter_alacritty.toml.example docs/superpowers/plans/2026-05-28-plan2gjh-findings.md
git commit -m "docs: sample search colors + Plan 2G/2J/2H acceptance findings

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Acceptance Criteria

- [ ] **2G:** `Ctrl+Shift+F` opens a bottom search bar; typing a regex highlights matches (focused match in a distinct color); `Enter`/`Shift+Enter` move focus and scroll the match into view; `Esc`/close clears; invalid regex highlights nothing and never crashes. Rust `search_*` + `full_snapshot_searched` tested; search colors config-driven (alacritty defaults), additive schema (old configs still load).
- [ ] **2J:** all U+2500–256C mixed light/heavy and single/double junctions/corners render programmatically; dashed lines (2504–250B, 254C–254F) render as N-segment dashes; new box-drawing tests pass.
- [ ] **2H:** touch one-finger drag scrolls (fling inertia), long-press(+drag) selects, tap clears; mouse `Listener` path is touch-guarded and unchanged for the mouse.
- [ ] No regressions; `flutter analyze` clean; `cargo test` + `flutter test` green (after `flutter build linux --debug`).

---

## Self-Review

**Spec coverage:** §3 (2G) → Tasks 1–5. §4 (2J) → Task 6. §5 (2H) → Task 7. §2 locked decisions: search engine/colors → Tasks 1–2; opaque highlight → Task 3; touch model + device split → Task 7; box scope → Task 6; additive config → Task 2 (+ Task 8 example). §7 error handling: invalid regex → Task 1 (`search_set` false) + Task 5 (`_searchChanged`); zero matches → `search_step` false; malformed config color → reuses 2F per-field fallback; fling cancel → Task 7. §8 testing → each task's tests + Task 8 manual. §9 risks: `&mut` snapshot resolved (Task 1 borrow order note); perf (visible-region iter); gesture arena (Task 7 long-press vs drag); fling decay (Task 7).

**Placeholder scan:** none — every code step has full code. The one judgment call (`longPressAt` vs manual gesture) is spelled out with the fallback.

**Type consistency:** `FLAG_MATCH`/`FLAG_MATCH_CURRENT` (Rust) ↔ `kFlagMatch`/`kFlagMatchCurrent` (Dart) = 1<<9 / 1<<10. `EngineBinding` gains `searchSet/Next/Prev/Clear` + `fullSnapshotSearched` — implemented on `FrbEngineBinding` (Task 4) and all test fakes (Tasks 4/5/7). `SearchColors{matchBg,matchFg,focusedBg,focusedFg}` used identically in painter (Task 3) and screen (Task 5). `DashOp(a,b,width,segments)` defined (Task 6 Step 3), built (Step 4), painted (Step 5), asserted (Step 1). `refreshView`/`_searchActive` defined in Task 4, used in Tasks 4/7.
