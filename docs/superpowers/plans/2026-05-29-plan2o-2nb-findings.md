# Plan 2O + 2N-b — Implementation findings

**Date:** 2026-05-29  
**Branch:** `feature/plan2o-2nb-config-osc`

## Per-commit status

| Commit | SHA | Tests | Notes |
|--------|-----|-------|-------|
| 1 — config schema + parser | `b9e1d4d` | PASS (+4 config tests) | `[[keyboard.bindings]]` parsed via `keyboard.bindings` array |
| 2 — shell → PTY | `c9f9e20` | PASS (+2 pty resolver tests) | `resolveShellSpec` pure; `~` expansion |
| 3 — keybindings | `defd8dd` | PASS (+7 shortcut/keybinding tests) | `bindingsToShortcuts` needs activator normalization for override semantics |
| 4 — OSC pump-through | `71a10ac` | PASS (+1 osc52 test); cargo +40 | ClipboardLoad + TextAreaSizeRequest queues mirror ColorRequest pattern |
| 5 — cosmetics | `2832de4` | PASS | `theme` cursor colors were wired in commit 1; commit 5 added test + glyph families |
| 6 — hot-reload | `e985a1f` | PASS (+2 watch tests) | `engine.reconfigure` uses full `EngineConfig` each time |

**Final:** `flutter test` 198 passed; `cargo test` 42 passed.

## API / integration notes

- **`Term::clear_screen(ClearMode::Saved)`** — used for `clear_history`; public via `Handler` trait on path-dep `alacritty_terminal`.
- **Semantic selection `kind`** — `1` = Semantic in `selection_start` tests.
- **`Term::set_options`** — emits Title/ResetTitle; benign refresh (no title clobber observed in manual smoke).
- **FRB content hash** — after Rust changes run `flutter_rust_bridge_codegen generate`, `cargo build`, then `flutter build linux --debug` so `engine_bindings_test` loads a matching `.so`.
- **OSC 12 vs config cursor color** — live snapshot `cursorColor` (OSC 12) wins in `cursorInk`; static `[colors.cursor]` feeds theme defaults when unset.
- **`bindingsToShortcuts` mode field** — parsed and stored on `KeyBinding` but not enforced yet (Vi/Search actions are no-ops anyway).

## Scope corrections (from design §1)

- Cursor shape/blink: already end-to-end via snapshot pull — no new Rust events.
- `MouseCursorDirty`: Dart-only; `anyMouse(modeFlags)` → arrow in `TerminalView._updateHoverCursor`.
- `CursorBlinkingChange`: snapshot pull sufficient; blink phase polish not added.

## Follow-ups (out of scope)

- Native `window.opacity` / `decorations` (host applies; example logs on start).
- Keybinding `mode` gating for AppCursor/AppKeypad/Alt via `mode_flags`.
- Vi/tabs/window actions remain `UnsupportedActionIntent` no-ops.

## Roadmap

- **2O-a, 2O-b, 2N-b** — delivered on this branch.
- **Hot-reload** — `ConfigLoader.watch` + example `configUpdates` stream.
