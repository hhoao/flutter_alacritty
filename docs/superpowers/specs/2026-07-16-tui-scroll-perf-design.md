# TUI Scroll Performance & Feel Design

**Date:** 2026-07-16  
**Status:** Approved (design review)  
**Consumer:** General pub library (any Flutter host; Orca is one consumer, not the product)  
**Related:** [2026-07-15-capability-roadmap-design.md](./2026-07-15-capability-roadmap-design.md) (extends T1 Performance)

## Goal

Make interactive TUI scrolling (vim, htop, less, mouse-report apps) feel **Orca-class responsive** while keeping **Alacritty-class VT correctness**, without changing the library boundary (embeddable single-terminal package, no host chrome).

Secondary: improve normal-buffer scrollback paint/damage so history pan/wheel also benefits from the same render and scheduling work.

## Problem (evidence)

TUI scroll is line-discrete at the PTY boundary on both stacks (correct). The feel gap is the end-to-end loop:

| Layer | flutter_alacritty today | Orca desktop terminal |
|-------|-------------------------|------------------------|
| Emulator | `alacritty_terminal` via FRB | xterm.js in-process |
| Paint | `CustomPainter` + glyph atlas; full grid walk per generation | `@xterm/addon-webgl` damage + GPU atlas |
| Wheel (TUI) | Simple pixel→line accumulator | Trackpad 1:1, log compress + burst, microtask drain (not rAF-capped) |
| Output | Post-frame coalesce; single in-flight `advance` | 8ms batch + interactive bypass + sync-frame scheduler |

Primary costs: (1) wheel→PTY→redraw→async FFI→paint latency, (2) full-grid CustomPainter every damage frame, (3) weaker TUI wheel distance math.

## Decisions locked in

| Decision | Choice |
|----------|--------|
| Success bar | C — Orca-class feel + Alacritty-class correctness/throughput |
| Architecture | B — dual-path render + interaction-first I/O (not paint-only, not full Alacritty window port) |
| TUI scroll model | Keep line-discrete PTY reports (no local `scrollFraction` preview on alt-screen) |
| Routing | Keep Alacritty `scroll_terminal` parity (mouse → program; Shift → history; alt+1007 → SS3) |
| Scope | Input wheel + output scheduler + damage/paint + optional GPU texture path |

## Non-goals

- Local sub-cell “fake smooth” preview for TUI / alt-screen
- Porting Alacritty’s full GPU frontend / window into Flutter
- Host chrome (tabs, profiles, SSH UI)
- Changing VT semantics for alternate scroll / mouse reporting

## Architecture

```text
Host (PTY read/write)
    │
┌───▼──────────────────────────────────────────────────────────────┐
│ flutter_alacritty                                                │
│  TerminalScrollController                                        │
│    ├─ history: scrollLines / scrollPixels (unchanged model)      │
│    └─ program: TuiWheelDistance → encode SS3/SGR → scheduleWrite │
│  TerminalEngineClient (interaction-first drain + DEC 2026 hold)  │
│  TerminalView                                                    │
│    ├─ GpuSurface (hot): Texture from Rust compositor          │
│    └─ PainterSurface (cold): MirrorGrid + dirty-row CustomPainter│
└───┬──────────────────────────────────────────────────────────────┘
    │ FRB
┌───▼──────────────────────────────────────────────────────────────┐
│ rust_lib_flutter_alacritty                                       │
│  Term + damage + (optional) GpuCompositor → external texture │
└──────────────────────────────────────────────────────────────────┘
```

### Ownership

| Unit | Owns | Must not own |
|------|------|--------------|
| `TuiWheelDistance` | Pixel/line → report count; burst/trackpad state | PTY I/O, painting |
| `TerminalScrollController` | Destination routing; coalesce program bytes / history flushes | VT parse |
| `TerminalEngineClient` | Feed coalesce, interactive bypass, sync hold, single-flight advance | Widget layout |
| `GpuSurface` / Rust compositor | Dirty-row raster to texture; glyph atlas on GPU path | Input gestures |
| `TerminalPainter` (cold) | Dirty-row clip paint; atlas LRU | Wheel math |
| Host | `engine.output` → PTY write; PTY read → `engine.feed` | Reimplementing damage |

## 1. Input — TUI wheel

### Behavior

Port Orca’s `pane-terminal-tui-wheel-reports` semantics into a pure Dart module (e.g. `lib/input/tui_wheel_distance.dart`):

- **Trackpad-like pixel streams:** accumulate physical distance in cell-height units; emit `trunc(rows)` reports; carry fractional remainder. No per-event cap; no momentum-tail suppression (batching happens at write coalesce).
- **Discrete / mouse wheel:** compress distance with log curve + short burst bonus when events arrive in a tight cadence; clamp per-event report count.
- **Drain:** schedule program writes via existing microtask `scheduleWrite` / `scheduleTask` — **do not** frame-rate-cap TUI report drain.
- **Direction change:** reset remainder / burst state.
- **Multiplier:** `tuiScrollSensitivity` ∈ [1, 10], default `1` (mouse-report path). Alternate-scroll (no mouse mode) continues to use `scrollMultiplier` scaling as today unless both apply by mode.

### Encoding (unchanged contracts)

- Mouse tracking active → batched SGR/X10 wheel reports at pointer cell
- Else alt-screen + DEC 1007 → batched SS3 `ESC O A/B`
- Shift → local history (not program)

### Config

| Knob | Default | Notes |
|------|---------|-------|
| `scrollMultiplier` | `3` (= 1.0×) | History / non-mouse alternate-scroll scale (existing) |
| `tuiScrollSensitivity` | `1` | Integer multiplier for mouse-report TUI wheel only |

## 2. Output — interaction-first scheduler

Upgrade `TerminalEngineClient` without removing backpressure:

1. **Steady state:** coalesce PTY bytes to a frame boundary; at most one `advanceAndTakeDamage` in flight.
2. **Interactive window (~100ms after wheel/key/program-scroll write):** bypass long coalesce; schedule drain ASAP (still single-flight; queue next batch when current finishes).
3. **DEC 2026 synchronized output:** when `?2026h`…`?2026l` (or equivalent hold markers exposed by the engine) is active, hold present until the sync frame completes, then one present — avoid mid-frame TUI flicker.
4. **Priority:** while interactive, prefer draining the buffer that follows a program-scroll write over unrelated deferred work (resize still flushes synchronously as today).

FFI panic isolation on advance/damage/scroll remains mandatory.

## 3. Render — dual path

### Hot path — GPU texture (preferred when available)

- Rust owns cell grid + glyph resources for the compositor.
- Each present: apply damage (row ranges / scroll delta); raster dirty regions into an **external Flutter texture** (platform channel / Impeller-compatible texture id).
- Dart `TerminalView` shows `Texture` (plus optional overlay layers for selection chrome if not baked in).
- Capability probe at startup; auto-fallback on failure / context loss.

### Cold path — CustomPainter (fallback + tests)

- Keep `MirrorGrid` + `TerminalPainter` + glyph atlas.
- **Must:** paint only dirty rows (or scrolled edge rows) when `GridUpdate.full == false`; clear/clip to those bands.
- **Must:** glyph atlas LRU eviction under pressure (roadmap T1).
- Full-grid paint only on `full` updates or explicit refresh.

### Host API

- `TerminalView` auto-selects path.
- Optional `preferGpuSurface: bool?` — `true` force attempt, `false` force painter, `null` auto.

## 4. Damage contract

| Case | Engine | Present |
|------|--------|---------|
| Live edge, `scroll_fraction == 0` | `TermDamage::Partial` → changed lines | GPU dirty rows / painter dirty rows |
| History line scroll | `scroll_line_delta` + edge rows | Rotate/copy + fill edges (existing mirror rotate; GPU blit/scroll) |
| Mid-cell `scroll_fraction` | Prefer edge + overscan payload; **tighten** forced full-snapshot cases (roadmap T1) | Painter shift clip / GPU shift |
| Alt-screen TUI redraw | Whatever Term marks; often many lines | Partial present; avoid unnecessary Dart full mirror when on GPU path |
| Resize / theme / font | Full snapshot | Full present |

On GPU path, avoid shipping full columnar `LineUpdate` mirrors every frame when the texture already presents — mirror may stay for selection/search/a11y snapshots via explicit APIs.

## 5. Testing & success criteria

### Tests (TDD)

- Unit: `TuiWheelDistance` — trackpad 1:1, discrete compress/burst, direction reset, multiplier clamp (parity with Orca fixtures where practical).
- Unit: program-scroll coalesce still one `scheduleWrite` batch per tick under wheel storms.
- Client: interactive window drains sooner than idle coalesce; single-flight preserved.
- Painter: partial update does not paint untouched row bands (golden or draw-call/spy).
- Existing TUI routing / encoder / history scroll tests remain green.
- Benchmarks: extend scroll/feed/paint gates; add GPU-path bench when enabled in CI.

### Success

- Same-machine TUI (vim/htop): wheel → first visible frame within ~2 frames @ 60Hz under typical load (document measurement method).
- No regression on existing `*_benchmark_test` thresholds.
- GPU unavailable → cold path still correct and improved (dirty-row paint).
- Docs: `library-api.md` scroll section updated for `tuiScrollSensitivity`, dual surface, scheduler behavior.

## 6. Rollout order

Work is shippable in slices (each keeps main green):

1. **TuiWheelDistance + controller wiring** (feel win, no render change)
2. **Interaction-first `TerminalEngineClient` + DEC 2026 hold hooks**
3. **Cold-path dirty-row paint + atlas LRU**
4. **Damage tightening** (`scroll_fraction` / full-snapshot)
5. **GPU texture path + probe/fallback**
6. **Benches + docs**

## Error handling

- GPU attach/context loss → log once, latch fallback to painter until next recovery boundary (settings/restart/explicit retry).
- Wheel math never drops opposite-direction intent across a direction change (reset state).
- `scheduleWrite` / advance failures surface as today; no silent no-op for “implemented” knobs.

## Open implementation notes (non-blocking)

- Exact Flutter external-texture registration API may differ by embedder (desktop vs mobile); probe isolates that behind `GpuSurface`.
- DEC 2026: expose minimal mode bits from Rust if not already on `modeFlags`; do not invent a second sync protocol.
- Orca reference implementations for wheel math live in Orca’s `pane-terminal-tui-wheel-reports.ts` — port semantics, not Electron/DOM types.
`)