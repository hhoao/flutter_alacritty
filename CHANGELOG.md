## 2.4.1

### Fix

- **Fix:** Trackpad pan (`PointerPanZoomUpdate`) now reports the hovered cell
  instead of the stale default (1,1), so SGR-mouse TUIs that hit-test scroll
  events from the reported cell (opencode/opentui) scroll their message
  region instead of missing it. Discrete wheels were unaffected.
- **Tests:** Real-engine regression coverage — opencode-style boot sequences
  mirror mouse-mode flags; wheel → SGR 64/65 reports; `PointerScrollEvent`
  and trackpad pan through `TerminalView` emit reports at the hovered cell.

### Diagnostics

- **Feat:** `FLUTTER_ALACRITTY_SCROLL_TRACE=true` enables the scroll pipeline
  trace at runtime (desktop), besides the compile-time
  `TERMINAL_SCROLL_TRACE=true` dart-define (whose `=1` form silently stays
  off — `bool.fromEnvironment` only accepts `"true"`/`"false"`).
- **Feat:** Trace now logs program-scroll routing: destination, mode flags,
  report counts, hovered cell, and the batched PTY bytes.

## 2.4.0

### TUI scroll performance

- **Feat:** Mouse-report TUI wheel via `TuiWheelDistance` +
  `TerminalView.tuiScrollSensitivity` (discrete/notch vs trackpad 1:1).
- **Feat:** Interaction-first PTY drain (~100ms microtask window) and DEC 2026
  synchronized-output present hold on `TerminalEngineClient`.
- **Feat:** Dual present path — CustomPainter (cold) plus Rust-raster →
  `ui.Image` hot path gated by `preferGpuSurface` /
  `FLUTTER_ALACRITTY_GPU=1` (not `FlPixelBufferTexture` yet; ASCII bitmap
  glyphs; mid-cell `scroll_fraction` and selection/search visuals not on
  raster — data path via `refreshView`).
- **Perf:** Dirty-row painter, glyph-atlas LRU, tighter `scroll_fraction`
  damage (partial + overscan); stabilize paint present and keep selection on
  partial damage.
- **Docs:** `docs/library-api.md` scroll/present sections; latency method in
  `docs/superpowers/specs/2026-07-16-tui-scroll-latency-method.md`.
- **Bench:** Loosen `kScrollRefreshVsFullSnapshotMaxRatio` 0.65 → 1.0 — both
  scroll FFI paths are sub-ms so ratio noise flake; cell-count + absolute µs
  ceilings remain the regression gates.

### T0 — Correctness / polish

- **Config:** Wire `font.offset` / `glyph_offset` into cell metrics and paint;
  warn on host-only `window.*` keys (`opacity`, `decorations`, etc.); document
  `bell.animation` as linear-only (other values ignored with a warning).
- **Fix:** Cell height follows **primary font** ascent+descent (Alacritty-style),
  not `max()` over CJK/fallback natural boxes; glyphs are hard-clipped to the
  cell slot so tall outlines cannot spill into the next row
  ([#5](https://github.com/hhoao/flutter_alacritty/issues/5)).
- **Feat:** Search options (case / whole word / regex / wrap) on the Rust engine
  and `TerminalController`, with matching toggles on the opt-in
  `TerminalSearchBar`.
- **Docs:** Library vs Host ownership catalog; bell defaults locked
  (`SystemSound` when `onBell` is null; visual flash only if `bellDuration > 0`).
- **Note:** `case_sensitive: false` is always case-insensitive (not Alacritty
  smart-case).
- **Deps:** Requires [`rust_lib_flutter_alacritty`](https://pub.dev/packages/rust_lib_flutter_alacritty)
  `^0.2.2` (fork-pinned `alacritty_terminal` with `with_case_insensitive`).

## 2.3.2

- Publish CI checks out the `rust_lib_flutter_alacritty` submodule so
  `dart pub publish --dry-run` does not treat the empty gitlink as a
  gitignored tracked path.

## 2.3.1

- Fix pub.dev publish dry-run: move local `rust_lib` path override to
  `pubspec_overrides.yaml`, remove unused analyze warnings, and stop mutating
  `pubspec.yaml` in CI before publish.

## 2.3.0

- **Foreground process state:** `PtyBackend.isForegroundProcessRunning` exposes
  an optional `ValueListenable<bool>` for tab loading indicators while a
  foreground command runs ([#1](https://github.com/hhoao/flutter_alacritty/issues/1)).
  `FlutterPtyBackend` implements it on Unix/Android; Windows returns `null`.
- Depend on [`flutter_pty_new`](https://pub.dev/packages/flutter_pty_new) `^1.0.0`
  instead of `flutter_pty`.
- Publish CI verifies `flutter_pty_new` exists on pub.dev before publishing
  (release order: `rust_lib` → `flutter_pty_new` → `flutter_alacritty`).

## 2.2.1

- **Rust optional for consumers:** `rust_lib_flutter_alacritty` 0.2.1 ships
  Cargokit precompiled binaries (signed GitHub releases). No local Rust needed
  for `flutter build` when artifacts exist for your platform/crate hash.
- New public test helper: `package:flutter_alacritty/testing/rust_lib_loader.dart`
  (local `cargo` → signed download fallback).
- Add `cargokit_options.yaml.example` for forcing precompiled binaries in CI.

- **Android (experimental):** local PTY via `FlutterPtyBackend` — default
  `/system/bin/sh`, app-private `HOME`/cwd through [`ShellDefaults.install`],
  and `path_provider` in the demo `main()`. Override with [`ShellConfig`];
  see `docs/library-api.md`.

## 2.2.0

- Resize v2: single viewport authority, atomic engine+PTY resize, unified scroll
  input with TUI line batching.
- Scrollback: proportional history scrollbar, incremental refresh, edge snap,
  and stabilized wheel/pan/scrollbar races.
- Rendering: GPU glyph atlas, bounded incremental growth, background opacity,
  and incremental scroll-only damage paths.
- Links: `TerminalLinkProvider` seam, overlay decoration/hover/click,
  `primaryTapActivatesLink`, OSC 8–only mode (no default URL regex scan).
- Example app updates and benchmark/visual test tagging via `dart_test.yaml`.
- Requires `rust_lib_flutter_alacritty` **0.2.0**.

## 2.1.0

- **Breaking:** `TerminalView.linkProviders` now defaults to `const []` (no
  automatic URL regex scan on every PTY update). Pass `[UrlLinkProvider()]`
  explicitly to restore clickable `http(s)://` detection. OSC 8 hyperlinks are
  unchanged.
- Library API: `TerminalEngine`, `TerminalController`, `TerminalView` with
  `PtyBackend` wiring; public barrel exports `RustLib` for host `main()`.
- Platform default fonts aligned with VS Code; CJK IME fixes on desktop.
- GNOME-style smooth scrolling, OSC cwd/notifications, hyperlink UX, and
  live color sync via `rust_lib_flutter_alacritty` 0.1.0.

## 1.0.0

- Initial pub.dev release.
- Terminal widget, TOML config, search, selection, and Alacritty-based Rust
  engine via `rust_lib_flutter_alacritty`.
