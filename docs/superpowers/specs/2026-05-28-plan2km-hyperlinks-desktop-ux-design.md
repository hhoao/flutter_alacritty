# flutter_alacritty Plan 2K·2M — Hyperlinks & Desktop UX Cluster

**Date:** 2026-05-28
**Status:** Design approved, pending spec review
**Branch:** `feature/km-hyperlinks-desktop-ux` (off `main` @ bcc2b56)

One spec, **five phases**, each its own commit (the 2D / 2GJH pattern):

- **2K — hyperlinks**: OSC 8 + URL auto-detect + Ctrl+click to launch.
- **2M phase A — font zoom**: `Ctrl+=`/`Ctrl+-`/`Ctrl+0`.
- **2M phase B — file drag-and-drop**: dropped paths inserted as bracketed paste.
- **2M phase C — right-click context menu**: gnome-terminal-style (plain right-click = menu; Shift+right-click = original logic).
- **2M phase D — visual bell**: config-driven flash overlay.

---

## 1. Goal & Non-Goals

**Goal.** Make a typical desktop workflow feel natural in the terminal: click `gh`/`ls --hyperlink`
output to open URLs, zoom the font, drop files into the prompt, hit right-click for a familiar
menu, and see the bell instead of just hearing it. Every piece either reuses existing infrastructure
(2G's `RegexIter` for URL hints, 2D's selection/paste paths, 2F's additive config schema, the
existing `Listener`+`GestureDetector` split) or layers a small new piece on top.

**Non-goals (explicitly deferred to later sub-projects):**
- OSC 7 cwd tracking, OSC 52 GET (read clipboard from program), OSC 4/10/11 dynamic palette, OSC 9/777
  desktop notifications — protocol completeness pass (2N).
- Configurable key bindings, shell/cwd/env overrides, window padding/opacity/decorations, cursor color
  override, separate bold/italic font families, live config reload — (2O).
- IME preedit composition rendering (CJK input methods) — (2L). Important for Chinese users but
  needs its own design surface (where to draw the candidate strip, how to commit text).
- tabs/splits, SSH, WASM, sixel/kitty graphics, ligatures, vi-mode, hold-on-exit policy.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Hyperlink storage | Engine interns URIs: `HashMap<String,u32>` id table + `Vec<String>` reverse lookup. `CellData` carries `hyperlink_id: u32` (0 = none). Avoids serializing the same URI per cell (a typical `ls --hyperlink` line repeats one URI across many cells) |
| URL auto-detect | Fixed regex `(?:https?\|ftp\|file)://[^\s]+` (alacritty's default hints pattern subset). Scanned over the **visible region only** during `engine_full_snapshot_searched` (already a `&mut self` snapshot path — reuse). Matched cells get the same interned `hyperlink_id` as OSC 8 cells; both flagged `FLAG_HYPERLINK` |
| Click trigger | **Ctrl + left-click** on a hyperlink cell launches the URI via `url_launcher` (cross-platform; we target Linux first). `Shift+left-click` keeps the existing "override app mouse, start selection" semantics. Hover on a hyperlink cell changes cursor to `SystemMouseCursors.click` via `MouseRegion` |
| Hint colors | `[colors.hints.start]` (alacritty schema): defaults `background = "#f4bf75"`, `foreground = "#181818"`. We use `start` (alacritty's "head" of a multi-part hint) since our matches are single-segment. Additive — old configs unaffected |
| Font zoom | Runtime-only (config sets the initial size; `Ctrl+=`/`Ctrl+-` adjusts session-wide; `Ctrl+0` resets to config value). Step `±1.0`, clamp `[6.0, 72.0]`. Not persisted — alacritty same |
| Drag-drop | Dropped file absolute paths are shell-quoted (single-quoted if they contain unsafe chars), joined with spaces, and written via the existing `pasteBytes(text, modeFlags)` so bracketed-paste applies when the program enabled it. Multi-file → space-joined (alacritty match) |
| Right-click menu | gnome-terminal style: **plain right-click** (no Shift) opens a context menu at the click position; **Shift+right-click** preserves the existing path (override-app-mouse local selection OR forward button 2). Menu items: Copy / Paste / Open Hyperlink / Copy Hyperlink Address / Search… — items shown conditionally on selection + hyperlink-under-cursor |
| Visual bell | `[bell]` config section (alacritty schema): `color = "#ffffff"`, `duration = 0` (ms; **0 = disabled**, alacritty default), `animation = "linear"` (we implement only linear fade-out for now; the field is accepted for forward-compat with alacritty values). On `EngineEvent::Bell`, a full-screen `IgnorePointer(AnimatedOpacity(Container(color)))` overlay fades out over `duration` ms |
| Library boundary | All new config (`[colors.hints.start]`, `[bell]`) is additive. `TerminalConfig.defaults()` includes the new sections; `fromTomlString` falls back per-field. New `desktop_drop` and `url_launcher` packages are app-level; a library consumer of `TerminalScreen` keeps everything except they'd need `runApp` / `MaterialApp` for the menu's `showMenu` (no change vs status quo) |

## 3. Phase 1 — Hyperlinks (2K)

### 3.1 Rust (`engine.rs`, `api/terminal.rs`)

`TerminalEngine` gains:
```rust
hyperlinks: Vec<String>,                    // index = id - 1; id 0 = no hyperlink
hyperlink_ids: HashMap<String, u32>,        // URI -> id (intern)
hint_regex: RegexSearch,                    // built once with the fixed URL pattern
```

`CellData` gains `pub hyperlink_id: u32` (0 = none).

New `FLAG_HYPERLINK = 1 << 11` (Dart mirror: `kFlagHyperlink`).

In `cell_data(&self, cell)`:
- If `cell.hyperlink()` is `Some(h)` → look up / insert `h.uri()` → set `hyperlink_id` and `FLAG_HYPERLINK`.

In `engine_full_snapshot_searched` (already a `&mut self` path), after the search-match pass, add a
**hint pass**: `RegexIter::new(top, bottom, Direction::Right, &term, &mut self.hint_regex)` collects
URL matches; for each match range, intern the matched substring as a hyperlink id and OR `FLAG_HYPERLINK`
+ the id onto each cell in range. (This means a cell either has an OSC 8 hyperlink — already set —
or gets one from the auto-detect pass; OSC 8 wins if both apply because OSC 8 is processed first.)

`engine_resolve_hyperlink(id: u32) -> Option<String>` — sync FRB getter returning the URI; called
from Dart on click. Out-of-range id → `None`.

The `hint_regex` is compiled once at engine construction with the fixed pattern; build failure (which
shouldn't happen for a vetted constant) is caught and the engine still works — hint pass simply skips.

Catch_unwind wrappers in `api/terminal.rs` unchanged in spirit (new fns wrapped the same way).

### 3.2 Dart

- `cell_flags.dart`: `kFlagHyperlink = 1 << 11` + `isHyperlink(int flags)`.
- `mirror_grid.dart`: `LineCells` + `MirrorGrid` storage gain a `hyperlinkId: Int32List` lane,
  `int hyperlinkIdAt(row, col)` accessor. `_ensureSize` initializes with zeros. `apply()` writes the
  lane like the others (with the same partial-update length-guard).
- `terminal_painter.dart`: a cell with `kFlagHyperlink` paints an underline (one-pixel line at the
  decoration-Y baseline) and applies an opaque fg+bg override to `hintColors` (same pattern as
  `_withSearch` for matches; focused-match wins > search match > hyperlink, in that precedence).
- `terminal_config.dart`: `TerminalColors` gains `hintStartFg`/`hintStartBg`; defaults
  `0x181818`/`0xF4BF75`. `fromTomlString` reads `[colors.hints.start] foreground/background`.
- `engine_binding.dart`: `String? resolveHyperlink(int id)` passthrough.
- `terminal_engine_client.dart`: `String? resolveHyperlink(int id) => _binding.resolveHyperlink(id);`
  (no snapshot side-effect).
- `terminal_screen.dart`:
  - Wrap `CustomPaint` in a `MouseRegion` whose `cursor` is `SystemMouseCursors.click` when the
    pointer's local position maps to a cell with `kFlagHyperlink`, else `defer`.
  - `Listener.onPointerDown`: when `event.kind == mouse` AND primary button AND `Ctrl` is held AND
    the click cell has `kFlagHyperlink` → resolve URI via client → `launchUrl(Uri.parse(uri))`
    (`url_launcher`). Don't start a selection.
- `pubspec.yaml`: `url_launcher: ^6.3.0`.

### 3.3 Tests

- Rust: a cell emitted under `\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\` carries
  `FLAG_HYPERLINK` and a non-zero `hyperlink_id`; `engine_resolve_hyperlink(id)` returns the URI.
  Auto-detect: feeding `"see https://x.io/page"` to the engine and calling `full_snapshot_searched`
  marks the URL cells with `FLAG_HYPERLINK` and a fresh id; `resolve_hyperlink(id)` returns the
  URL substring.
- Dart unit: `applySearchOverride`-style helper extended with hyperlink precedence; defaults test for
  the new colors; `fromTomlString` reads `[colors.hints.start]`.
- Widget test (fake binding): click on a `kFlagHyperlink` cell with `Ctrl` held → a recording fake's
  `launchUrl` (injected via a small `UrlLauncher` seam) is called with the cell's URI.

## 4. Phase 2 — Font zoom

Only `terminal_screen.dart`.

- Convert `_metrics`/`_glyphs`/`_grid`'s declarations from `late final` to plain `late` (re-buildable),
  guarded by a `_rebuildMetrics()` helper that disposes the old glyph cache (calling a new
  `GlyphCache.dispose()` that clears the LRU map) and constructs new ones with the current `_fontSize`.
- Add `double _fontSize` initialized from `_config.font.size`.
- `_onKey` (after the Ctrl+Shift+F branch, before the existing Ctrl+Shift+C/V) intercepts:
  - `Ctrl+=` / `Ctrl++` (LogicalKeyboardKey.equal with Shift, or `add` on numpad) → `_setZoom(_fontSize + 1.0)`
  - `Ctrl+-` → `_setZoom(_fontSize - 1.0)`
  - `Ctrl+0` → `_setZoom(_baseFontSize)` (= `_config.font.size`)
- `_setZoom(double v)`: `clamp(6, 72)`, then if changed → `setState(() { _fontSize = v; _rebuildMetrics(); })`.
- Engine `resize` is **not** called — only the *visible* font changes; cell count stays the same
  unless the layout constraints change (handled by the existing `_ensureStarted` resize path on the
  next frame).

Tests: a widget test pumps a TerminalScreen, sends `Ctrl+=` once, asserts `_metrics.height` grew (via
the painter's `cellHeight` constructor arg readable from the inflated `TerminalPainter` widget).

## 5. Phase 3 — Drag-and-drop

Only `terminal_screen.dart` (+ `desktop_drop`).

- Wrap the existing `Listener`'s child with `DropTarget(onDragDone: _onDrop, child: ...)` from
  `desktop_drop: ^0.4.4` (mature, cross-platform desktop, Linux supported).
- `_onDrop(DropDoneDetails details)`:
  - For each `details.files`, take `f.path` (absolute), shell-quote if it contains any of
    `[' ', '\t', '\'', '"', '$', '`', '\\', ...]` (use a small `_shellQuote(String) → String`).
  - Join with spaces.
  - `_pty?.write(pasteBytes(joined, modeFlags: _grid.modeFlags))` — bracketed-paste wraps it when
    `kModeBracketedPaste` is set, otherwise raw bytes (same as Ctrl+Shift+V).
- No visual highlight on hover (YAGNI; can add later if requested).
- `pubspec.yaml`: `desktop_drop: ^0.4.4`.

Tests: a widget test invokes `_onDrop` with `DropDoneDetails([XFile.fromData(..., path: '/tmp/with spaces')])`
and asserts `_pty.writes` contains a single-quoted path inside bracketed-paste markers.

## 6. Phase 4 — Right-click context menu

Only `terminal_screen.dart`.

- In `Listener.onPointerDown`, when `event.kind == mouse` AND `event.buttons & kSecondaryButton != 0`:
  - **If Shift is held** → fall through to the existing button-2 path (forward to program in mouse
    mode, or local logic).
  - **Else** → call `_showContextMenu(event.localPosition, event.position)`:
    - Build `List<PopupMenuEntry>` conditional on state:
      - `Copy` enabled if `_client!.binding.selectionText()` is non-null+non-empty.
      - `Paste` always enabled.
      - `Open Hyperlink` + `Copy Hyperlink Address` shown only if the click cell has `kFlagHyperlink`
        (look up URI via `client.resolveHyperlink(grid.hyperlinkIdAt(row, col))`).
      - `Search…` always enabled (opens search bar).
    - Use Flutter's `showMenu(context: ..., position: RelativeRect.fromLTRB(global.dx, global.dy, ...))`.
  - Suppress the existing button-2 transmission for this click (we own it).
- The menu items dispatch the same code paths as Ctrl+Shift+C/V/F + `launchUrl` + clipboard
  `Clipboard.setData`.

Tests: a widget test sends a secondary-button pointer-down without Shift → `showMenu` produces a
visible menu (assert `find.text('Copy')` etc.); with Shift → no menu, the existing `_reportMouse`
button-2 fake records a call.

## 7. Phase 5 — Visual bell

- `terminal_config.dart`: new `BellConfig { color: int, duration: int /* ms */, animation: String }`
  with `defaults()` = `(color: 0xFFFFFF, duration: 0, animation: "linear")`. `fromTomlString` reads
  `[bell]`. `TerminalConfig` gets a `bell` field + `copyWith`.
- `terminal_screen.dart`:
  - `late final AnimationController _bellCtrl = AnimationController(vsync: this, duration: Duration(milliseconds: _config.bell.duration));`
    (uses `SingleTickerProviderStateMixin` — new mixin on the state class).
  - In `_flashBell` (already invoked by `EngineEvent::Bell`): play audio (unchanged), AND if
    `_config.bell.duration > 0` then `_bellCtrl.forward(from: 1.0)` (i.e. start at full opacity,
    animate to 0).
  - Stack's topmost child: `IgnorePointer(child: FadeTransition(opacity: _bellCtrl, child: ColoredBox(color: cfg.bell.color)))`.
- `dispose`: `_bellCtrl.dispose()`.
- The non-linear `animation` field is parsed but ignored for now (linear only); accepting it keeps
  alacritty TOML files copy-paste compatible.

Tests: a unit test on `BellConfig.fromTomlString` defaults + parsing; a widget test triggers
`_flashBell` with a non-zero duration → asserts the controller is animating.

## 8. Components / files (by phase)

```
P1 hyperlinks
  rust/src/engine.rs                hyperlinks / hyperlink_ids / hint_regex; cell_data sets id;
                                      full_snapshot_searched hint pass; resolve_hyperlink
  rust/src/api/terminal.rs          engine_resolve_hyperlink (regen FRB)
  lib/src/rust/**                   (regen)
  lib/render/cell_flags.dart        kFlagHyperlink + isHyperlink
  lib/render/mirror_grid.dart       +hyperlinkId lane (+ accessor + ensureSize init)
  lib/render/terminal_painter.dart  hyperlink underline + hint color override (precedence below
                                      search/selection)
  lib/config/terminal_config.dart   TerminalColors +hintStartFg/Bg, fromTomlString reads
                                      [colors.hints.start]
  lib/engine/engine_binding.dart    resolveHyperlink passthrough
  lib/engine/terminal_engine_client.dart  resolveHyperlink passthrough
  lib/ui/terminal_screen.dart       MouseRegion cursor; Ctrl+click handler in Listener.onPointerDown
  pubspec.yaml                      + url_launcher
P2 font zoom — lib/ui/terminal_screen.dart, lib/render/glyph_cache.dart (+dispose)
P3 drag-drop — lib/ui/terminal_screen.dart; pubspec (+desktop_drop)
P4 right-click menu — lib/ui/terminal_screen.dart
P5 visual bell — lib/config/terminal_config.dart (+BellConfig); lib/ui/terminal_screen.dart
                  (mixin + controller + fade overlay)
```

## 9. Error handling

- **Bad URI from OSC 8 / regex match**: `Uri.parse` is forgiving; `launchUrl` returns `false` on
  failure (no scheme handler) — we ignore the result silently. Optionally `debugPrint`.
- **resolveHyperlink with stale id** (engine restart between snapshot and click): returns `None` → no
  launch, silent.
- **Drop with no `path` on `XFile`** (web/mobile platforms returning no path): skip, log.
- **Bell controller during exited state**: `_flashBell` already guarded by `_status == running` via
  the existing `_status` machine? — actually it's invoked from `pumpEvents` which only runs while
  client is alive. Safe.
- **`showMenu` on transient context**: standard Flutter API; closes on dismiss.
- **Font zoom past clamp**: `_setZoom` clamps silently; no popup.

## 10. Testing & acceptance

**Rust:** OSC 8 cell carries flag + id; auto-detect URL produces flag + id; both resolve via
`resolve_hyperlink`; out-of-range id → `None`.

**Dart unit:** `TerminalColors` defaults + `fromTomlString` for hint + bell; `BellConfig` defaults
+ parse.

**Widget (fake binding):**
- Ctrl+click on a hyperlink cell → injected URL launcher invoked with the URI.
- Plain right-click → context menu appears; menu items dispatch correct handlers.
- Shift+right-click → no menu; button-2 path fires (existing fake spy).
- `Ctrl+=` increases `_metrics.height`; `Ctrl+0` returns to base.
- DropTarget callback with a multi-file payload → `_pty.writes` contains the joined+quoted bytes
  inside bracketed-paste markers when `kModeBracketedPaste` is set.
- `_flashBell` with `duration > 0` → animation controller progresses; with `duration == 0` → no
  controller activity.

**Manual smoke (Linux):**
- `ls --hyperlink=auto` in a hyperlinked directory → URLs underline in gold; Ctrl+click opens xdg-open.
- Type a URL into the terminal; Ctrl+click it → opens.
- `Ctrl+=`/`Ctrl+-`/`Ctrl+0` — visible zoom.
- Drag a file with spaces in the name from a file manager → path appears at the prompt, quoted.
- Right-click → menu; click Copy/Paste/Open Hyperlink → correct action.
- `printf '\a'` with `bell.duration = 200` → flash visible; with `0` → only audio.

**Regression:** the existing suite passes; after Rust/FRB change, `flutter build linux --debug`
before `flutter test` (2F lesson).

## 11. Risks & open questions

- **Hyperlink precedence**: a cell carrying both an OSC 8 hyperlink and a search match — the
  current match's opaque fg+bg override takes precedence over the hint override (focus > match >
  hyperlink). Documented in the painter's `_withSearch` extension. Manual smoke verifies a
  search-while-hyperlinks-on-screen looks right.
- **`hint_regex` perf**: scanning the visible viewport (~50×200 cells) with a small URL regex on
  every `full_snapshot_searched` is cheap; spot-check with `tail -f /var/log/syslog`-style traffic.
- **`url_launcher` on Linux**: requires `xdg-utils` (present on most desktops); fallback handled by
  the package. We don't bundle.
- **`desktop_drop` and Wayland**: should work via GTK on Linux; Wayland-specific paths tested via
  the package's own CI. If a user reports Wayland flakes we revisit.
- **Font-zoom rebuild cost**: every `Ctrl+=` rebuilds the glyph cache from scratch. Glyph cache is
  capped at 4096 entries; cold rebuild costs ~one-frame of layout work. Acceptable for a manual,
  low-frequency action.
- **Menu vs button-2 race**: clicking right-button while a program is in mouse mode currently
  forwards button 2 to the program. We're now *consuming* plain right-clicks for the menu —
  programs that wanted right-click need `Shift+right-click` instead. Documented + matches gnome-terminal.
- **`alacritty` `bell.animation` curves**: we accept the field for compat but render linear-fade
  only. Adding the full curve set (`EaseOutExpo` etc.) is a follow-up if requested.
