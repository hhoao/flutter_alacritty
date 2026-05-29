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

## Code review (pre-merge) + fixes

Pre-merge review (subagent) on `main..f2c0dbb` + submodule `5d350ba..087b19f`. Verdict:
"No / with fixes" — one Critical, four Important, three Minor. Resolved:

- **Critical #1 — submodule codegen drift.** The committed submodule `frb_generated.rs`
  was stale (content hash `-447713057`, missing `engine_reconfigure`, off-by-one sync
  dispatcher); a clean checkout would throw at `RustLib.init()` on the hash mismatch. The
  only thing reconciling it was an *uncommitted* working-tree regen. Fixed: regenerated +
  committed in submodule (`d2b062b`, hash `1837108674`) and bumped the parent pointer
  (`13892d9`). Recommend a CI check that fails when the submodule is dirty after codegen.
- **Important #2 — glyph-cache thrash.** `TerminalStyle` had no value equality and
  `TerminalConfig.style` returns a fresh instance each build, so the view's
  `oldWidget.textStyle != widget.textStyle` guard fired on every unrelated `setState`,
  re-flushing the glyph cache / remeasuring metrics. Fixed: added `==`/`hashCode` to
  `TerminalStyle` (commit `81ad546`).
- **Important #3 — disable idiom.** `action="None"/"ReceiveChar"` were dropped instead of
  removing the matched (default) chord. Fixed: `DisableBindingIntent` sentinel +
  `bindingsToShortcuts` removal; +2 tests.
- **Important #4 — parsed-but-inert config.** `cursor.blink_timeout` now wired
  (`TerminalView.cursorBlinkTimeout`: blink pauses after inactivity, resumes on input;
  blink interval also hot-reloads). `font.offset`/`glyph_offset` documented as
  accepted-but-inert (deferred) in `terminal_config.dart`.
- **Important #5 — missing Dart integration tests.** Added `test/review_fixes_test.dart`:
  pure `hoverCursorFor` (mouse-mode → arrow) unit tests + a hot-reload widget test
  (asserts `engine.reconfigure` called + theme swapped). Extracted `hoverCursorFor` as a
  pure top-level fn for testability.
- **Minor #8** — removed unused import in `terminal_shortcuts_actions_test.dart`.

Post-fix: `flutter test` 204 pass, `cargo test` 42 pass, `flutter analyze` clean.

### Minor — accepted as known limitations (not fixed)

- **#6** Per-style font (`[font.bold]` etc.) only renders a distinct weight when the
  configured `family` is itself a separately-registered family name; a same-family
  "Bold" style won't bold via `fontWeight` in this path. `FontStyleConfig.style` is parsed
  but unused. Document for users; revisit if needed.
- **#7** `window.decorations` accepts any string (host-applied only); no validation to the
  `full|none|transparent|buttonless` set.

## Roadmap

- **2O-a, 2O-b, 2N-b** — delivered on this branch.
- **Hot-reload** — `ConfigLoader.watch` + example `configUpdates` stream.
- **Pre-merge note:** the submodule commits (`…d2b062b`) live on the submodule's `main`,
  unpushed; pushing the parent feature branch must be accompanied by pushing the submodule
  so the recorded pointer doesn't dangle.
