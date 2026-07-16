import 'dart:typed_data';

import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_binding.dart';

/// Scripted binding: each [advanceAndTakeDamage] returns the next canned update.
///
/// Simulates the engine packing [kModeSynchronizedOutput] into `modeFlags`
/// (library-owned bit — not from alacritty `TermMode`).
class _SyncScriptBinding extends FakeBinding {
  _SyncScriptBinding(this.script);
  final List<GridUpdate> script;
  int advanceCount = 0;
  GridUpdate? lastAdvanced;
  bool searchActive = false;
  int plainSnapshotCalls = 0;
  int searchedSnapshotCalls = 0;
  GridUpdate? searchedSnapshot;

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    fedBytes.addAll(bytes);
    if (advanceCount >= script.length) {
      throw StateError('unexpected advance #${advanceCount + 1}');
    }
    lastAdvanced = script[advanceCount++];
    return lastAdvanced!;
  }

  /// Sync-end present uses a full snapshot so mid-sync partial damage is not lost.
  @override
  GridUpdate fullSnapshot() {
    plainSnapshotCalls++;
    return lastAdvanced ?? super.fullSnapshot();
  }

  @override
  bool searchIsActive() => searchActive;

  @override
  GridUpdate fullSnapshotSearched() {
    searchedSnapshotCalls++;
    return searchedSnapshot ?? lastAdvanced ?? super.fullSnapshot();
  }
}

GridUpdate _lineUpdate({
  required int modeFlags,
  required int codepoint,
  int cols = 4,
  int rows = 1,
}) {
  final cps = Uint32List(cols)..fillRange(0, cols, 32);
  cps[0] = codepoint;
  return GridUpdate(
    full: true,
    rows: rows,
    columns: cols,
    lines: [
      LineCells(
        line: 0,
        codepoints: cps,
        fg: Uint32List(cols)..fillRange(0, cols, 0xD8D8D8),
        bg: Uint32List(cols)..fillRange(0, cols, 0x181818),
        flags: Uint16List(cols),
      ),
    ],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: true,
    modeFlags: modeFlags,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('holds MirrorGrid apply while DEC 2026 synchronized output is active',
      () async {
    // CSI ?2026h … partial redraw … CSI ?2026l — engine sets/clears the
    // synthetic mode bit; client must not present mid-sync.
    final syncOn = _lineUpdate(
      modeFlags: kModeSynchronizedOutput,
      codepoint: 'A'.codeUnitAt(0),
    );
    final syncOff = _lineUpdate(
      modeFlags: 0,
      codepoint: 'B'.codeUnitAt(0),
    );
    final binding = _SyncScriptBinding([syncOn, syncOff]);
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 4);
    final gen0 = grid.generation;
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    // Sync start + partial redraw (content would be 'A').
    client.feed(Uint8List.fromList('\x1b[?2026hA'.codeUnits));
    expect(scheduled, hasLength(1));
    scheduled.removeAt(0)();
    await Future<void>.value();

    expect(binding.advanceCount, 1);
    expect(grid.generation, gen0, reason: 'must not apply while sync active');
    expect(grid.codepointAt(0, 0), 32);

    // Sync end — present once with final content.
    client.feed(Uint8List.fromList('\x1b[?2026l'.codeUnits));
    expect(scheduled, hasLength(1));
    scheduled.removeAt(0)();
    await Future<void>.value();

    expect(binding.advanceCount, 2);
    expect(grid.codepointAt(0, 0), 'B'.codeUnitAt(0));
    expect(grid.generation, greaterThan(gen0));
  });

  test('applies GridUpdate immediately when synchronized output is inactive',
      () async {
    final binding = _SyncScriptBinding([
      _lineUpdate(modeFlags: 0, codepoint: 'Z'.codeUnitAt(0)),
    ]);
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 4);
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.feed(Uint8List.fromList([0x5a]));
    scheduled.single();
    await Future<void>.value();

    expect(grid.codepointAt(0, 0), 'Z'.codeUnitAt(0));
  });

  test('coalesces multiple sync-active updates into one present on sync end',
      () async {
    final mid1 = _lineUpdate(
      modeFlags: kModeSynchronizedOutput,
      codepoint: '1'.codeUnitAt(0),
    );
    final mid2 = _lineUpdate(
      modeFlags: kModeSynchronizedOutput,
      codepoint: '2'.codeUnitAt(0),
    );
    final end = _lineUpdate(
      modeFlags: 0,
      codepoint: '3'.codeUnitAt(0),
    );
    final binding = _SyncScriptBinding([mid1, mid2, end]);
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 4);
    final gen0 = grid.generation;
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.feed(Uint8List.fromList([1]));
    scheduled.removeAt(0)();
    await Future<void>.value();
    expect(grid.generation, gen0);

    client.feed(Uint8List.fromList([2]));
    scheduled.removeAt(0)();
    await Future<void>.value();
    expect(grid.generation, gen0);
    expect(grid.codepointAt(0, 0), 32);

    client.feed(Uint8List.fromList([3]));
    scheduled.removeAt(0)();
    await Future<void>.value();
    expect(grid.codepointAt(0, 0), '3'.codeUnitAt(0));
  });

  test('sync-end present uses searched snapshot when search is active', () async {
    final syncOn = _lineUpdate(
      modeFlags: kModeSynchronizedOutput,
      codepoint: 'A'.codeUnitAt(0),
    );
    final syncOff = _lineUpdate(
      modeFlags: 0,
      codepoint: 'B'.codeUnitAt(0),
    );
    final highlighted = _lineUpdate(
      modeFlags: 0,
      codepoint: 'H'.codeUnitAt(0),
    );
    final binding = _SyncScriptBinding([syncOn, syncOff])
      ..searchActive = true
      ..searchedSnapshot = highlighted;
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 4);
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.feed(Uint8List.fromList([1]));
    scheduled.removeAt(0)();
    await Future<void>.value();

    client.feed(Uint8List.fromList([2]));
    scheduled.removeAt(0)();
    await Future<void>.value();

    expect(binding.searchedSnapshotCalls, 1);
    expect(binding.plainSnapshotCalls, 0);
    expect(grid.codepointAt(0, 0), 'H'.codeUnitAt(0));
  });
}
