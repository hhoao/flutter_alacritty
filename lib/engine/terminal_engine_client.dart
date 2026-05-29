import 'dart:typed_data';

import 'package:flutter/scheduler.dart';

import '../render/mirror_grid.dart';
import 'engine_binding.dart';

/// Coalesces PTY output per frame and feeds it to the engine off the UI thread,
/// then applies the returned damage to the grid. A single advance is ever in
/// flight (`_advancing`), giving natural backpressure under heavy output.
class TerminalEngineClient {
  TerminalEngineClient({
    required EngineBinding binding,
    required MirrorGrid grid,
    void Function(void Function())? schedule,
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

  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _drainScheduled = false;
  bool _advancing = false;
  int? _pendingColumns;
  int? _pendingRows;
  int _pendingScrollDelta = 0;
  bool _scrollScheduled = false;
  bool _scrollApplying = false;
  bool _disposed = false;
  /// Re-applies the current viewport. Always uses the searched snapshot — the
  /// Rust side short-circuits to a plain snapshot when no search is active, so
  /// this is the same cost when idle and removes a class of Dart-side flag-
  /// desync bugs (e.g. a stale _searchActive after engine restart leaving
  /// match highlights stuck or absent).
  void refreshView() {
    _grid.apply(_binding.fullSnapshotSearched());
    SchedulerBinding.instance.scheduleFrame();
  }

  bool searchSet(String pattern) {
    final ok = _binding.searchSet(pattern);
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
    _buf.add(bytes);
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_drainScheduled || _advancing) return;
    _drainScheduled = true;
    _schedule(_drain);
  }

  Future<void> _drain() async {
    _drainScheduled = false;
    // Hold the advance guard across the WHOLE drain, including the scroll apply
    // below. Otherwise a feed() arriving during an awaited scroll/advance slips
    // past _scheduleDrain's (_drainScheduled || _advancing) gate and starts a
    // second overlapping advanceAndTakeDamage on the same engine.
    _advancing = true;
    try {
      // Apply coalesced scroll before ingesting PTY bytes. When scrolled back,
      // alacritty's scroll_up increases display_offset; deferring scroll until
      // after the drain lets output outrun wheel-down (can't reach the live end).
      await _applyPendingScroll();
      if (_buf.isEmpty) return;
      final batch = _buf.takeBytes();
      final update = await _binding.advanceAndTakeDamage(batch);
      _applyUpdate(update);
      _binding.pumpEvents(); // route PtyWrite/Title/Bell/Clipboard for this batch
    } finally {
      _advancing = false;
      _flushPendingResize();
    }
    if (_buf.isNotEmpty) _scheduleDrain();
  }

  void _applyUpdate(GridUpdate update) {
    if (!update.full &&
        _grid.columns > 0 &&
        update.lines.any((l) => l.codepoints.length != _grid.columns)) {
      // Engine resized before the mirror caught up — partial line width won't fit.
      _grid.apply(_binding.fullSnapshot());
      return;
    }
    _grid.apply(update);
  }

  void resize(int columns, int rows) {
    _pendingColumns = columns;
    _pendingRows = rows;
    if (!_advancing) {
      _flushPendingResize();
    }
    SchedulerBinding.instance.scheduleFrame();
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
  }

  Future<void> scrollLines(int delta) async {
    await _binding.scrollLines(delta);
    refreshView();
  }

  /// Coalesced scroll. Multiple calls within one scheduling tick aggregate
  /// into a single FFI scrollLines + refreshView. Use this for input-driven
  /// scroll paths (wheel, trackpad pan, touch fling) where the per-event
  /// snapshot rate would otherwise saturate the UI thread.
  ///
  /// Programmatic callers that need the future (PageUp/PageDown, ScrollTo*)
  /// should keep using [scrollLines] / [scrollToBottom] which await the
  /// underlying FFI.
  void scheduleScrollBy(int delta) {
    if (delta == 0 || _disposed) return;
    _pendingScrollDelta += delta;
    _ensureScrollScheduled();
  }

  /// Schedules a single post-frame [_applyPendingScroll] when scroll is pending
  /// and none is already queued. Idempotent — safe to call from
  /// [scheduleScrollBy] and from a flush's `finally`.
  void _ensureScrollScheduled() {
    if (_disposed || _scrollScheduled || _pendingScrollDelta == 0) return;
    _scrollScheduled = true;
    _schedule(() => _applyPendingScroll());
  }

  /// Applies the coalesced scroll accumulator. Called from the post-frame
  /// scheduler and at the start of [_drain] so user scroll wins over PTY
  /// output in the same frame.
  ///
  /// Re-entrancy is serialized by [_scrollApplying]: if a flush is already in
  /// flight this is a no-op, and the in-flight flush's `finally` re-arms for
  /// any delta that accumulated meanwhile — so a scheduled callback that fires
  /// mid-flush is never lost (which would otherwise strand the accumulator with
  /// [_scrollScheduled] stuck true and no callback queued).
  Future<void> _applyPendingScroll() async {
    _scrollScheduled = false;
    if (_disposed || _pendingScrollDelta == 0 || _scrollApplying) return;
    final delta = _pendingScrollDelta;
    _pendingScrollDelta = 0;
    _scrollApplying = true;
    try {
      await _binding.scrollLines(delta);
      if (!_disposed) refreshView();
    } finally {
      _scrollApplying = false;
      _ensureScrollScheduled();
    }
  }

  Future<void> scrollToBottom() async {
    await _binding.scrollToBottom();
    refreshView();
  }

  void clearHistory() {
    _binding.clearHistory();
    refreshView();
  }

  /// Drain terminal→host events synchronously (e.g. OSC 52 paste reply).
  void pumpEventsNow() => _binding.pumpEvents();

  void dispose() {
    _disposed = true;
    _binding.dispose();
  }
}
