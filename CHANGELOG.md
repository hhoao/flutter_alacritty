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
