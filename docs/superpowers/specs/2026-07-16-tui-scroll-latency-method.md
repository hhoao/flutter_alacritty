# TUI scroll latency measurement method

Locked method for measuring program-scroll “feel” latency (wheel/pan → PTY →
redraw → paint). Used by the Phase 6 harness and manual `TERMINAL_SCROLL_TRACE`
runs.

## Definition

| Field | Definition |
|-------|------------|
| **Start** | `TerminalScrollController` enqueues the first program-scroll byte for a gesture batch (`_scheduleProgramWrite` → `TerminalScrollLatency.markScheduleWrite`) |
| **Stop** | First frame where `TerminalPainter.paint` / `RasterPresentPainter.paint` completes after the corresponding `MirrorGrid` / texture generation update from that scroll’s PTY echo |
| **Target** | Median ≤ 2 frames @ 60Hz (≤ ~33ms) on a reference machine (vim in alt-screen, mouse reporting on, 80×24, local PTY). CI asserts only that the harness **runs**, not absolute ms |
| **Tooling** | `--dart-define=TERMINAL_SCROLL_TRACE=1` and/or `TerminalScrollLatency.harnessEnabled = true` + `test/tui_scroll_latency_harness_test.dart` |

## Pipeline

```
scheduleWrite (start)
    → PTY write / echo (or simulated feed in tests)
    → MirrorGrid.apply / RasterPresentSurface.present (echo gen)
    → TerminalPainter / RasterPresentPainter paint (stop)
```

Correlation uses the first grid/texture generation bump while a start is pending,
then the first paint whose generation is ≥ that echo generation.

## Running

```bash
# Harness (no real PTY; CI-safe)
flutter test test/tui_scroll_latency_harness_test.dart

# Manual trace logging
flutter run --dart-define=TERMINAL_SCROLL_TRACE=1
# Look for [scroll#N latency] start / echo / stop lines
```

Inspect samples in-process via `TerminalScrollLatency.samples` (`startUs`,
`stopUs`, `elapsedUs`). Call `TerminalScrollLatency.reset()` between runs.
