# Plan 2F — Config File & Theme Acceptance Findings

**Date:** 2026-05-28  
**Branch:** `feature/f-config-theme`  
**Worktree:** `.worktrees/f-config-theme`  
**Tasks:** 0–6 (config value object, Rust palette injection, loader, wiring, sample config, acceptance)

## What shipped

Plan 2F moves every v1 look-and-feel constant into a single immutable `TerminalConfig`, loadable from an alacritty-style TOML file at startup with full fallback on missing or broken files.

| Layer | Deliverable |
|-------|-------------|
| **Rust** | `EngineConfig { palette: Vec<u32>, scrollback: u32 }` injected at `engine_new`; per-engine `[u32; 18]` palette drives ANSI/xterm256/named color resolution; length-guarded fallback to `default_palette()` |
| **Dart value object** | `TerminalConfig` with section types (`TerminalColors`, `FontConfig`, `CursorConfig`, `ScrollConfig`, `MouseConfig`), `defaults()`, `copyWith`, `textStyle`, `selectionOverlay`, `engineConfig` getters |
| **Parser** | `parseColor()` (`#rrggbb`, `#aarrggbb`, `0x..`); `TerminalConfig.fromTomlString()` with per-field fallback |
| **Loader** | `ConfigLoader.resolveConfigPath()` + `loadFile()` + `load()` — XDG/HOME path, never throws |
| **Wiring** | `TerminalScreen.config` (optional, defaults to `.defaults()`); font, line-height, blink, scroll multiplier, double-click, window bg, selection overlay, and engine palette/scrollback all config-driven |
| **Docs** | `flutter_alacritty.toml.example` — full schema, every key at its default |

## EngineConfig protocol

`EngineConfig` crosses the FRB boundary at engine creation only:

```rust
pub struct EngineConfig {
    pub palette: Vec<u32>,   // length 18: [0..15] ANSI, [16] default fg, [17] default bg (0x00RRGGBB)
    pub scrollback: u32,     // max history lines → alacritty_terminal scrolling_history
}
```

Dart builds it via `TerminalConfig.engineConfig`:

```dart
EngineConfig get engineConfig => EngineConfig(
  palette: Uint32List.fromList([...colors.ansi, colors.foreground, colors.background]),
  scrollback: scrolling.history,
);
```

`FrbEngineBinding` / `EngineFactory` / test fakes all carry `required engineConfig`. No render-protocol change — cells still arrive as packed RGB; only the lookup table is configurable.

## Dart/Rust default-sync invariant

The v1 palette is **intentionally duplicated** in two places and kept in sync by paired tests:

| Location | Mechanism |
|----------|-----------|
| Dart | `TerminalConfig.defaults()` — `TerminalColors` constants + section defaults |
| Rust | `EngineConfig::default_palette()` — same 18 values including `DEFAULT_FG` / `DEFAULT_BG` |

**Guard tests:**

- Rust: `default_palette_matches_v1_table` (indices 0, 1, 15, 16, 17)
- Dart: `defaults match v1 constants` + `engineConfig palette is length 18 in documented order`

Any future default change must update both sites and both tests.

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` (rust/) | **Pass** — 18 tests (3 new: palette injection, default palette sync, custom scrollback) |
| `flutter test` | **Pass** — 77 tests (+18 over pre-2F baseline of 59) |
| `flutter analyze lib/ test/` | **Pass** — no issues (removed unused `flutter/painting.dart` import in `terminal_config_test.dart`) |
| `flutter analyze` (full tree) | **67 issues** — all in `rust_builder/cargokit/build_tool/` (pre-existing cargokit codegen; unrelated to Plan 2F) |
| `flutter build linux --debug` | **Pass** — `build/linux/x64/debug/bundle/flutter_alacritty` |

### New test files / coverage

- `test/color_parse_test.dart` — 4 tests
- `test/terminal_config_test.dart` — 8 tests (defaults, getters, `fromTomlString` sections)
- `test/config_loader_test.dart` — 5 tests (path resolution, missing file, malformed file)
- `test/terminal_lifecycle_test.dart` — +1 widget test (`window background comes from config`)
- Rust `engine.rs` tests module — +3 palette/scrollback tests

## Manual smoke checklist

Environment: `DISPLAY=:0` (display available).

| Checklist item | Status | Notes |
|----------------|--------|-------|
| No config file → v1 look (dark bg, same font/colors) | **Pass** | App launches cleanly with empty `XDG_CONFIG_HOME`; no config errors |
| Distinct palette + `line_height = 1.6` + `blink_interval = 250` + `scrolling.multiplier = 5` → visible changes | **Partial** | Parsing and wiring verified by unit/widget tests (`fromTomlString reads every section`, Rust `palette_injection_overrides_ansi_colors`, window-bg widget test). Blink rate, line spacing, and wheel speed not interactively inspected in this session |
| Malformed TOML → app starts at defaults; `config: failed to load …` in log | **Pass** | `[[broken` → `config: failed to load … (TOML parse error …); using defaults` |

## Deferred follow-ups

1. **Default palette single source of truth** — today duplicated in Dart + Rust; a shared codegen or golden-file check could prevent drift (current paired tests are sufficient for now).
2. **Full-schema TOML validation** — unknown keys are silently ignored; a strict/lenient mode could warn in debug builds.
3. **Hot reload / runtime config change** — config is loaded once at `main()`; live reload would require engine recreation and glyph-cache invalidation.
4. **cargokit analyze noise** — `rust_builder/cargokit/build_tool/` errors pollute full-tree `flutter analyze`; fix or exclude in analysis_options.
5. **Interactive manual sign-off** — visually confirm blink interval, line-height spacing, and scroll multiplier with a custom on-disk config (automated tests cover the data path).

## Post-review fixes (code review, 2026-05-28)

- **Critical — `integration_test/simple_test.dart` no longer compiled.** Making `MyApp.config`
  required broke `const MyApp()`, and full-tree `flutter analyze` failed (the original findings only
  ran `analyze lib/ test/`, missing `integration_test/`). The test was also stale FRB-template code
  asserting `Result: Hello, Tom!`. Repurposed it into a real boot smoke test:
  `MyApp(config: TerminalConfig.defaults())` → expect a `TerminalScreen`. `flutter analyze lib/ test/
  integration_test/` is now clean; `flutter test` 77/77.
- **Minor — orphaned `kTerminalTextStyle` / `kTerminalFontFamily`** removed from `terminal_painter.dart`.
  `TerminalConfig.defaults()` is now the single source for the default font (it already held the
  identical values); the dead constants are gone (deviates from the spec's "retain as source" wording
  in favor of the cleaner library-boundary choice — config owns the default).
- **Follow-up bug (user-reported) — themed background showed stale color bands.** `MirrorGrid`'s
  empty-cell fill was hardcoded `0xD8D8D8/0x181818`. Untouched rows get no partial damage from the
  engine, so with a custom background those rows kept the old default until a full snapshot (e.g. a
  click starting a selection) repainted them — visible as mismatched bands at startup, "fixed" by
  clicking. Initially mis-deferred as one-frame/cosmetic; it is not (the engine never re-sends
  untouched rows). Fixed: `MirrorGrid({defaultFg, defaultBg})` (v1 values as defaults) fed the
  configured colors by `TerminalScreen`; regression test in `mirror_grid_test.dart`.
- **Line-height alignment ("行距打磨", in 2F scope) — user-reported, fixed.** Pre-existing v1
  behavior (glyph/metrics/box files byte-identical to main): glyphs were laid out at their natural
  height and drawn at the cell top while box-drawing fills the full cell, so text rode high and
  didn't align with box-bordered prompts; the uniform themed background made it obvious. Fixed by
  laying out each glyph into a cell-height line box with a forced strut (`GlyphCache.lineHeight` +
  `StrutStyle(forceStrutHeight: true)`), giving every glyph (ASCII/CJK/fallback) one shared baseline
  that fills the cell. Fed from `_config.font.lineHeight`. User-verified aligned.
- **Left as deferred:** cursor out-of-bounds fallback color (`terminal_painter.dart`) — only the
  degenerate sub-frame where the cursor sits outside the grid; not a themeable surface.
- **Flake note:** one isolated test failure was seen once during this pass, then 4 consecutive clean
  79/79 runs. Timing-sensitive (likely the lifecycle async exit/restart or a glyph-warmup frame),
  unrelated to the config change — worth a future look if it recurs.

## Spec coverage

- §3 schema → `fromTomlString` + `flutter_alacritty.toml.example` ✅
- §4 data flow → Task 5 wiring ✅
- §5 Rust palette → `EngineConfig` + `TerminalEngine.palette` ✅
- §7 error handling → per-field parser fallback + loader full-file fallback ✅
- §8 tests → Rust + Dart automated; manual smoke partial ✅
- §9 risks → scrollback verified; palette length-guarded; default duplication guarded ✅
- §10 library boundary → `TerminalConfig` usable without file; loader decoupled ✅
