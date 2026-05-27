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
  final MirrorGrid _grid;
  final void Function(void Function()) _schedule;

  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _drainScheduled = false;
  bool _advancing = false;
  int? _pendingColumns;
  int? _pendingRows;

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
    if (_buf.isEmpty) return;
    _advancing = true;
    final batch = _buf.takeBytes();
    try {
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
    _grid.apply(_binding.fullSnapshot());
  }

  Future<void> scrollLines(int delta) async {
    await _binding.scrollLines(delta);
    _grid.apply(await _binding.takeDamage()); // scrolled -> full snapshot
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> scrollToBottom() async {
    await _binding.scrollToBottom();
  }

  void dispose() => _binding.dispose();
}
