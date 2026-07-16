import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../debug/terminal_scroll_trace.dart';
import '../input/term_mode.dart';
import '../render/mirror_grid.dart';
import '../src/rust/terminal_raster_present.dart';
import '../controller/terminal_search_options.dart';
import 'engine_binding.dart';

/// Coalesces PTY output per frame and feeds it to the engine off the UI thread,
/// then applies the returned damage to the grid. A single advance is ever in
/// flight (`_advancing`), giving natural backpressure under heavy output.
class TerminalEngineClient {
  TerminalEngineClient({
    required EngineBinding binding,
    required MirrorGrid grid,
    void Function(void Function())? schedule,
    this.onRasterPresent,
  })  : _binding = binding,
        _grid = grid,
        _schedule = schedule ??
            ((cb) {
              final binding = SchedulerBinding.instance;
              binding.addPostFrameCallback((_) => cb());
              // A post-frame callback only fires if a frame is actually produced.
              // Request one so sporadic output/input (e.g. a single keystroke's
              // echo) refreshes even when the UI is otherwise idle.
              binding.scheduleFrame();
            });

  final EngineBinding _binding;
  EngineBinding get binding => _binding;
  final MirrorGrid _grid;
  final void Function(void Function()) _schedule;

  /// When set, hot-path advances/scrolls use Rust-raster present (no full
  /// LineUpdate mirror). Selection/search still call [refreshView].
  void Function(RasterPresentFrame frame)? onRasterPresent;

  /// When true, use raster present APIs and chrome-only mirror applies.
  bool useRasterPresent = false;

  RasterPresentBinding? get _raster {
    final b = _binding;
    return b is RasterPresentBinding ? b as RasterPresentBinding : null;
  }

  bool get _rasterHotPath =>
      useRasterPresent && onRasterPresent != null && _raster != null;

  /// After user interaction (keys / program writes), drain ASAP via microtask
  /// for this window instead of waiting for the idle post-frame scheduler.
  static const interactiveWindow = Duration(milliseconds: 100);

  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _drainScheduled = false;
  bool _advancing = false;
  DateTime? _interactiveUntil;
  int? _pendingColumns;
  int? _pendingRows;
  bool _disposed = false;

  /// When true, DEC 2026 synchronized output is active and MirrorGrid presents
  /// are deferred until the mode clears (then one full snapshot).
  bool _syncOutputActive = false;

  /// Opens (or extends) the interactive drain window so PTY output following
  /// user input is scheduled via microtask rather than post-frame idle.
  void markInteractive([DateTime? now]) {
    if (_disposed) return;
    final t = now ?? DateTime.now();
    _interactiveUntil = t.add(interactiveWindow);
    if (_buf.isNotEmpty) _scheduleDrain(forceImmediate: true);
  }

  bool get _isInteractive =>
      _interactiveUntil != null && DateTime.now().isBefore(_interactiveUntil!);

  /// Fired only from [_flushPendingResize], after the engine reflow and mirror
  /// snapshot complete. Host wires this to `PtyBackend.resize`.
  void Function(int columns, int rows)? onPtyResize;

  /// Re-applies the current viewport. Uses [EngineBinding.searchIsActive] to
  /// pick [fullSnapshotSearched] vs [fullSnapshot] so search highlights stay
  /// in sync with the engine without a stale Dart-side search flag.
  ///
  /// Also used for selection/a11y/copy — always ships a full cell mirror even
  /// when [useRasterPresent] is on.
  void refreshView() {
    if (_disposed) return;
    if (_rasterHotPath) {
      final frame = _raster!.fullRasterPresent();
      _applyRasterChrome(frame);
      onRasterPresent!(frame);
      // Selection/search/a11y need the Dart cell mirror on demand.
      final update = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(update);
    } else {
      final update = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(update);
    }
    try {
      SchedulerBinding.instance.scheduleFrame();
    } on Object {
      // Headless tests without a scheduler binding.
    }
  }

  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) {
    final ok = _binding.searchSet(pattern, options: options);
    refreshView();
    return ok;
  }

  bool searchNext() {
    final ok = _binding.searchNext();
    refreshView();
    return ok;
  }

  bool searchPrev() {
    final ok = _binding.searchPrev();
    refreshView();
    return ok;
  }

  void searchClear() {
    _binding.searchClear();
    refreshView();
  }

  String? resolveHyperlink(int id) => _binding.resolveHyperlink(id);

  void feed(Uint8List bytes) {
    if (_disposed) return;
    _buf.add(bytes);
    _scheduleDrain();
  }

  void _scheduleDrain({bool forceImmediate = false}) {
    if (_drainScheduled || _advancing) return;
    _drainScheduled = true;
    if (forceImmediate || _isInteractive) {
      scheduleMicrotask(_drain);
    } else {
      _schedule(_drain);
    }
  }

  Future<void> _drain() async {
    _drainScheduled = false;
    if (_disposed) return;
    // Hold the advance guard across the WHOLE drain, including the scroll apply
    // below. Otherwise a feed() arriving during an awaited scroll/advance slips
    // past _scheduleDrain's (_drainScheduled || _advancing) gate and starts a
    // second overlapping advanceAndTakeDamage on the same engine.
    _advancing = true;
    try {
      if (_pendingColumns != null || _pendingRows != null) {
        _flushPendingResize();
      }
      if (_disposed || _buf.isEmpty) return;
      final batch = _buf.takeBytes();
      if (_rasterHotPath) {
        final frame = await _raster!.advanceAndTakeRasterPresent(batch);
        if (_disposed) return;
        _applyRasterFrame(frame);
      } else {
        final update = await _binding.advanceAndTakeDamage(batch);
        if (_disposed) return;
        _applyUpdate(update);
      }
      if (_disposed) return;
      _binding.pumpEvents(); // route PtyWrite/Title/Bell/Clipboard for this batch
    } finally {
      _advancing = false;
      if (!_disposed) _flushPendingResize();
    }
    if (!_disposed && _buf.isNotEmpty) _scheduleDrain();
  }

  void _applyUpdate(GridUpdate update) {
    if (_disposed) return;
    if (!update.full &&
        _grid.columns > 0 &&
        update.lines.any((l) => l.codepoints.length != _grid.columns)) {
      // Engine resized before the mirror caught up — partial line width won't fit.
      update = _binding.fullSnapshot();
    }

    // DEC 2026: hold present while synchronized output is active. Mid-sync
    // damage is partial across advances, so on clear take one full snapshot.
    if (synchronizedOutput(update.modeFlags)) {
      _syncOutputActive = true;
      return;
    }
    if (_syncOutputActive) {
      _syncOutputActive = false;
      // Match [refreshView]: keep search match flags when search is active.
      final snap = _binding.searchIsActive()
          ? _binding.fullSnapshotSearched()
          : _binding.fullSnapshot();
      _grid.apply(snap);
      return;
    }
    _grid.apply(update);
  }

  /// Chrome-only mirror apply + raster upload (skips LineUpdate cell mirrors).
  void _applyRasterFrame(RasterPresentFrame frame) {
    if (synchronizedOutput(frame.modeFlags)) {
      _syncOutputActive = true;
      return;
    }
    if (_syncOutputActive) {
      _syncOutputActive = false;
      refreshView();
      return;
    }
    _applyRasterChrome(frame);
    onRasterPresent?.call(frame);
    try {
      SchedulerBinding.instance.scheduleFrame();
    } on Object {
      // Headless tests without a scheduler binding.
    }
  }

  void _applyRasterChrome(RasterPresentFrame frame) {
    _grid.apply(
      GridUpdate(
        full: false,
        rows: 0,
        columns: 0,
        lines: const [],
        cursorRow: frame.cursorLine,
        cursorCol: frame.cursorCol,
        cursorVisible: frame.cursorVisible,
        cursorShape: frame.cursorShape,
        cursorBlinking: frame.cursorBlinking,
        modeFlags: frame.modeFlags,
        displayOffset: frame.displayOffset,
        historySize: frame.historySize,
        defaultFg: frame.defaultFg,
        defaultBg: frame.defaultBg,
        cursorColor: frame.cursorColor,
        scrollFraction: frame.scrollFraction,
        scrollLineDelta: 0,
      ),
    );
  }

  void resize(int columns, int rows) {
    if (_disposed) return;
    _pendingColumns = columns;
    _pendingRows = rows;
    // Always flush synchronously so MirrorGrid tracks LayoutBuilder even while
    // a PTY drain is in flight (avoids painter clearing a viewport-sized area
    // but only drawing the stale grid row count).
    _flushPendingResize();
  }

  void _flushPendingResize() {
    final columns = _pendingColumns;
    final rows = _pendingRows;
    if (columns == null || rows == null) return;
    _pendingColumns = null;
    _pendingRows = null;
    _binding.resize(columns, rows);
    // Engine resize sets TermDamage::Full; sync snapshot keeps MirrorGrid in sync.
    refreshView();
    _schedulePtyResize(columns, rows);
  }

  void _schedulePtyResize(int columns, int rows) {
    void fire() => onPtyResize?.call(columns, rows);
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.persistentCallbacks ||
          phase == SchedulerPhase.midFrameMicrotasks) {
        SchedulerBinding.instance.addPostFrameCallback((_) => fire());
        return;
      }
    } on Object {
      // Headless tests without a scheduler binding.
    }
    fire();
  }

  Future<void> scrollLines(int delta) async {
    TerminalScrollTrace.log(
      'client',
      'scrollLines($delta) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      _applyRasterFrame(await _raster!.scrollLinesRaster(delta));
    } else {
      _applyScrollUpdate(await _binding.scrollLines(delta));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollLines($delta) after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollPixels(double deltaPx) async {
    TerminalScrollTrace.log(
      'client',
      'scrollPixels(${deltaPx.toStringAsFixed(1)}) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      _applyRasterFrame(await _raster!.scrollPixelsRaster(deltaPx));
    } else {
      _applyScrollUpdate(await _binding.scrollPixels(deltaPx));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollPixels(${deltaPx.toStringAsFixed(1)}) after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToBottom() async {
    TerminalScrollTrace.log(
      'client',
      'scrollToBottom before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      _applyRasterFrame(await _raster!.scrollToBottomRaster());
    } else {
      _applyScrollUpdate(await _binding.scrollToBottom());
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToBottom after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToTop() async {
    TerminalScrollTrace.log(
      'client',
      'scrollToTop before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      _applyRasterFrame(await _raster!.scrollToTopRaster());
    } else {
      _applyScrollUpdate(await _binding.scrollToTop());
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToTop after ${_gridPosSnapshot()}',
    );
  }

  Future<void> scrollToOffset(double offsetLines) async {
    TerminalScrollTrace.log(
      'client',
      'scrollToOffset($offsetLines) before ${_gridPosSnapshot()}',
    );
    if (_rasterHotPath) {
      _applyRasterFrame(await _raster!.scrollToOffsetRaster(offsetLines));
    } else {
      _applyScrollUpdate(await _binding.scrollToOffset(offsetLines));
    }
    TerminalScrollTrace.log(
      'client',
      'scrollToOffset($offsetLines) after ${_gridPosSnapshot()}',
    );
  }

  void _applyScrollUpdate(GridUpdate update) {
    if (_disposed) return;
    _applyUpdate(update);
    SchedulerBinding.instance.scheduleFrame();
  }

  void clearHistory() {
    _binding.clearHistory();
    refreshView();
  }

  /// Drain terminal→host events synchronously (e.g. OSC 52 paste reply).
  void pumpEventsNow() => _binding.pumpEvents();

  /// Runs any pending PTY ingest immediately. For unit/widget tests that do not
  /// pump frames (the default [schedule] uses post-frame callbacks).
  @visibleForTesting
  Future<void> drainForTest() async {
    while (_buf.isNotEmpty || _drainScheduled || _advancing) {
      if (_drainScheduled || _buf.isNotEmpty) {
        await _drain();
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _binding.dispose();
  }

  String _gridPosSnapshot() => TerminalScrollTrace.pos(
        displayOffset: _grid.displayOffset,
        scrollFraction: _grid.scrollFraction,
        historySize: _grid.historySize,
      );
}
