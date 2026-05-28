# Plan 2G·2J·2H — Search, Box-Drawing, Touch Acceptance Findings

**Date:** 2026-05-28  
**Branch:** `feature/g-search-box-touch`  
**Worktree:** `.worktrees/feature-g-search-box-touch`  
**Spec:** `docs/superpowers/specs/2026-05-28-plan2gjh-search-box-touch-design.md`

## What shipped

| Phase | Deliverable |
|-------|-------------|
| **2G** | Rust `search_set` / `search_next` / `search_prev` / `search_clear` + `full_snapshot_searched`; FRB passthroughs; `kFlagMatch` / `kFlagMatchCurrent` (1<<9 / 1<<10); opaque search-match colors in painter; bottom search bar (`Ctrl+Shift+F`); additive `[colors.search.*]` config |
| **2J** | Mixed light/heavy and single/double junction table rows in `box_drawing.dart`; `DashOp` for U+2504–250B and U+254C–254F |
| **2H** | Touch-only `GestureDetector` (scroll + fling, long-press select, tap clear); mouse `Listener` handlers gated to `PointerDeviceKind.mouse`; touch tap restarts when session exited |

## Search protocol

**Rust flags:** `FLAG_MATCH = 1 << 9`, `FLAG_MATCH_CURRENT = 1 << 10` (Dart `kFlagMatch` / `kFlagMatchCurrent`).

**Snapshot:** While search is active, the client calls `full_snapshot_searched()` (FRB `engine_full_snapshot_searched`) so visible cells get match flags without requiring content damage. Invalid regex → `search_set` returns `false`, no flags set.

**Config (additive):**

```toml
[colors.search.matches]
background = "#ac4242"
foreground = "#181818"

[colors.search.focused_match]
background = "#f4bf75"
foreground = "#181818"
```

Defaults match alacritty; missing sections keep 2F per-field fallback.

## Automated verification

| Check | Result |
|-------|--------|
| `cargo test` (rust/) | **Pass** — 22 tests (4 search tests) |
| `flutter build linux --debug` | **Pass** |
| `flutter analyze lib/ test/ integration_test/` | **Pass** — no issues |
| `flutter test` | **Pass** — 90 tests |

## Manual smoke (Linux)

| Area | Result | Notes |
|------|--------|-------|
| Search UI | **Not run in this session** | Automated: `Ctrl+Shift+F` widget test; regex/highlight/jump need interactive verify |
| Box-drawing | **Not run** | Unit tests cover dash segments and arm weights |
| Touch device | **Not run** | Widget tests: `tester.drag` scroll, `longPressAt` selection; fling decay constants untuned on hardware |

## Deferred / risks

- **Live re-highlight:** Match flags refresh on the next `full_snapshot_searched` / view refresh, not on every PTY byte while search is open (acceptable per spec perf note).
- **Fling tuning:** Decay `0.92`, velocity thresholds `200` / `40` px/s — tune on a real touch panel if inertia feels off.
- **Gesture arena:** Long-press vs vertical drag split into separate widget tests; combined drag-then-long-press on one pointer is flaky in tests (production paths are separate gestures).

## Commits (feature branch)

| SHA | Message |
|-----|---------|
| `bd6d8e1` | feat(rust): regex search (search_set/next/prev/clear + searched snapshot) |
| `08c1893` | feat(config): match flags + alacritty search colors |
| `d7e278f` | feat(render): opaque search-match color override in painter |
| `bd32f3a` | feat(engine): search passthroughs + searched-snapshot refresh |
| `a286855` | feat(ui): search bar + Ctrl+Shift+F wiring |
| `2784bbc` | feat(render): box-drawing long-tail — mixed junctions + dashed lines |
| `6463cf4` | feat(ui): touch input — one-finger scroll + long-press select |
