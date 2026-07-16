# TUI Scroll Performance & Feel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make TUI scrolling Orca-class responsive while keeping Alacritty-class VT correctness, via TUI wheel math, interaction-first PTY drain, dirty-row paint, tighter damage, and an optional GPU texture present path.

**Architecture:** Dual-path present (GPU `Texture` hot / `CustomPainter` cold) sitting on `alacritty_terminal` via FRB. Program scroll stays line-discrete CSI/SS3. Selection/search/a11y keep an on-demand Dart mirror (GPU path does **not** bake selection into the texture for MVP). Ship in six green slices.

**Tech Stack:** Dart/Flutter, flutter_rust_bridge, `alacritty_terminal` (Rust), existing `TerminalScrollController` / `TerminalEngineClient` / `MirrorGrid` / `GlyphAtlas`.

**Spec:** `docs/superpowers/specs/2026-07-16-tui-scroll-perf-design.md`

**Locked decisions (from spec review):**
- Success latency method: see Phase 6 measurement section (must not be left open).
- GPU MVP: Texture for cells + cursor; selection/search/a11y via on-demand `fullSnapshot` / existing mirror APIs — not baked into texture.
- Phase gate: each phase commits only when its DoD tests pass; later phases may start only after prior DoD is green on main.

---

## File map

| File | Responsibility |
|------|----------------|
| `lib/input/tui_wheel_distance.dart` | Orca-parity report-count math (pure Dart) |
| `lib/input/tui_wheel_event.dart` | Platform-neutral wheel event fields (deltaY, deltaMode, timeStamp, optional legacy deltas) |
| `lib/ui/terminal_scroll_controller.dart` | Route history vs program; call `TuiWheelDistance` on program path |
| `lib/ui/terminal_view.dart` | Wire `tuiScrollSensitivity`, `preferGpuSurface`; present surface switch |
| `lib/engine/terminal_engine_client.dart` | Interactive drain + DEC 2026 hold |
| `lib/input/term_mode.dart` | Add `kModeSynchronizedOutput` if missing |
| `lib/render/mirror_grid.dart` | Track dirty row bands for cold paint |
| `lib/render/terminal_painter.dart` | Dirty-row clip paint |
| `lib/render/glyph_atlas.dart` | LRU eviction |
| `lib/render/gpu_surface.dart` | Capability probe + Texture widget host |
| Rust `engine.rs` + compositor module | Damage tightening; optional GPU raster → texture id |
| `docs/library-api.md` | Public scroll / surface / scheduler docs |

**Reference (read-only):** `/home/hhoa/git/opensource/orca/src/renderer/src/lib/pane-manager/pane-terminal-tui-wheel-reports.ts`

---

## Phase 1: TuiWheelDistance + controller wiring

**DoD:** Mouse-report / alt-scroll wheel uses new distance math; history path unchanged; existing scroll controller + TUI batch tests green; new unit tests green.

### Task 1: TuiWheelDistance unit module (TDD)

**Files:**
- Create: `lib/input/tui_wheel_event.dart`
- Create: `lib/input/tui_wheel_distance.dart`
- Create: `test/tui_wheel_distance_test.dart`

- [ ] **Step 1: Write failing tests for event helpers + distance**

```dart
// test/tui_wheel_distance_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/tui_wheel_distance.dart';
import 'package:flutter_alacritty/input/tui_wheel_event.dart';

void main() {
  test('normalizeTuiScrollSensitivity clamps 1..10', () {
    expect(normalizeTuiScrollSensitivity(null), 1);
    expect(normalizeTuiScrollSensitivity(0), 1);
    expect(normalizeTuiScrollSensitivity(4.4), 4);
    expect(normalizeTuiScrollSensitivity(20), 10);
  });

  test('trackpad pixel stream maps 1:1 with fractional carry', () {
    final state = TuiWheelDistanceState();
    // cellHeight 20 → 30px = 1.5 rows → 1 report, 0.5 remainder
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 30, deltaMode: TuiWheelDeltaMode.pixel),
        multiplier: 1,
        state: state,
        cellHeight: 20,
      ),
      1,
    );
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 10, deltaMode: TuiWheelDeltaMode.pixel),
        multiplier: 1,
        state: state,
        cellHeight: 20,
      ),
      1,
    ); // 0.5 + 0.5
  });

  test('direction change resets pending fractional rows', () {
    final state = TuiWheelDistanceState();
    resolveTuiWheelReportCount(
      TuiWheelEvent(deltaY: 15, deltaMode: TuiWheelDeltaMode.pixel),
      multiplier: 1,
      state: state,
      cellHeight: 20,
    );
    expect(state.pendingRows, greaterThan(0));
    resolveTuiWheelReportCount(
      TuiWheelEvent(deltaY: -1, deltaMode: TuiWheelDeltaMode.pixel),
      multiplier: 1,
      state: state,
      cellHeight: 20,
    );
    // After opposite direction, prior remainder must not leak into new direction
    expect(state.pendingDirection, -1);
  });

  test('discrete line mode emits at least one report', () {
    final state = TuiWheelDistanceState();
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 1, deltaMode: TuiWheelDeltaMode.line),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      ),
      greaterThanOrEqualTo(1),
    );
  });
}
```

Port additional Orca fixtures from `pane-terminal-mouse-wheel.test.ts` (burst, multiplier) in the same file as follow-on tests in this task.

- [ ] **Step 2: Run tests — expect FAIL (library missing)**

Run: `flutter test test/tui_wheel_distance_test.dart`  
Expected: FAIL — target library/URI not found.

- [ ] **Step 3: Implement minimal modules**

Create `lib/input/tui_wheel_event.dart`:

```dart
enum TuiWheelDeltaMode { pixel, line, page }

class TuiWheelEvent {
  const TuiWheelEvent({
    required this.deltaY,
    this.deltaMode = TuiWheelDeltaMode.pixel,
    this.timeStampMs,
    this.legacyWheelDeltaY,
  });
  final double deltaY;
  final TuiWheelDeltaMode deltaMode;
  final double? timeStampMs;
  final double? legacyWheelDeltaY;
}
```

Create `lib/input/tui_wheel_distance.dart` by porting constants and functions from Orca’s `pane-terminal-tui-wheel-reports.ts` (`createTerminalTuiMouseWheelDistanceState` → `TuiWheelDistanceState`, `resolveTerminalTuiMouseWheelReportCount` → `resolveTuiWheelReportCount`, `normalizeTerminalTuiMouseWheelMultiplier` → `normalizeTuiScrollSensitivity`). Keep numeric constants identical (`TUI_WHEEL_ACCELERATED_DISTANCE_GAIN = 1.6`, burst intervals 16/45, etc.).

- [ ] **Step 4: Run tests — expect PASS**

Run: `flutter test test/tui_wheel_distance_test.dart`  
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/input/tui_wheel_event.dart lib/input/tui_wheel_distance.dart test/tui_wheel_distance_test.dart
git commit -m "feat: add TuiWheelDistance Orca-parity report math"
```

### Task 2: Wire TerminalScrollController program path

**Files:**
- Modify: `lib/ui/terminal_scroll_controller.dart`
- Modify: `lib/ui/terminal_view.dart` (add `tuiScrollSensitivity`)
- Modify: `test/terminal_scroll_controller_test.dart`
- Modify: `test/terminal_view_tui_scroll_test.dart` if constructors change

- [ ] **Step 1: Write failing controller test — mouse mode uses TuiWheelDistance**

Add to `test/terminal_scroll_controller_test.dart`:

```dart
test('mouse-report trackpad pixels emit reports via TuiWheelDistance not ScrollAccumulator only', () async {
  final modeFlags = kModeSgrMouse | kModeMouseClick | kModeAltScreen;
  final binding = FakeBinding()..modeFlags = modeFlags;
  final engine = TerminalEngine.fromBinding(binding, config: TerminalConfig.defaults());
  addTearDown(engine.dispose);
  final captured = <List<int>>[];
  engine.output.listen((b) => captured.add(b.toList()));

  final c = TerminalScrollController(
    engine: engine,
    cellHeight: 20,
    scrollMultiplier: 3,
    tuiScrollSensitivity: 1,
  );
  c.setWheelCell(col: 1, row: 1);
  // Two 30px events → 1 then 1 report at cellHeight 20 (1.5 + carry)
  c.onWheelSignal(dyPx: 30, shiftHeld: false);
  c.onWheelSignal(dyPx: 10, shiftHeld: false);
  await Future<void>.value();
  expect(captured, isNotEmpty);
  // Must contain mouse wheel CSI (SGR), not zero writes
  expect(captured.expand((e) => e).length, greaterThan(0));
});
```

- [ ] **Step 2: Run test — expect FAIL (no `tuiScrollSensitivity` / old math)**

Run: `flutter test test/terminal_scroll_controller_test.dart`  
Expected: compile fail or assertion fail.

- [ ] **Step 3: Implement wiring**

In `TerminalScrollController`:
- Add `required int tuiScrollSensitivity` (normalize via `normalizeTuiScrollSensitivity`).
- Hold `TuiWheelDistanceState _tuiDistance = TuiWheelDistanceState()`.
- On program destination + `wheelStyle == true` + `anyMouse(modeFlags)`: build `TuiWheelEvent` from `dyPx` (pixel mode; pass a monotonic `timeStampMs` from `SchedulerBinding.instance.currentFrameTimeStamp` or `DateTime.now()`), call `resolveTuiWheelReportCount`, encode `n` lines with existing encoders, `_scheduleProgramWrite`.
- On program destination + alternate scroll (no mouse): keep existing `ScrollAccumulator` + `scrollMultiplier` path (spec: alternate-scroll continues using `scrollMultiplier`).
- Reset `_tuiDistance` on `onGestureStart` / direction handled inside distance state.

In `TerminalView`: add `this.tuiScrollSensitivity = 1` and pass into controller construction (~line 552).

- [ ] **Step 4: Run controller + TUI view tests**

Run:
```bash
flutter test test/terminal_scroll_controller_test.dart test/terminal_view_tui_scroll_test.dart test/tui_wheel_distance_test.dart
```
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/terminal_scroll_controller.dart lib/ui/terminal_view.dart test/
git commit -m "feat: wire TuiWheelDistance into program scroll path"
```

---

## Phase 2: Interaction-first TerminalEngineClient + DEC 2026

**DoD:** After `markInteractive()`, drain schedules immediately (not only post-frame idle); single-flight preserved; sync-output hold defers `MirrorGrid.apply` until sync ends; mode bit exposed.

### Task 3: Interactive drain (TDD)

**Files:**
- Modify: `lib/engine/terminal_engine_client.dart`
- Create: `test/terminal_engine_client_interactive_test.dart`
- Modify: `lib/engine/terminal_engine.dart` to call `client.markInteractive()` from `scheduleWrite` when writes are user-driven (or have scroll controller notify engine)

- [ ] **Step 1: Write failing interactive drain test**

```dart
test('markInteractive drains without waiting for idle post-frame only', () async {
  final binding = FakeBinding();
  final grid = MirrorGrid();
  var scheduleCount = 0;
  final scheduled = <void Function()>[];
  final client = TerminalEngineClient(
    binding: binding,
    grid: grid,
    schedule: (cb) {
      scheduleCount++;
      scheduled.add(cb);
    },
  );
  client.markInteractive();
  client.feed(Uint8List.fromList([0x41])); // 'A'
  expect(scheduleCount, greaterThan(0));
  // Interactive path may use scheduleMicrotask or immediate schedule — drain runs when invoked
  for (final cb in List.of(scheduled)) {
    cb();
  }
  await Future<void>.value();
  // FakeBinding should have received advance — assert via binding spy if available
});
```

Adapt to existing `FakeBinding` / client test patterns in repo (`test/fake_binding.dart`). Prefer asserting `_advancing` / feed emptied over internal fields.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement**

```dart
// In TerminalEngineClient
static const interactiveWindow = Duration(milliseconds: 100);
DateTime? _interactiveUntil;

void markInteractive([DateTime? now]) {
  final t = now ?? DateTime.now();
  _interactiveUntil = t.add(interactiveWindow);
  if (_buf.isNotEmpty) _scheduleDrain(forceImmediate: true);
}

bool get _isInteractive =>
    _interactiveUntil != null && DateTime.now().isBefore(_interactiveUntil!);

void _scheduleDrain({bool forceImmediate = false}) {
  if (_drainScheduled || _advancing) return;
  _drainScheduled = true;
  if (forceImmediate || _isInteractive) {
    scheduleMicrotask(_drain);
  } else {
    _schedule(_drain);
  }
}
```

Call `markInteractive()` from `TerminalEngine.scheduleWrite` (all coalesced program writes, including TUI scroll) and from key/paste write paths already going through `scheduleWrite` / `write`.

- [ ] **Step 4: Run tests — PASS**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: interaction-first PTY drain window on TerminalEngineClient"
```

### Task 4: DEC 2026 mode bit + present hold

**Files:**
- Modify: `lib/input/term_mode.dart`
- Modify: Rust mode bit mapping if TermMode includes synchronized output (check `alacritty_terminal` `TermMode` bits; only expose if present)
- Modify: `lib/engine/terminal_engine_client.dart` (`_applyUpdate` hold)
- Create: `test/terminal_engine_client_sync_output_test.dart`

- [ ] **Step 1: Confirm sync handling in path-pinned alacritty_terminal**

```bash
# Search the path dependency / cargo checkout, not only our wrapper crate:
rg -n "SyncUpdate|2026|SYNCHRONIZED" ~/.cargo/git/checkouts/ packages/rust_lib_flutter_alacritty/ -g '*.rs' 2>/dev/null | head
# Also check Cargo.toml path to alacritty_terminal and search that tree.
```

**Known constraint:** `alacritty_terminal` already parses CSI `?2026` as `NamedPrivateMode::SyncUpdate` but historically treats it as a **no-op** (no `TermMode` bit). Do **not** expect a ready-made mode flag from `term.mode().bits()`.

**Required approach:** track sync state in our engine wrapper (set/clear on SyncUpdate private mode enter/exit during `parser.advance`), expose `engine.synchronized_output_active()` (or a bit we pack into `mode_flags` ourselves). Optionally small patch to the path-pinned alacritty crate if that is cleaner — document which in the commit body. Do not invent a second CSI parser in Dart.

- [ ] **Step 2: Failing test — hold apply while sync active**

Feed bytes that start sync, feed partial screen update, assert grid unchanged until sync end; then apply once.

- [ ] **Step 3: Implement hold buffer of `GridUpdate` until sync clears; then single `_grid.apply`**

- [ ] **Step 4: Tests PASS + commit**

```bash
git commit -am "feat: hold grid present during DEC 2026 synchronized output"
```

---

## Phase 3: Cold-path dirty-row paint + atlas LRU

**DoD:** Partial `GridUpdate` only paints dirty row bands; atlas evicts under pressure; visual/glyph tests green.

### Task 5: MirrorGrid dirty bands

**Files:**
- Modify: `lib/render/mirror_grid.dart`
- Create: `test/mirror_grid_dirty_rows_test.dart`

- [ ] **Step 1: Failing test**

```dart
test('apply partial records dirty row indices and clears after take', () {
  final g = MirrorGrid();
  g.initializeEmpty(4, 8);
  g.apply(GridUpdate(
    full: false,
    rows: 4,
    columns: 8,
    lines: [/* line 2 only */],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: true,
  ));
  expect(g.takeDirtyRows(), [2]);
  expect(g.takeDirtyRows(), isEmpty);
});
```

- [ ] **Step 2: Implement `Set<int> _dirtyRows`, set on apply (all rows if full), `takeDirtyRows()`, notify as today**

- [ ] **Step 3: PASS + commit**

```bash
git commit -am "feat: track dirty row bands on MirrorGrid"
```

### Task 6: TerminalPainter dirty clip

**Files:**
- Modify: `lib/render/terminal_painter.dart`
- Modify: `lib/ui/terminal_view.dart` if painter construction needs dirty set
- Create or extend: `test/terminal_painter_dirty_test.dart` (prefer recording canvas / golden)

- [ ] **Step 1: Failing test — partial paint does not draw bg for clean rows**

Use a fake `Canvas` recorder or count `drawRect` Y ranges; assert no fill centered on a clean row.

- [ ] **Step 2: In `paint`, if `dirtyRows` non-null and not full, clip to union of dirty row rects (+ overscan if needed); still allow full clear only when `full` or dirty covers all rows**

Note: Flutter `CustomPainter` typically redraws the whole layer; for true partial update use `RepaintBoundary` per region **or** keep full-layer paint but skip glyph/bg work for clean rows (CPU win). Spec requires skipping work on untouched rows — implement **skip loops for non-dirty rows** even if the layer is composited whole.

- [ ] **Step 3: PASS + commit**

```bash
git commit -am "perf: skip clean rows in TerminalPainter"
```

### Task 7: GlyphAtlas LRU

**Files:**
- Modify: `lib/render/glyph_atlas.dart`
- Modify: `test/glyph_atlas_test.dart`

- [ ] **Step 1: Failing test — exceeding capacity evicts oldest unused slots without throwing**

- [ ] **Step 2: Implement LRU (generation/order list); rebuild atlas image on eviction batch**

- [ ] **Step 3: PASS + commit**

```bash
git commit -am "feat: glyph atlas LRU eviction under pressure"
```

---

## Phase 4: Damage tightening

**DoD:** Mid-cell scroll no longer always forces full snapshot when overscan + fraction can ride on edge-row updates; benches do not regress.

### Task 8: Rust take_damage / scroll_refresh

**Files:**
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/engine.rs` (`take_damage` ~1270)
- Add Rust tests in `engine.rs` `#[cfg(test)]` or existing test module
- Re-run FRB codegen if API changes (prefer no API change)

- [ ] **Step 1: Write failing Rust test — scroll_fraction != 0 with display_offset==0 returns partial-capable update including overscan + fraction, not always full viewport lines**

Also update/replace any existing test that locks today’s behavior (e.g. `take_damage_forces_full_when_fraction_nonzero`) so it asserts the new contract instead of fighting the change.

- [ ] **Step 2: Change `take_damage` so `scroll_fraction != 0` alone does not force `full_snapshot` when live edge; keep full when `display_offset > 0`, or document retained full for history mid-cell if still required for correctness — prefer edge-row path from `scroll_refresh`

- [ ] **Step 3: `cargo test` in rust package + Dart scroll benchmarks**

```bash
cd packages/rust_lib_flutter_alacritty/rust && cargo test
cd ../../.. && flutter test test/scroll_benchmark_test.dart
```

- [ ] **Step 4: Commit**

```bash
git commit -am "perf: tighten scroll_fraction damage to avoid full snapshots"
```

---

## Phase 5: GPU texture path + probe/fallback

**DoD:** On supported desktop, `preferGpuSurface: true` or auto shows `Texture`; selection/search still work via on-demand mirror; failure latches to painter.

### Task 9: GpuSurface API + fallback latch (Dart first)

**Files:**
- Create: `lib/render/gpu_surface.dart`
- Create: `test/gpu_surface_test.dart`
- Modify: `lib/ui/terminal_view.dart`

- [ ] **Step 1: Failing tests for probe interface**

```dart
test('GpuSurfaceController latches painter fallback after attach failure', () {
  final c = GpuSurfaceController(probe: () async => false);
  expect(await c.ensureAttached(), isFalse);
  expect(c.usePainterFallback, isTrue);
});
```

- [ ] **Step 2: Implement controller with `preferGpuSurface`, probe, latch, `retry()`**

- [ ] **Step 3: TerminalView takes `bool? preferGpuSurface`; when fallback, existing painter tree; when GPU, placeholder `Texture(textureId: …)` behind feature flag until Rust wires id**

- [ ] **Step 4: Commit Dart scaffolding**

```bash
git commit -am "feat: GpuSurface probe and painter fallback latch"
```

### Task 10: Rust compositor → Flutter texture (desktop)

**Files:**
- Create: `packages/rust_lib_flutter_alacritty/rust/src/gpu_compositor.rs` (or similar concrete name — not `helpers`/`utils`)
- Modify: FRB API for `engine_present_damage` / register texture
- Platform: Linux/macOS/Windows Flutter texture registrar via existing plugin glue in `rust_builder` / flutter_rust_bridge

- [ ] **Step 1: Spike document in commit body — which embedder API registers external texture on each desktop OS**

- [ ] **Step 2: Minimal present: clear texture to default bg + draw dirty row solid colors (no glyphs) to prove pipe**

- [ ] **Step 3: Add glyph atlas draw into texture**

- [ ] **Step 4: Cursor overlay either in texture or keep `CursorPainter` above Texture**

- [ ] **Step 5: On GPU present success, skip applying full cell mirrors every frame; call `refreshView()` / snapshot only for selection, search, a11y, copy

- [ ] **Step 6: Integration test or example flag `FLUTTER_ALACRITTY_GPU=1`**

- [ ] **Step 7: Commit**

```bash
git commit -am "feat: GPU texture present path with on-demand mirror for selection"
```

---

## Phase 6: Benches, docs, latency measurement

**DoD:** Docs updated; benches gated; latency method documented and runnable.

### Task 11: Latency measurement method (locked)

Document in `docs/library-api.md` and a short `docs/superpowers/specs/2026-07-16-tui-scroll-latency-method.md` (or section in library-api):

| Field | Definition |
|-------|------------|
| Start | `TerminalScrollController` enqueues first program-scroll byte for a gesture (`_scheduleProgramWrite`) |
| Stop | First frame where `TerminalPainter.paint` / GPU present completes after corresponding `MirrorGrid`/`Texture` update from that scroll’s PTY echo |
| Target | Median ≤ 2 frames @ 60Hz (≤ ~33ms) on reference machine, vim in alt-screen, mouse reporting on, 80×24, local PTY |
| Tooling | `TERMINAL_SCROLL_TRACE=1` + optional microbench harness wrapping feed→apply |

- [ ] **Step 1: Add harness test or example debug path that records start/stop timestamps (CI may assert only that harness runs, not absolute ms)**

- [ ] **Step 2: Commit**

### Task 12: Docs + benchmark gates

**Files:**
- Modify: `docs/library-api.md` (scroll section ~552+)
- Modify: `CHANGELOG.md`
- Modify: existing `test/scroll_benchmark_test.dart` / `test/rendering_benchmark_test.dart` thresholds if improved
- Optionally: GPU bench behind tag

- [ ] **Step 1: Update library-api for `tuiScrollSensitivity`, interactive drain, `preferGpuSurface`, dual path**

- [ ] **Step 2: Run full relevant suite**

```bash
flutter test test/tui_wheel_distance_test.dart test/terminal_scroll_controller_test.dart test/terminal_view_tui_scroll_test.dart test/terminal_engine_client_interactive_test.dart test/mirror_grid_dirty_rows_test.dart test/glyph_atlas_test.dart test/scroll_benchmark_test.dart
```

- [ ] **Step 3: Commit**

```bash
git commit -am "docs: TUI scroll perf API and latency measurement"
```

---

## Execution notes

- **TDD:** @superpowers:test-driven-development — no production code before failing test in each task.
- **Commits:** one logical commit per task (or per step group above); never commit secrets; do not amend unless rules allow.
- **Naming:** no `helpers`/`utils` filenames — use domain names (`tui_wheel_distance`, `gpu_surface`, `gpu_compositor`).
- **Phase gates:** do not start Phase N+1 until Phase N DoD is green.
- **YAGNI:** do not add TUI local `scrollFraction` preview; do not port full Alacritty renderer.

---

## Parallelism

| Parallelizable after Phase 1 | Depends on |
|------------------------------|------------|
| Phase 2 (scheduler) | Phase 1 optional but preferred (markInteractive from scroll writes) |
| Phase 3 (paint) | Independent of Phase 2 |
| Phase 4 (Rust damage) | Independent of 2–3 |
| Phase 5 (GPU) | Prefer Phase 3–4 first for damage/dirty semantics |
| Phase 6 | After features it documents |
