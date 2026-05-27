# Plan 2A acceptance findings (core data path)

**Branch:** `feature/plan2a-core-data-path`  
**Worktree:** `.worktrees/plan2a-core-data-path`  
**Date:** 2026-05-27  
**Verifier:** Agent (automated build/test + `flutter run` smoke) + human interactive gate pending

## Automated verification (agent environment)

| Check | Result |
|-------|--------|
| `git log -1 --oneline` | **PASS** — `7d0c241` (Tasks 1–9 as expected) |
| `cd rust && cargo test` | **PASS** — 9 tests |
| `flutter test` | **PASS** — 12 tests |
| `flutter analyze lib test` | **PASS** — no issues |
| `flutter run -d linux` (build + launch) | **PASS** — Linux debug bundle built and app launched; agent did not drive interactive shell workflows (see manual checklist) |

## Manual acceptance checklist (Task 10 / spec §7)

**Automated gates (2026-05-27 code-review pass):** `cargo test`, `flutter test`, and `flutter analyze lib test` pass after resize/title/FFI fixes. Interactive rows below remain **USER** unless you run `flutter run -d linux` locally.

Run locally:

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty/.worktrees/plan2a-core-data-path
flutter run -d linux
```

| Item | Status | Notes |
|------|--------|-------|
| `cat` large file / `yes \| head -n 100000` — responsive, Ctrl-C works | **USER** | Coalescing + async advance implemented; perf subjective |
| `vim` scroll + `htop` — smooth, no jank | **USER** | Glyph cache + damage path in place; not profiled here |
| DSR / query path (`printf '\e[6n'…` or vim DA) | **AUTO** | Rust `dsr_emits_pty_write` + `engine_bindings_test` (FRB round-trip + `EngineEvent_PtyWrite`); live PTY loop **USER** |
| `printf '\e]0;hi\a'` — window title "hi" | **USER** | Wired: events → `MyApp._title` → `MaterialApp.title` + `Title` widget (GTK header bar may still show static title from `linux/runner` — verify visually) |
| `printf '\a'` — bell hook | **USER** | `_flashBell()` is a no-op stub (Plan A: hook present; visual flash → sub-project C) |
| OSC52 copy → system clipboard | **USER** | `ClipboardStore` → `Clipboard.setData` wired; needs desktop session with clipboard |
| Full-width ruler — right edge alignment | **USER** | `CellMetrics.measure` uses sub-pixel `W×20` width; cols = `floor(maxWidth/cw)` — ruler confirms artifact gone or documents deferred wrap |

## Heavy-output smoothness

**Not manually tested** in this pass. Architecture intent: per-frame PTY coalescing, FRB-async `engine_advance`, damage-only `take_damage`, glyph-cached full repaint. User should run `yes | head -n 100000` and `cat` on a large file and note subjective jank vs Plan 1 tracer bullet.

## `engine_advance` + `engine_take_damage` two-hop

- **Design:** Two async FRB calls per drain frame (`advance` then `take_damage`), plus sync `engine_take_events` in `pumpEvents`.
- **Observation:** No profiling in agent environment. Spec §9 notes merging into one FFI call if hop cost matters — carry-over if profiling shows overhead.
- **Unit coverage:** `engine_bindings_test` exercises both hops over real `.so`; `engine_client_test` verifies coalescing calls `advance` once per frame.

## Cols / ruler artifact

- **Fix applied:** `CellMetrics.measure` — `layout('W' * 20).width / 20` for sub-pixel cell width; `TerminalScreen` uses `floor(maxWidth / cw)` for cols.
- **Status:** Automated tests do not assert ruler alignment. **USER** should run `printf '%*s\n' "$(tput cols)" '' | tr ' ' '-'` and compare to native terminal; right-edge bars from deferred wrap are acceptable per spec.

## FRB adjustments vs plan

| Plan / spec assumption | As implemented |
|------------------------|----------------|
| `engine_new(columns, rows, StreamSink<EngineEvent>)` | **`engine_new(columns, rows)` only** — engine owns `Arc<Mutex<Vec<EngineEvent>>>`, drained via `engine_take_events()` each frame |
| `EngineEvent` hand-written Dart enum | **`@freezed` union** in `lib/src/rust/event_proxy.dart` — variants `EngineEvent_PtyWrite`, `_Title`, etc.; `field0` accessors |
| `reset_damage` in `new()` | **Yes** — clears `TermDamage::Full` from boot so first post-input `take_damage` is partial |
| Idle `take_damage` after reset | **≤1 line** — cursor-cell damage only; documented in `damage_reports_only_changed_lines_then_resets` |
| `catch_unwind` on advance/damage | **Yes** in `rust/src/api/terminal.rs` |
| `engine_mode_flags` | **Not exposed** — deferred to Plan B (mode-aware input) |

## `alacritty_terminal` API notes

| Topic | Notes |
|-------|--------|
| `term.damage()` / `reset_damage()` | `TermDamage::Full` vs `Partial` with viewport line indices — matches plan |
| `grid[Line][Column]` indexing | Works as planned |
| `Term::new` + `EventProxy` | No extra `Clone` bound on listener |
| Git dep | Pinned rev in `rust/Cargo.toml` (same as Plan 1) |
| Initial full damage | `Term` boots with full damage; **`reset_damage()` in `TerminalEngine::new`** required for incremental first frame |

## Spec §1–7 compliance (lightweight skim)

| Area | Status |
|------|--------|
| Async advance + per-frame coalescing + `_advancing` backpressure | **Done** |
| Damage incremental + `reset_damage` after read | **Done** |
| Event back-channel (PtyWrite, Title, ResetTitle, Bell, ClipboardStore) | **Done** (polled, not streamed) |
| ClipboardLoad | **PtyWrite(empty)** in Rust |
| ColorRequest / TextAreaSizeRequest | **No-op** (documented deferral) |
| Mutable `MirrorGrid` + `GlyphCache` + painter | **Done** |
| Cols sub-pixel measurement | **Done**; ruler verification **USER** |
| Panic isolation | **Done** (advance swallows panic; damage returns empty update) |
| Max bytes-per-advance cap (spec §3) | **Deferred** — coalescing + one batch/frame only; add cap if profiling shows latency spikes on huge single reads |
| `engine_mode_flags` (spec §4) | **Deferred → B** |

## Carry-over for sub-projects B / C / D / E

| Sub-project | Carry-over |
|-------------|------------|
| **B — Input** | Expose `engine_mode_flags`; mode-aware `encodeKey`; mouse reporting; bracketed paste; consider answering `TextAreaSizeRequest` with real pixel dims |
| **C — Rendering fidelity** | Bold/italic/underline/inverse/dim; cursor styles/blink; wide/CJK; real bell flash in `_flashBell` |
| **D — Scrollback / selection** | `display_offset` in damage/snapshot; selection + copy/paste; scrollback view in `MirrorGrid` |
| **E — Lifecycle** | Shell exit / restart UX; handle `Event::Exit` / `ChildExit` if needed |
| **Profiling** | Merge `advance`+`take_damage` FFI hop; optional per-advance byte cap |
| **Integration** | Merge `feature/plan2a-core-data-path` → `main` after user manual gate; open PR for review |

## Stale display fix (2026-05-27)

**Symptom:** Terminal grid updated in memory but `CustomPaint` did not repaint until app hide/resume (lifecycle forced a frame).

**Root causes (partial fixes f151a36, 637f4d2):**

1. **Missing frame after async apply** — `TerminalEngineClient._drain` completes on a microtask; `scheduleFrame()` after `apply()` is necessary but not sufficient alone.
2. **Partial damage resized the grid** — `FrbEngineBinding._toGridUpdate` sets `rows` to `max(damaged line)+1`, not viewport height. `MirrorGrid.apply` now resizes only when `full: true`.
3. **`repaint:` + `ListenableBuilder` insufficient for async path** — Main’s tracer bullet updates the grid synchronously on the PTY stream; `CustomPaint` + `repaint: grid` is enough there. Plan 2A applies damage asynchronously; `notifyListeners()` + `scheduleFrame()` did not reliably repaint while the window stayed focused. `ListenableBuilder` around `CustomPaint` still failed in practice (same symptom after 637f4d2).

**Fix:** `TerminalScreen` listens to `MirrorGrid` and calls `setState` on every apply (proven rebuild path). Keep `scheduleFrame()` after apply, `MirrorGrid.generation` in `shouldRepaint`, stable `ValueListenableBuilder` `child: TerminalScreen` for title updates, and `CustomPaint` + `repaint: grid` like main (no `ListenableBuilder` wrapper).

## Rendering / integration notes

- **Font:** DejaVu Sans Mono + fallback (from Task 1 tracer fix), shared by metrics, glyph cache, and painter.
- **Title:** `MaterialApp.title` + `Title` widget bound to shared `ValueNotifier`; GNOME header bar may need native runner sync later.
- **Resize:** `TerminalEngineClient.resize` applies `fullSnapshot()` after `engine_resize` so `MirrorGrid` matches new viewport (`engine_client_test`).
- **Bell:** Hook only — no visual feedback yet.
