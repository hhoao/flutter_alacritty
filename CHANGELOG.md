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
