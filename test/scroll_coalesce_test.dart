import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

class _CountingFakeBinding implements EngineBinding {
  int scrollLinesCalls = 0;
  final List<int> scrollLinesArgs = [];
  int snapshotCalls = 0;

  GridUpdate _empty() => GridUpdate(
        full: true,
        rows: 0,
        columns: 0,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: false,
      );

  @override
  Future<void> scrollLines(int delta) async {
    scrollLinesCalls++;
    scrollLinesArgs.add(delta);
  }

  @override
  GridUpdate fullSnapshotSearched() {
    snapshotCalls++;
    return _empty();
  }

  @override
  GridUpdate fullSnapshot() => _empty();
  @override
  Future<void> advance(Uint8List bytes) async {}
  @override
  Future<GridUpdate> takeDamage() async => _empty();
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async => _empty();
  @override
  void pumpEvents() {}
  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> scrollToBottom() async {}
  @override
  void clearHistory() {}
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) {}
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  bool searchSet(String pattern) => false;
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('multiple scheduleScrollBy in one tick → 1 FFI scrollLines + 1 snapshot',
      () async {
    final binding = _CountingFakeBinding();
    final grid = MirrorGrid();
    late void Function() pending;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) {
        pending = cb;
      },
    );

    client.scheduleScrollBy(3);
    client.scheduleScrollBy(3);
    client.scheduleScrollBy(-1);
    expect(binding.scrollLinesCalls, 0);
    expect(binding.snapshotCalls, 0);

    pending();
    await Future<void>.value();

    expect(binding.scrollLinesCalls, 1);
    expect(binding.scrollLinesArgs.single, 5);
    expect(binding.snapshotCalls, 1);
  });

  test('coalesced delta sums linearly before engine clamp', () async {
    final binding = _CountingFakeBinding();
    final grid = MirrorGrid();
    late void Function() pending;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pending = cb,
    );

    client.scheduleScrollBy(10);
    client.scheduleScrollBy(-3);
    pending();
    await Future<void>.value();

    expect(binding.scrollLinesArgs.single, 7);
  });

  test('a new scheduleScrollBy after flush starts a fresh batch', () async {
    final binding = _CountingFakeBinding();
    final grid = MirrorGrid();
    final pending = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pending.add(cb),
    );

    client.scheduleScrollBy(2);
    pending.removeAt(0)();
    await Future<void>.value();

    client.scheduleScrollBy(4);
    pending.removeAt(0)();
    await Future<void>.value();

    expect(binding.scrollLinesCalls, 2);
    expect(binding.scrollLinesArgs, [2, 4]);
    expect(binding.snapshotCalls, 2);
  });

  test('scheduleScrollBy during in-flight flush schedules a second batch',
      () async {
    final binding = _DeferredScrollBinding();
    final grid = MirrorGrid();
    final pending = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pending.add(cb),
    );

    client.scheduleScrollBy(3);
    pending.removeAt(0)();
    client.scheduleScrollBy(5);
    binding.completeScroll();
    await Future<void>.value();
    pending.removeAt(0)();
    binding.completeScroll();
    await Future<void>.value();

    expect(binding.scrollLinesArgs, [3, 5]);
    expect(binding.snapshotCalls, 2);
  });

  test('a callback firing mid-flush re-arms instead of stranding the delta',
      () async {
    final binding = _DeferredScrollBinding();
    final grid = MirrorGrid();
    final pending = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pending.add(cb),
    );

    // Batch 1 begins; its FFI stays in flight (completer not yet completed).
    client.scheduleScrollBy(3);
    pending.removeAt(0)();
    expect(binding.scrollLinesArgs, [3]);

    // A new delta arrives mid-flight and schedules a second callback.
    client.scheduleScrollBy(5);
    expect(pending.length, 1);

    // The second callback fires WHILE batch 1's FFI is still in flight. Under
    // the old guard it was silently consumed and the in-flight `finally`
    // declined to re-arm (because _scrollScheduled was stuck true), permanently
    // stranding the +5. It must now be a no-op deferring to the in-flight flush.
    pending.removeAt(0)();
    expect(pending, isEmpty);

    // Completing batch 1 must re-arm a callback for the residual +5.
    binding.completeScroll();
    await Future<void>.value();
    expect(pending.length, 1, reason: 'residual scroll re-armed, not stranded');

    // Drain the re-armed callback → the +5 finally reaches the engine.
    pending.removeAt(0)();
    binding.completeScroll();
    await Future<void>.value();

    expect(binding.scrollLinesArgs, [3, 5]);
    expect(binding.snapshotCalls, 2);
  });

  test('pending scroll applies before drain ingests PTY output', () async {
    final binding = _ScrollOffsetFakeBinding();
    final grid = MirrorGrid();
    late void Function() pendingDrain;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) {
        pendingDrain = cb;
      },
    );

    // User scrolled back; wheel-down is pending for post-frame.
    client.scheduleScrollBy(-5);
    // Same frame: installer output arrives (increases offset when scrolled back).
    client.feed(Uint8List.fromList([0x6c, 0x73])); // "ls"

    pendingDrain();
    await Future<void>.value();

    // Scroll must run before advance: 10 - 5 + 1 = 6, not (10 + 1) - 5.
    expect(binding.displayOffset, 6);
    expect(binding.scrollLinesArgs, [-5]);
  });

  test('flush after dispose is a no-op', () async {
    final binding = _CountingFakeBinding();
    final grid = MirrorGrid();
    late void Function() pending;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pending = cb,
    );

    client.scheduleScrollBy(3);
    client.dispose();
    pending();
    await Future<void>.value();

    expect(binding.scrollLinesCalls, 0);
    expect(binding.snapshotCalls, 0);
  });
}

/// Simulates alacritty scroll_up bumping display_offset while scrolled back.
class _ScrollOffsetFakeBinding extends _CountingFakeBinding {
  int displayOffset = 10;

  @override
  Future<void> scrollLines(int delta) async {
    await super.scrollLines(delta);
    displayOffset =
        (displayOffset + delta).clamp(0, 100);
  }

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    if (displayOffset > 0) {
      displayOffset += 1; // one scroll_up line while viewing history
    }
    return super.advanceAndTakeDamage(bytes);
  }

  @override
  GridUpdate fullSnapshotSearched() {
    snapshotCalls++;
    final u = super.fullSnapshotSearched();
    return GridUpdate(
      full: u.full,
      rows: u.rows,
      columns: u.columns,
      lines: u.lines,
      cursorRow: u.cursorRow,
      cursorCol: u.cursorCol,
      cursorVisible: u.cursorVisible,
      displayOffset: displayOffset,
    );
  }
}

class _DeferredScrollBinding extends _CountingFakeBinding {
  Completer<void>? _scrollCompleter;

  @override
  Future<void> scrollLines(int delta) {
    scrollLinesCalls++;
    scrollLinesArgs.add(delta);
    _scrollCompleter = Completer<void>();
    return _scrollCompleter!.future;
  }

  void completeScroll() {
    _scrollCompleter?.complete();
    _scrollCompleter = null;
  }
}
