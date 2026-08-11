import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_alacritty/debug/terminal_scroll_latency.dart';
import 'package:flutter_alacritty/debug/terminal_scroll_trace.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/program_scroll_encoder.dart';
import 'package:flutter_alacritty/input/scroll_accumulator.dart';
import 'package:flutter_alacritty/input/scroll_destination.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/input/tui_wheel_distance.dart';
import 'package:flutter_alacritty/input/tui_wheel_event.dart';

/// Owns scroll gesture state for [TerminalView]: pixel accumulator, routing,
/// per-tick flush to either local history scroll or batched PTY writes.
class TerminalScrollController {
  TerminalScrollController({
    required this.engine,
    required double cellHeight,
    required int scrollMultiplier,
    /// Orca/xterm history scrollSensitivity (default 1.15).
    double scrollSensitivity = 1.15,
    /// Orca/xterm fastScrollSensitivity when Alt is held (default 5).
    double fastScrollSensitivity = 5.0,
    /// Mouse-report wheel sensitivity (1..10). Applies to discrete/mouse-notch
    /// classification (large pixel deltas / legacy); trackpad-like small pixel
    /// streams stay 1:1 and ignore this knob (Orca parity). Flutter has no
    /// `wheelDeltaY`, so abs(dy)≥50 is treated as a discrete notch. Alternate-
    /// scroll continues to use [scrollMultiplier] × [scrollSensitivity].
    required int tuiScrollSensitivity,
  })  : _baseMultiplier = scrollMultiplier / 3.0,
        _scrollSensitivity = scrollSensitivity,
        _fastScrollSensitivity = fastScrollSensitivity,
        _accumulator = ScrollAccumulator(cellHeight: cellHeight),
        _historyWheelAccumulator = ScrollAccumulator(cellHeight: cellHeight),
        _tuiScrollSensitivity =
            normalizeTuiScrollSensitivity(tuiScrollSensitivity);

  final TerminalEngine engine;
  ScrollAccumulator _accumulator;
  /// Pixel remainder for history wheel only (Alacritty `accumulated_scroll % height`).
  ScrollAccumulator _historyWheelAccumulator;
  final double _baseMultiplier;
  final double _scrollSensitivity;
  final double _fastScrollSensitivity;
  final int _tuiScrollSensitivity;
  TuiWheelDistanceState _tuiDistance = TuiWheelDistanceState();
  /// Monotonic ms counter for [TuiWheelEvent.timeStampMs] when frame time is unavailable.
  double _tuiWheelTimeMs = 0;

  bool _historyScheduled = false;
  bool _historyScrollInFlight = false;
  int _historyGeneration = 0;
  final List<Completer<void>> _historyIdleWaiters = [];
  double _pendingHistoryPx = 0;
  int _pendingHistoryLines = 0;
  int _wheelCol = 1;
  int _wheelRow = 1;

  /// Trackpad-like wheel deltas coalesced within one microtask turn.
  /// Discrete notches (≥50px) flush immediately so burst/sensitivity stay correct.
  double _pendingTrackpadWheelDyPx = 0;
  bool _trackpadWheelScheduled = false;
  bool _pendingTrackpadShiftHeld = false;
  bool _pendingTrackpadAltHeld = false;

  Ticker? _flingTicker;
  double _flingVelocity = 0;
  double _flingDecel = 0.998;
  Duration? _flingLastTick;
  bool _flingShiftHeld = false;

  /// Rebuilds the pixel accumulator when cell metrics change (font zoom).
  /// Sub-line [ScrollAccumulator.remainderPx] is intentionally discarded.
  /// Also resets TUI wheel carry so pending rows are not applied in stale
  /// cell-height units.
  void updateCellHeight(double cellHeight) {
    _cancelPendingProgram();
    _flushPendingTrackpadWheel();
    _accumulator = ScrollAccumulator(cellHeight: cellHeight);
    _historyWheelAccumulator = ScrollAccumulator(cellHeight: cellHeight);
    _tuiDistance = TuiWheelDistanceState();
  }

  void _cancelPendingProgram() {
    _pendingProgramBytes.clear();
    _programScheduled = false;
  }

  /// Drop coalesced history wheel/pan/fling deltas. Call before absolute
  /// scroll (scrollbar, ScrollTo*) so a pending flush cannot override the
  /// target position on the next microtask/frame.
  ///
  /// Pair with [drainHistoryScroll] before absolute engine scroll so an
  /// in-flight `scrollPixels` / `scrollLines` cannot race past cancel.
  void cancelPendingHistoryFlushes() {
    if (_pendingHistoryPx != 0 ||
        _pendingHistoryLines != 0 ||
        _historyScheduled) {
      TerminalScrollTrace.log(
        'controller',
        'cancelPendingHistoryFlushes px=$_pendingHistoryPx lines=$_pendingHistoryLines',
      );
    }
    _pendingHistoryPx = 0;
    _pendingHistoryLines = 0;
    _historyScheduled = false;
    _historyGeneration++;
    stopFling();
    _notifyHistoryIdle();
  }

  void _notifyHistoryIdle() {
    if (_historyScrollInFlight ||
        _historyScheduled ||
        _pendingHistoryPx != 0 ||
        _pendingHistoryLines != 0) {
      return;
    }
    if (_historyIdleWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.from(_historyIdleWaiters);
    _historyIdleWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
  }

  /// Drop all pending history scroll state including wheel pixel remainder.
  void cancelPendingHistory() {
    cancelPendingHistoryFlushes();
    _historyWheelAccumulator.reset();
  }

  /// Waits until no history scroll flush is scheduled, in flight, or pending.
  /// Wired to [TerminalEngine.onDrainHistoryScroll] for absolute scroll paths.
  Future<void> drainHistoryScroll() async {
    while (_historyScrollInFlight ||
        _historyScheduled ||
        _pendingHistoryPx != 0 ||
        _pendingHistoryLines != 0) {
      if (!_historyScrollInFlight &&
          !_historyScheduled &&
          (_pendingHistoryPx != 0 || _pendingHistoryLines != 0)) {
        _scheduleHistoryFlush();
      }
      final waiter = Completer<void>();
      _historyIdleWaiters.add(waiter);
      await waiter.future;
    }
  }

  void onGestureStart() {
    cancelPendingHistory();
    _accumulator.reset();
    _tuiDistance = TuiWheelDistanceState();
  }

  void setWheelCell({required int col, required int row}) {
    _wheelCol = col;
    _wheelRow = row;
  }

  void onWheelSignal({
    required double dyPx,
    required bool shiftHeld,
    bool altHeld = false,
  }) {
    // Discrete / mouse-notch: keep per-event ingest (burst + sensitivity).
    // Trackpad pixel streams: sum within the turn, one ingest — cuts handler
    // storms without frame-rate-capping reports across turns.
    const discretePixelMin = 50.0;
    if (dyPx.abs() >= discretePixelMin) {
      _flushPendingTrackpadWheel();
      _ingestDy(dyPx, shiftHeld: shiftHeld, altHeld: altHeld, wheelStyle: true);
      return;
    }
    _pendingTrackpadWheelDyPx += dyPx;
    _pendingTrackpadShiftHeld = shiftHeld;
    _pendingTrackpadAltHeld = altHeld;
    if (_trackpadWheelScheduled) return;
    _trackpadWheelScheduled = true;
    engine.scheduleTask(_flushPendingTrackpadWheel);
  }

  void _flushPendingTrackpadWheel() {
    _trackpadWheelScheduled = false;
    final dy = _pendingTrackpadWheelDyPx;
    _pendingTrackpadWheelDyPx = 0;
    if (dy == 0) return;
    // Why: trackpad gain/forceTrackpad are for mouse-report TUI only.
    // Alternate-scroll still uses ScrollAccumulator and must keep full dy.
    final mouseReport = anyMouse(engine.grid.modeFlags);
    const trackpadGain = 0.85;
    _ingestDy(
      mouseReport ? dy * trackpadGain : dy,
      shiftHeld: _pendingTrackpadShiftHeld,
      altHeld: _pendingTrackpadAltHeld,
      wheelStyle: true,
      forceTrackpad: mouseReport,
    );
  }

  void onPanDelta({required double dyPx, required bool shiftHeld}) {
    _ingestDy(dyPx, shiftHeld: shiftHeld, wheelStyle: false);
  }

  void _ingestDy(
    double dyPx, {
    required bool shiftHeld,
    required bool wheelStyle,
    bool altHeld = false,
    bool forceTrackpad = false,
  }) {
    final modeFlags = engine.grid.modeFlags;
    final dest = scrollDestination(modeFlags: modeFlags, shiftHeld: shiftHeld);
    TerminalScrollTrace.log(
      'controller',
      'ingest dy=$dyPx wheel=$wheelStyle shift=$shiftHeld '
      'dest=$dest anyMouse=${anyMouse(modeFlags)} modeFlags=$modeFlags',
    );

    // Scrollback: wheel uses discrete lines (Alacritty `scroll_terminal` parity);
    // touch pan / fling keep sub-cell `scroll_pixels` for smooth drag.
    if (dest == ScrollDestination.history) {
      // Why: Orca/xterm use scrollSensitivity (1.15) normally and
      // fastScrollSensitivity (5) when Alt is held.
      final sens = altHeld ? _fastScrollSensitivity : _scrollSensitivity;
      final scaled = dyPx * _baseMultiplier * sens;
      final signedPx = wheelStyle ? -scaled : scaled;
      if (wheelStyle) {
        final lines = _historyWheelAccumulator.ingest(
          dyPx: signedPx,
          multiplier: 1.0,
        );
        TerminalScrollTrace.log(
          'controller',
          'wheel ingest dy=$dyPx signedPx=${signedPx.toStringAsFixed(1)} '
          'lines=$lines wheelRem=${_historyWheelAccumulator.remainderPx.toStringAsFixed(1)} '
          'pendingLines=$_pendingHistoryLines '
          'before ${_posSnapshot()}',
        );
        if (lines != 0) {
          _pendingHistoryLines += lines;
          _scheduleHistoryFlush();
        }
      } else {
        final g = engine.grid;
        final pos = g.displayOffset + g.scrollFraction;
        if (signedPx < 0 && pos <= 0) {
          TerminalScrollTrace.log(
            'controller',
            'pan skip at live bottom px=${signedPx.toStringAsFixed(1)}',
          );
          stopFling();
          return;
        }
        if (signedPx > 0 &&
            g.historySize > 0 &&
            pos >= g.historySize.toDouble()) {
          TerminalScrollTrace.log(
            'controller',
            'pan skip at history top px=${signedPx.toStringAsFixed(1)}',
          );
          stopFling();
          return;
        }
        TerminalScrollTrace.log(
          'controller',
          'pan px+=${signedPx.toStringAsFixed(1)} pendingPx=$_pendingHistoryPx '
          '${_posSnapshot()}',
        );
        _scheduleHistoryPixels(signedPx);
      }
      return;
    }

    // TUI / mouse-report: accumulate pixels → whole-line PTY events.
    // Wheel ([PointerScrollEvent.scrollDelta]) and drag/pan use opposite dy
    // signs for the same user intent — same split as pre-controller pointer code.
    //
    // Why: mouse-report wheel uses Orca-parity TuiWheelDistance (trackpad pixel
    // carry + discrete burst); alternate-scroll keeps ScrollAccumulator + multiplier.
    if (wheelStyle && anyMouse(modeFlags)) {
      final n = resolveTuiWheelReportCount(
        _mouseReportWheelEvent(dyPx, forceTrackpad: forceTrackpad),
        multiplier: _tuiScrollSensitivity,
        state: _tuiDistance,
        cellHeight: _accumulator.cellHeight,
        forceTrackpad: forceTrackpad,
      );
      if (n == 0) return;
      // Flutter scrollDelta.dy > 0 is scroll-down → mouse wheel "down" (up: false).
      final up = dyPx < 0;
      final bytes = encodeMouseWheelLines(
        lines: n,
        up: up,
        col: _wheelCol,
        row: _wheelRow,
        modeFlags: modeFlags,
      );
      TerminalScrollTrace.log(
        'controller',
        'tui mouse wheel n=$n up=$up col=$_wheelCol row=$_wheelRow '
        'bytes=${bytes.length}',
      );
      if (bytes.isNotEmpty) _scheduleProgramWrite(bytes);
      return;
    }

    final programMultiplier =
        anyMouse(modeFlags) ? 1.0 : _baseMultiplier * _scrollSensitivity;
    final signedDy = wheelStyle ? -dyPx : dyPx;
    final signedLines = _accumulator.ingest(
      dyPx: signedDy,
      multiplier: programMultiplier,
    );
    if (signedLines == 0) return;

    final up = signedLines > 0;
    final n = signedLines.abs();
    final bytes = anyMouse(modeFlags)
        ? encodeMouseWheelLines(
            lines: n,
            up: up,
            col: _wheelCol,
            row: _wheelRow,
            modeFlags: modeFlags,
          )
        : encodeAlternateScrollLines(lines: n, up: up);
    TerminalScrollTrace.log(
      'controller',
      'tui wheel lines=$n up=$up anyMouse=${anyMouse(modeFlags)} '
      'bytes=${bytes.length}',
    );
    if (bytes.isNotEmpty) _scheduleProgramWrite(bytes);
  }

  /// Build a [TuiWheelEvent] for mouse-report wheel signals.
  ///
  /// Flutter [PointerScrollEvent] has no `wheelDeltaY`. Orca treats legacy-notched
  /// wheels as discrete (where [tuiScrollSensitivity] multiplies) and pure pixel
  /// streams as trackpad (1:1, ignore sensitivity). Approximate mouse notches as
  /// `abs(dy) >= 50` by synthesizing a one-notch legacy delta.
  TuiWheelEvent _mouseReportWheelEvent(
    double dyPx, {
    bool forceTrackpad = false,
  }) {
    const discretePixelMin = 50.0;
    const legacyNotch = 120.0;
    final absDy = dyPx.abs();
    return TuiWheelEvent(
      deltaY: dyPx,
      deltaMode: TuiWheelDeltaMode.pixel,
      timeStampMs: _nextTuiWheelTimeMs(),
      // Batched trackpad sums can exceed the discrete pixel threshold; never
      // synthesize a legacy notch in that path or distance compresses wrongly.
      legacyWheelDeltaY: forceTrackpad
          ? null
          : (absDy >= discretePixelMin ? dyPx.sign * legacyNotch : null),
    );
  }

  double _nextTuiWheelTimeMs() {
    // Why: burst/cadence math needs strictly increasing stamps; frame time is
    // unavailable outside a Flutter frame (unit tests / idle pointer path).
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    if (now > _tuiWheelTimeMs) {
      _tuiWheelTimeMs = now;
      return _tuiWheelTimeMs;
    }
    _tuiWheelTimeMs += 1;
    return _tuiWheelTimeMs;
  }

  final BytesBuilder _pendingProgramBytes = BytesBuilder(copy: false);
  bool _programScheduled = false;

  void _scheduleProgramWrite(Uint8List bytes) {
    TerminalScrollTrace.log(
      'controller',
      'scheduleProgramWrite ${bytes.length}B ${String.fromCharCodes(bytes.take(32)).replaceAll('\x1b', 'ESC')}',
    );
    _pendingProgramBytes.add(bytes);
    if (_programScheduled) return;
    // Why: latency start = first enqueue of a program-scroll batch (locked method).
    TerminalScrollLatency.markScheduleWrite();
    _programScheduled = true;
    engine.scheduleTask(_flushProgram);
  }

  void _flushProgram() {
    _programScheduled = false;
    if (_pendingProgramBytes.isEmpty) return;
    engine.scheduleWrite(_pendingProgramBytes.toBytes());
    _pendingProgramBytes.clear();
  }

  void _scheduleHistoryFlush() {
    if (_historyScheduled || _historyScrollInFlight) return;
    _historyScheduled = true;
    engine.scheduleTask(() => unawaited(_flushHistoryScroll()));
  }

  void _scheduleHistoryPixels(double deltaPx) {
    if (deltaPx != 0) _pendingHistoryPx += deltaPx;
    _scheduleHistoryFlush();
  }

  /// Serializes wheel line scroll and pan pixel scroll on one queue so
  /// `scroll_lines` never races `scroll_pixels` on the engine.
  Future<void> _flushHistoryScroll() async {
    if (_historyScrollInFlight) return;
    _historyScrollInFlight = true;
    _historyScheduled = false;
    final gen = _historyGeneration;
    try {
      while (_pendingHistoryLines != 0 || _pendingHistoryPx != 0) {
        if (gen != _historyGeneration) break;

        if (_pendingHistoryLines != 0) {
          final lines = _pendingHistoryLines;
          _pendingHistoryLines = 0;
          TerminalScrollTrace.log(
            'controller',
            'flushHistoryLines net=$lines ${_posSnapshot()}',
          );
          await _applyHistoryLineScroll(lines, generation: gen);
          if (gen != _historyGeneration) break;
          TerminalScrollTrace.log(
            'controller',
            'flushHistoryLines done ${_posSnapshot()}',
          );
          continue;
        }

        if (_pendingHistoryPx != 0) {
          final px = _pendingHistoryPx;
          _pendingHistoryPx = 0;
          await _applyHistoryPanPixels(px, generation: gen);
          if (gen != _historyGeneration) break;
        }
      }
    } finally {
      _historyScrollInFlight = false;
      if (_pendingHistoryLines != 0 || _pendingHistoryPx != 0) {
        _scheduleHistoryFlush();
      }
      _notifyHistoryIdle();
    }
  }

  Future<void> _applyHistoryPanPixels(
    double px, {
    required int generation,
  }) async {
    if (px == 0) return;
    if (generation != _historyGeneration) return;

    final grid = engine.grid;
    final pos = grid.displayOffset + grid.scrollFraction;
    final cellH = _accumulator.cellHeight;

    if (px < 0) {
      if (pos <= 0) {
        stopFling();
        return;
      }
      // Large fling toward live bottom: skip incremental scroll_pixels FFI.
      if (cellH > 0 && pos + px / cellH <= 0) {
        TerminalScrollTrace.log(
          'controller',
          'pan snap→bottom px=${px.toStringAsFixed(1)} pos=${pos.toStringAsFixed(3)}',
        );
        await engine.scrollToBottomSnap();
        if (generation != _historyGeneration) return;
        stopFling();
        return;
      }
    } else if (px > 0 && grid.historySize > 0) {
      if (pos >= grid.historySize) {
        stopFling();
        return;
      }
      if (cellH > 0 && pos + px / cellH >= grid.historySize) {
        TerminalScrollTrace.log(
          'controller',
          'pan snap→top px=${px.toStringAsFixed(1)} pos=${pos.toStringAsFixed(3)}',
        );
        await engine.scrollToTopSnap();
        if (generation != _historyGeneration) return;
        stopFling();
        return;
      }
    }

    TerminalScrollTrace.log(
      'controller',
      'flushHistoryPixels px=${px.toStringAsFixed(1)} ${_posSnapshot()}',
    );

    if (generation != _historyGeneration) return;
    await engine.scrollPixels(px);
    if (generation != _historyGeneration) return;

    final after = engine.grid;
    final posAfter = after.displayOffset + after.scrollFraction;
    if (px < 0 && posAfter <= 0) {
      stopFling();
    } else if (px > 0 &&
        after.historySize > 0 &&
        posAfter >= after.historySize) {
      stopFling();
    }
  }

  /// Whole-line history scroll with hard snap at the edges (VTE
  /// `scroll_to_bottom` / `scroll_to_top` semantics).
  Future<void> _applyHistoryLineScroll(
    int lines, {
    required int generation,
  }) async {
    if (lines == 0) return;
    if (generation != _historyGeneration) return;

    final grid = engine.grid;
    final pos = grid.displayOffset + grid.scrollFraction;

    if (lines < 0) {
      if (pos + lines <= 0) {
        TerminalScrollTrace.log(
          'controller',
          'apply snap→bottom lines=$lines pos=${pos.toStringAsFixed(3)}',
        );
        await engine.scrollToBottomSnap();
        return;
      }
    } else {
      final hist = grid.historySize;
      if (hist > 0 && pos + lines >= hist) {
        TerminalScrollTrace.log(
          'controller',
          'apply snap→top lines=$lines pos=${pos.toStringAsFixed(3)} hist=$hist',
        );
        await engine.scrollToTopSnap();
        return;
      }
    }
    TerminalScrollTrace.log(
      'controller',
      'apply scrollLines($lines) pos=${pos.toStringAsFixed(3)}',
    );
    if (generation != _historyGeneration) return;
    await engine.scrollLines(lines);
  }

  String _posSnapshot() {
    final g = engine.grid;
    return TerminalScrollTrace.pos(
      displayOffset: g.displayOffset,
      scrollFraction: g.scrollFraction,
      historySize: g.historySize,
    );
  }

  void dispose() {
    cancelPendingHistory();
    stopFling();
  }

  void startFling({
    required double velocityPxPerSec,
    required double deceleration,
    required bool shiftHeld,
    required Ticker Function(TickerCallback) createTicker,
  }) {
    stopFling();
    if (velocityPxPerSec.abs() < 80) return;
    _flingVelocity = velocityPxPerSec;
    _flingDecel = deceleration;
    _flingShiftHeld = shiftHeld;
    _flingLastTick = null;
    _flingTicker = createTicker(_onFlingTick)..start();
  }

  void stopFling() {
    _flingTicker?.dispose();
    _flingTicker = null;
    _flingVelocity = 0;
    _flingLastTick = null;
  }

  void _onFlingTick(Duration elapsed) {
    final last = _flingLastTick;
    if (last == null) {
      _flingLastTick = elapsed;
      return;
    }
    final dtMs = (elapsed - last).inMicroseconds / 1000.0;
    _flingLastTick = elapsed;
    if (dtMs <= 0) return;
    _flingVelocity *= math.pow(_flingDecel, dtMs).toDouble();
    if (_flingVelocity.abs() < 18) {
      stopFling();
      return;
    }
    final g = engine.grid;
    final pos = g.displayOffset + g.scrollFraction;
    final hist = g.historySize;
    if (pos <= 0 && _flingVelocity < 0) {
      TerminalScrollTrace.log('controller', 'fling stop at live bottom');
      stopFling();
      return;
    }
    if (hist > 0 && pos >= hist && _flingVelocity > 0) {
      TerminalScrollTrace.log('controller', 'fling stop at history top');
      stopFling();
      return;
    }
    onPanDelta(dyPx: _flingVelocity * dtMs / 1000.0, shiftHeld: _flingShiftHeld);
  }

  bool get isFlinging => _flingTicker != null;

  @visibleForTesting
  bool get historyScrollInFlight => _historyScrollInFlight;
}
