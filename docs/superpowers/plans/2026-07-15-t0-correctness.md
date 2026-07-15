# T0 Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make named config knobs truthful, fix CJK glyph vertical metrics (#5), document/lock bell defaults, and add search options (case / whole word / regex / wrap) with SearchBar toggles—without changing library vs host seams.

**Architecture:** Capability seams from the roadmap spec. Config/docs and font offsets stay in Dart; search options need a small `alacritty_terminal` API addition (case flag) plus FRB surface; SearchBar remains an opt-in composable (export it). Bell defaults stay as today’s `TerminalView` behavior.

**Tech Stack:** Flutter/Dart, Rust (`rust_lib_flutter_alacritty`), `alacritty_terminal` (git pin + local patch), flutter_rust_bridge 2.12.

**Spec:** `docs/superpowers/specs/2026-07-15-capability-roadmap-design.md`

---

## Locked decisions (from spec + evidence)

| Knob | Decision |
|------|----------|
| `font.offset` / `glyph_offset` | **Wire** (parse TOML + apply to metrics/paint) |
| `window.opacity` / `decorations` | **Document host-only** + central warn helper |
| `bell.animation` | **Document linear-only** + warn when ≠ `linear` |
| Bell defaults | **Keep** `SystemSound` when `onBell == null`; visual only if `bellDuration > 0` |
| Search options | Engine + controller + SearchBar toggles; defaults below |

**Search option defaults (GNOME-aligned, document departure from Alacritty smart-case):**

| Flag | Default | Meaning |
|------|---------|---------|
| `caseSensitive` | `false` | Always case-insensitive (not Alacritty smart-case) |
| `wholeWord` | `false` | No word-boundary wrap |
| `regex` | `true` | Pass pattern to regex engine (back-compat with today’s always-regex) |
| `wrap` | `true` | Full-buffer search (`max_lines: None`) |

---

## File structure

| File | Responsibility |
|------|----------------|
| `lib/config/terminal_config.dart` | Parse offsets; `warnInertOrHostOnlyKeys()` |
| `lib/render/cell_metrics.dart` | Apply `font.offset` to cell size |
| `lib/render/glyph_cache.dart` / `glyph_atlas.dart` / `terminal_painter.dart` | Apply `glyph_offset`; CJK baseline fix |
| `lib/ui/terminal_bell.dart` (new) | Extract default bell handler (same behavior) |
| `lib/ui/terminal_view.dart` | Call bell helper |
| `lib/ui/search_bar.dart` | Four toggles + export |
| `lib/controller/terminal_controller.dart` | `TerminalSearchOptions` + `searchSet` |
| `lib/engine/*` + `test/fake_binding.dart` | Plumb options |
| `packages/rust_lib_…/rust/src/engine.rs` + `api/terminal.rs` | Search options |
| `opensource/alacritty/alacritty_terminal/…/search.rs` | `RegexSearch::with_case_insensitive` (patch) |
| `docs/library-api.md` | Library vs Host + bell lock + config table |
| `test/*` | Unit / golden / widget coverage |

---

### Task 1: Config warn helper + Library vs Host docs

**Files:**
- Modify: `lib/config/terminal_config.dart`
- Modify: `docs/library-api.md`
- Modify: `flutter_alacritty.toml.example` (bell.animation note if missing)
- Test: `test/terminal_config_test.dart`

- [ ] **Step 1: Write failing tests for warn helper**

Add to `test/terminal_config_test.dart`:

```dart
test('warnInertOrHostOnlyKeys reports window host-only and non-linear bell', () {
  final cfg = TerminalConfig.defaults().copyWith(
    window: const WindowConfig(opacity: 0.9, decorations: 'none'),
    bell: const BellConfig(color: 0xFFFFFF, duration: 0, animation: 'EaseOutExpo'),
  );
  final warnings = cfg.warnInertOrHostOnlyKeys();
  expect(warnings.any((w) => w.contains('window.opacity')), isTrue);
  expect(warnings.any((w) => w.contains('window.decorations')), isTrue);
  expect(warnings.any((w) => w.contains('bell.animation')), isTrue);
});

test('warnInertOrHostOnlyKeys is empty for defaults', () {
  expect(TerminalConfig.defaults().warnInertOrHostOnlyKeys(), isEmpty);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/terminal_config_test.dart --name warnInertOrHostOnlyKeys`  
Expected: FAIL — `warnInertOrHostOnlyKeys` not defined.

- [ ] **Step 3: Implement helper + docs**

On `TerminalConfig`:

```dart
/// Returns human-readable warnings for keys that are host-only or
/// accepted-but-limited. Call after load; example/host may `debugPrint` each.
List<String> warnInertOrHostOnlyKeys() {
  final out = <String>[];
  if (window.opacity != 1.0) {
    out.add('window.opacity is host-only; apply to the native window yourself '
        '(not TerminalView.backgroundOpacity).');
  }
  if (window.decorations != 'full') {
    out.add('window.decorations is host-only; the library does not change '
        'window chrome.');
  }
  if (bell.animation != 'linear') {
    out.add('bell.animation=${bell.animation} ignored; only linear is rendered.');
  }
  return out;
}
```

In `docs/library-api.md`, add sections:

1. **Library vs Host** — copy the catalog table from the roadmap spec.
2. **Bell defaults** — explicit lock: `onBell == null` → `SystemSoundType.alert`; visual flash only when `bellDuration > Duration.zero` (default zero).
3. **Config knobs** — table for offset (wired after Task 2), window (host-only), bell.animation (linear-only).

Call `warnInertOrHostOnlyKeys` from `ExampleTerminalApp` config load (replace or supplement existing window `debugPrint`).

- [ ] **Step 4: Run tests**

Run: `flutter test test/terminal_config_test.dart`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/config/terminal_config.dart docs/library-api.md test/terminal_config_test.dart flutter_alacritty.toml.example lib/example/example_app.dart
git commit -m "docs: lock bell defaults and warn on host-only config keys"
```

---

### Task 2: Wire `font.offset` / `glyph_offset`

**Files:**
- Modify: `lib/config/terminal_config.dart` (TOML parse `[font.offset]` / `[font.glyph_offset]`)
- Modify: `lib/render/cell_metrics.dart`
- Modify: `lib/ui/terminal_view.dart` (pass offsets into metrics / cache / atlas)
- Modify: `lib/render/glyph_cache.dart`, `lib/render/glyph_atlas.dart`, and/or `lib/render/terminal_painter.dart`
- Test: `test/terminal_config_test.dart`, `test/glyph_cache_test.dart` or new `test/font_offset_test.dart`

**Alacritty semantics:** `offset` grows cell width/height; `glyph_offset` shifts glyph bitmap inside the cell.

- [ ] **Step 1: Failing TOML parse test**

```dart
test('parses font.offset and font.glyph_offset', () {
  const toml = '''
[font]
size = 12.0
[font.offset]
x = 1
y = 2
[font.glyph_offset]
x = 3
y = -1
''';
  final c = TerminalConfig.fromTomlString(toml);
  expect(c.font.offsetX, 1);
  expect(c.font.offsetY, 2);
  expect(c.font.glyphOffsetX, 3);
  expect(c.font.glyphOffsetY, -1);
});
```

- [ ] **Step 2: Run — expect FAIL** (fields stay 0; TOML ignored).

- [ ] **Step 3: Parse TOML**

In `fromTomlString` font section, read nested maps (same shape as Alacritty):

```dart
// After reading fontM:
offsetX: dbl(offsetM, 'x', d.font.offsetX),
offsetY: dbl(offsetM, 'y', d.font.offsetY),
// glyph_offset map → glyphOffsetX/Y
```

- [ ] **Step 4: Failing metrics test**

```dart
test('CellMetrics applies font offset', () {
  const style = TextStyle(fontSize: 12, height: 1.0, fontFamily: 'monospace');
  final base = CellMetrics.measure(style);
  final grown = CellMetrics.measure(style, offsetX: 2, offsetY: 4);
  expect(grown.width, closeTo(base.width + 2, 0.01));
  expect(grown.height, closeTo(base.height + 4, 0.01));
});
```

- [ ] **Step 5: Implement measure offset**

```dart
static CellMetrics measure(
  TextStyle style, {
  int sample = 20,
  double offsetX = 0,
  double offsetY = 0,
}) {
  final tp = TextPainter(
    text: TextSpan(text: 'W' * sample, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return CellMetrics(tp.width / sample + offsetX, tp.height + offsetY);
}
```

Wire `TerminalView` measure site to pass `config.font.offsetX/Y`.

- [ ] **Step 6: Apply glyph_offset in paint**

When drawing glyphs (atlas sprite dest rect and `drawParagraph` fallback), add `glyphOffsetX/Y` to the destination origin. Thread offsets from config → `GlyphCache` / `GlyphAtlas` / painter constructors (follow existing `fontSize` / `lineHeight` plumbing in `terminal_view.dart`).

- [ ] **Step 7: Remove “accepted-but-inert” comment** on `FontConfig`; update `library-api.md` config table to “wired”.

- [ ] **Step 8: Run tests**

```bash
flutter test test/terminal_config_test.dart test/font_offset_test.dart
# or whichever files you added
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat: wire font.offset and glyph_offset into cell metrics and paint"
```

---

### Task 3: CJK glyph metrics (#5)

**Files:**
- Investigate/modify: `lib/render/cell_metrics.dart`, `glyph_cache.dart`, `glyph_atlas.dart`, `terminal_painter.dart`
- Test: `test/visual_render_test.dart` and/or new golden under `test/fixtures/`
- Reference: https://github.com/hhoao/flutter_alacritty/issues/5

- [ ] **Step 1: Reproduce with a focused golden**

Add a visual test that paints one row of CJK (e.g. `中文测试`) at fixed font/size on a known background, tagged `visual`. **Bundle a subset CJK font under `test/fixtures/fonts/`** and load via `FontLoader` — do not depend on `/usr/share/fonts/...` so CI is hermetic. Capture golden.

- [ ] **Step 2: Run visual test; inspect failure / ink bounds**

```bash
flutter test --tags visual test/visual_render_test.dart
```

Document in the PR whether gap is: (a) `lineHeight: 1.2` padding, (b) strut vs CJK descent, (c) ASCII `'W'` measure vs CJK paint.

- [ ] **Step 3: Fix vertical alignment**

Preferred minimal fix (pick based on evidence from Step 2):

1. Prefer measuring cell height with a sample that includes CJK + ASCII, **or**
2. Align glyph draw Y so ink sits on a shared baseline inside the strut cell (Alacritty-like), without changing default `lineHeight` unless necessary.

Do not break box-drawing / ASCII goldens — run existing visual + `terminal_painter_test.dart`.

- [ ] **Step 4: Update golden; assert in unit test if possible**

Add a non-visual assertion where feasible (e.g. paragraph height ≤ `cellHeight` + epsilon for CJK codepoint in cache).

- [ ] **Step 5: Run**

```bash
flutter test test/terminal_painter_test.dart test/glyph_cache_test.dart
flutter test --tags visual test/visual_render_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git commit -m "fix: align CJK glyph vertical metrics with cell bounds"
```

---

### Task 4: Bell helper extract + unit coverage

**Files:**
- Create: `lib/ui/terminal_bell.dart`
- Modify: `lib/ui/terminal_view.dart`
- Test: `test/terminal_view_callback_test.dart` or new `test/terminal_bell_test.dart`

- [ ] **Step 1: Failing test — onBell spy / duration zero**

```dart
test('default bell plays sound path via onBell override; zero duration skips flash', () {
  var sounded = false;
  // Pump TerminalView with onBell: () => sounded = true, bellDuration: Duration.zero
  // Trigger engine.bell (via FakeBinding event)
  expect(sounded, isTrue);
  // Assert bell AnimationController value stays 0
});
```

Extend existing bell tests in `terminal_lifecycle_test.dart` / `terminal_view_callback_test.dart` rather than inventing a new harness if possible.

- [ ] **Step 2: Extract helper (same behavior)**

```dart
// lib/ui/terminal_bell.dart
import 'package:flutter/services.dart';

void handleTerminalBell({
  required void Function()? onBell,
  required Duration bellDuration,
  required void Function(Duration duration) flashVisual,
}) {
  if (onBell != null) {
    onBell();
  } else {
    SystemSound.play(SystemSoundType.alert);
  }
  if (bellDuration > Duration.zero) {
    flashVisual(bellDuration);
  }
}
```

`TerminalView._flashBell` calls this. **No default behavior change.**

- [ ] **Step 3: Run callback/lifecycle tests**

```bash
flutter test test/terminal_view_callback_test.dart test/terminal_lifecycle_test.dart
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: extract terminal bell handler without changing defaults"
```

---

### Task 5: `RegexSearch` case flag in alacritty_terminal

**Why:** `RegexSearch::new` always sets `case_insensitive(!has_uppercase)` (smart-case). Explicit `caseSensitive` needs a new constructor. Fields of `RegexSearch` are private — must patch `alacritty_terminal`.

**Files:**
- Modify: `/home/hhoa/git/opensource/alacritty/alacritty_terminal/src/term/search.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/Cargo.toml` (enable `[patch]` to local alacritty **or** point `rev` at a fork commit that includes the patch)
- Test: alacritty_terminal unit tests / new cases in that crate

- [ ] **Step 1: Add API on RegexSearch**

```rust
impl RegexSearch {
    pub fn new(search: &str) -> Result<RegexSearch, Box<BuildError>> {
        let has_uppercase = search.chars().any(|c| c.is_uppercase());
        Self::with_case_insensitive(search, !has_uppercase)
    }

    /// Build DFAs with an explicit case-insensitivity flag (GNOME-style Match Case).
    pub fn with_case_insensitive(
        search: &str,
        case_insensitive: bool,
    ) -> Result<RegexSearch, Box<BuildError>> {
        let syntax_config = SyntaxConfig::new().case_insensitive(case_insensitive);
        // … same DFA setup as current `new`, using `syntax_config`
    }
}
```

Refactor existing `new` body into `with_case_insensitive`.

- [ ] **Step 2: Add alacritty_terminal tests**

- `with_case_insensitive("foo", false)` does not match `FOO`
- `with_case_insensitive("foo", true)` matches `FOO`

Run: `cargo test -p alacritty_terminal search::` from the alacritty repo.

- [ ] **Step 3: Point rust_lib at the patched crate**

**Do not commit an absolute `[patch]` path** (breaks CI). For local hacking only, uncomment the path patch. For committed/CI state: push the alacritty change to a fork and set:

```toml
alacritty_terminal = { git = "https://github.com/<you>/alacritty.git", rev = "<commit-with-with_case_insensitive>" }
```

Or land an upstream PR and bump `rev` to that merge commit. Document the fork/PR link in the rust_lib README until upstream merges.

- [ ] **Step 4: Commit** (alacritty change in its repo; rust_lib dep bump in submodule)

Separate commits per repo as appropriate.

---

### Task 6: Rust search options + engine tests

**Files:**
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs`
- Optionally new: `packages/rust_lib_flutter_alacritty/rust/src/api/search_options.rs` (FRB-visible struct)

- [ ] **Step 1: Define options struct (FRB)**

```rust
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub regex: bool,
    pub wrap: bool,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            case_sensitive: false,
            whole_word: false,
            regex: true,
            wrap: true,
        }
    }
}
```

- [ ] **Step 2: Pattern compile helper**

```rust
fn compile_search(pattern: &str, opt: &SearchOptions) -> Result<RegexSearch, Box<BuildError>> {
    let mut pat = if opt.regex {
        pattern.to_string()
    } else {
        regex_syntax::escape(pattern) // or manual escape if dep unavailable
    };
    // Case-neutral boundaries only — never embed (?i); case comes from SyntaxConfig.
    if opt.whole_word {
        pat = format!(r"(?:(?<=\W)|^)(?:{})(?:(?=\W)|$)", pat);
    }
    RegexSearch::with_case_insensitive(&pat, !opt.case_sensitive)
}
```

Verify the lookaround form works with `regex_automata` in unit tests (fallback: `\b(?:pat)\b` if lookaround is rejected at build time).

Store `SearchOptions` (including `wrap`) on `TerminalEngine` for `search_step`.

- [ ] **Step 3: Update `search_set` / `search_step` (wrap=false must not no-op)**

**Critical:** `Term::search_next` does `max_lines.filter(|m| m + 1 < total_lines())`. Passing `Some(total_lines - 1)` becomes `None` (full wrap) — a no-op. Do **not** use that formula.

Preferred approach — **post-filter wrapped hits** (clear, matches GNOME “stop at end”):

```rust
pub fn search_set(&mut self, pattern: String, opt: SearchOptions) -> bool { … }

fn search_step(&mut self, direction: Direction) -> bool {
    // Always search with max_lines: None (engine finds next hit in buffer order).
    let found = self.term.search_next(re, origin, direction, Side::Left, None);
    match found {
        Some(m) if self.search_wrap || !Self::match_wrapped_past_origin(&m, origin, direction) => {
            self.term.scroll_to_point(*m.start());
            self.current_match = Some(m);
            true
        }
        _ => false,
    }
}
```

Define `match_wrapped_past_origin` so that when `wrap=false`, a match on the “other side” of the buffer relative to `origin` (the classic wrap-around hit) is rejected. Cover with a unit test: pattern appears both above and below the cursor; with `wrap=false` and search downward from the lower region, do not jump to the upper hit.

Alternative (also OK): compute a remaining-line `max_lines` that is **strictly less than** `total_lines - 1` so it survives the filter — only use this if post-filter proves awkward with wide-cell origins; document the inequality in a code comment.

- [ ] **Step 4: FRB API**

```rust
pub fn engine_search_set(
    engine: &mut TerminalEngine,
    pattern: String,
    options: SearchOptions,
) -> bool { … }
```

Keep a thin overload or default only if FRB allows; otherwise always pass options from Dart.

- [ ] **Step 5: Rust unit tests in `engine.rs`**

Extend existing search tests (~1723+):

- literal `regex=false` does not treat `.` as any-char  
- `whole_word` does not match mid-token  
- `case_sensitive`  
- `wrap=false` does not wrap  

Run: `cargo test --manifest-path packages/rust_lib_flutter_alacritty/rust/Cargo.toml`

- [ ] **Step 6: Regenerate FRB**

From repo root (adjust if project docs differ):

```bash
flutter_rust_bridge_codegen generate
```

Commit generated `lib/src/rust/**` and `frb_generated.rs`.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat: add search options to rust terminal engine"
```

(Submodule: commit inside `packages/rust_lib_flutter_alacritty` first, then bump pointer in parent.)

---

### Task 7: Dart engine / controller / fake binding

**Files:**
- Modify: `lib/engine/engine_binding.dart`, `terminal_engine.dart`, `terminal_engine_client.dart`
- Modify: `lib/controller/terminal_controller.dart`
- Modify: `test/fake_binding.dart`
- Test: `test/terminal_controller_test.dart`, `test/engine_bindings_test.dart`

- [ ] **Step 1: Dart options type**

```dart
class TerminalSearchOptions {
  const TerminalSearchOptions({
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = true,
    this.wrap = true,
  });
  final bool caseSensitive;
  final bool wholeWord;
  final bool regex;
  final bool wrap;
}
```

Place in `terminal_controller.dart` or `lib/controller/terminal_search_options.dart` (prefer dedicated file if controller is large). Export from barrel.

- [ ] **Step 2: Plumb `searchSet`**

```dart
bool searchSet(String pattern, {TerminalSearchOptions options = const TerminalSearchOptions()}) {
  _searchPattern = pattern;
  _searchOptions = options;
  final ok = _engine?.searchSet(pattern, options: options) ?? false;
  …
}
```

Update `EngineBinding.searchSet` signature; map to FRB `SearchOptions`.

- [ ] **Step 3: Update FakeBinding**

```dart
TerminalSearchOptions? lastSearchOptions;
bool searchSet(String pattern, {TerminalSearchOptions options = const TerminalSearchOptions()}) {
  lastSearchOptions = options;
  return pattern != '(';
}
```

- [ ] **Step 4: Controller tests**

```dart
test('searchSet forwards options', () {
  final fake = FakeBinding();
  // attach engine with fake…
  controller.searchSet('foo', options: const TerminalSearchOptions(caseSensitive: true, wrap: false));
  expect(fake.lastSearchOptions?.caseSensitive, isTrue);
  expect(fake.lastSearchOptions?.wrap, isFalse);
});
```

- [ ] **Step 5: Run**

```bash
flutter test test/terminal_controller_test.dart test/engine_client_test.dart test/engine_bindings_test.dart
```

Expected: PASS (bindings test may need native lib — follow existing skip patterns).

- [ ] **Step 6: Commit**

```bash
git commit -m "feat: plumb TerminalSearchOptions through controller and engine"
```

---

### Task 8: SearchBar toggles + export + example

**Files:**
- Modify: `lib/ui/search_bar.dart`
- Modify: `lib/flutter_alacritty.dart` (export)
- Modify: `lib/example/example_app.dart`
- Test: new `test/terminal_search_bar_test.dart`

- [ ] **Step 1: Extend `TerminalSearchBar` API**

```dart
class TerminalSearchBar extends StatefulWidget {
  const TerminalSearchBar({
    required this.visible,
    required this.onChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
    this.invalidPattern = false,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = true,
    this.wrap = true,
    this.onCaseSensitiveChanged,
    this.onWholeWordChanged,
    this.onRegexChanged,
    this.onWrapChanged,
    super.key,
  });
  // …
}
```

UI: compact IconButtons or FilterChips for Match case / Whole word / Regex / Wrap. Keep row usable on narrow widths (wrap to second row if needed).

When a toggle changes, call the callback; host rebuilds `onChanged(currentText)` so search recompiles.

- [ ] **Step 2: Widget test**

Pump bar, tap “Match case”, expect `onCaseSensitiveChanged(true)`.

- [ ] **Step 3: Export**

```dart
export 'ui/search_bar.dart';
```

- [ ] **Step 4: Wire example**

`ExampleTerminalApp` holds four bools (or reads from controller), passes into `TerminalSearchBar`, and on any change calls:

```dart
_controller.searchSet(
  pattern,
  options: TerminalSearchOptions(
    caseSensitive: _caseSensitive,
    wholeWord: _wholeWord,
    regex: _regex,
    wrap: _wrap,
  ),
);
```

- [ ] **Step 5: Document in `library-api.md`** — SearchBar is opt-in composable; options live on controller.

- [ ] **Step 6: Run**

```bash
flutter test test/terminal_search_bar_test.dart test/terminal_lifecycle_test.dart
flutter test test/ --exclude-tags benchmark --exclude-tags visual
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat: add search option toggles to TerminalSearchBar"
```

---

### Task 9: CHANGELOG + final verification

**Files:**
- Modify: `CHANGELOG.md`
- Optionally bump notes in README features list

- [ ] **Step 1: CHANGELOG under Unreleased / next version**

- Config: font offsets wired; window.* host-only warnings; bell.animation linear-only  
- Fix: CJK vertical metrics (#5)  
- Feat: search options + SearchBar toggles  
- Docs: Library vs Host, bell defaults lock  

- [ ] **Step 2: Full verification**

```bash
flutter analyze
flutter test test/ --exclude-tags benchmark --exclude-tags visual
flutter test --tags visual
cargo test --manifest-path packages/rust_lib_flutter_alacritty/rust/Cargo.toml
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs: changelog for T0 correctness track"
```

---

## Risk notes

1. **alacritty patch publish path** — CI must not depend on a laptop absolute `[patch]` path. Use a fork `rev` or merged upstream commit before release.
2. **Search default case behavior** — switching from smart-case to always-insensitive when `caseSensitive: false` is intentional; call it out in CHANGELOG.
3. **CJK fonts in CI** — bundle a fixture font if runners lack Noto CJK.
4. **FRB regen** — keep `flutter_rust_bridge = "=2.12.0"`; regenerate both Dart and Rust sides in one commit with the submodule.

## Out of scope (later tracks)

- Performance (T1), Semantics (T2), copy-as-HTML (T3), Vi/hints/SSH (T4)
- Implementing Penner `bell.animation` curves
- Applying `window.opacity` to native window chrome
