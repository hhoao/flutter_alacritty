import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/controller/terminal_search_options.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';

class _SlowBinding implements EngineBinding {
  final release = Completer<void>();
  int resizeCalls = 0;
  int lastCols = 0;
  int lastRows = 0;

  GridUpdate _empty({bool full = false}) => GridUpdate(
        full: full,
        rows: lastRows,
        columns: lastCols,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
      );

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    await release.future;
    return _empty();
  }

  @override
  void resize(int columns, int rows) {
    resizeCalls++;
    lastCols = columns;
    lastRows = rows;
  }

  @override
  GridUpdate fullSnapshot() => _empty(full: true);

  @override
  Future<void> advance(Uint8List b) async {}
  @override
  Future<GridUpdate> takeDamage() async => _empty();
  @override
  void pumpEvents() {}
  @override
  bool searchIsActive() => false;
  @override
  Future<GridUpdate> scrollLines(int d) async => _empty();
  @override
  Future<GridUpdate> scrollPixels(double d) async => _empty();
  @override
  Future<GridUpdate> scrollToBottom() async => _empty();
  @override
  Future<GridUpdate> scrollToTop() async => _empty();
  @override
  Future<GridUpdate> scrollToOffset(double offsetLines) async => _empty();
  @override
  void clearHistory() {}
  @override
  void reconfigure(EngineConfig c) {}
  @override
  void respondClipboardLoad(String t) {}
  @override
  void setCellPixels(int w, int h) {}
  @override
  void selectionStart(int r, int c, bool rh, int k) {}
  @override
  void selectionUpdate(int r, int c, bool rh) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  bool searchSet(
    String p, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) => false;
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() => _empty(full: true);
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

class _ScrollSlowBinding implements EngineBinding {
  final scrollRelease = Completer<void>();
  final advanceRelease = Completer<void>();
  int resizeCalls = 0;
  int lastCols = 0;
  int lastRows = 0;

  GridUpdate _empty({bool full = false}) => GridUpdate(
        full: full,
        rows: lastRows,
        columns: lastCols,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
      );

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    await advanceRelease.future;
    return _empty();
  }

  @override
  Future<GridUpdate> scrollLines(int delta) async {
    await scrollRelease.future;
    return _empty();
  }

  @override
  void resize(int columns, int rows) {
    resizeCalls++;
    lastCols = columns;
    lastRows = rows;
  }

  @override
  GridUpdate fullSnapshot() => _empty(full: true);

  @override
  Future<void> advance(Uint8List b) async {}
  @override
  Future<GridUpdate> takeDamage() async => _empty();
  @override
  void pumpEvents() {}
  @override
  bool searchIsActive() => false;
  @override
  Future<GridUpdate> scrollPixels(double d) async => _empty();
  @override
  Future<GridUpdate> scrollToBottom() async => _empty();
  @override
  Future<GridUpdate> scrollToTop() async => _empty();
  @override
  Future<GridUpdate> scrollToOffset(double offsetLines) async => _empty();
  @override
  void clearHistory() {}
  @override
  void reconfigure(EngineConfig c) {}
  @override
  void respondClipboardLoad(String t) {}
  @override
  void setCellPixels(int w, int h) {}
  @override
  void selectionStart(int r, int c, bool rh, int k) {}
  @override
  void selectionUpdate(int r, int c, bool rh) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  bool searchSet(
    String p, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) => false;
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() => _empty(full: true);
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resize during in-flight drain flushes engine and mirror immediately',
      () async {
    final binding = _SlowBinding();
    final grid = MirrorGrid()..initializeEmpty(24, 80);
    late void Function() drain;
    var ptyResizeCount = 0;

    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => drain = cb,
    );
    client.onPtyResize = (_, _) => ptyResizeCount++;

    client.feed(Uint8List.fromList([1]));
    drain();

    client.resize(120, 40);

    expect(binding.resizeCalls, 1);
    expect(binding.lastCols, 120);
    expect(ptyResizeCount, 1);
    expect(grid.columns, 120);

    binding.release.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('pty resize fires only after engine flush on immediate resize', () {
    final binding = _SlowBinding();
    final grid = MirrorGrid()..initializeEmpty(24, 80);
    var ptyResizeCount = 0;

    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
    );
    client.onPtyResize = (_, _) => ptyResizeCount++;

    client.resize(100, 30);

    expect(binding.resizeCalls, 1);
    expect(ptyResizeCount, 1);
    expect(grid.columns, 100);
  });

  test('resize during in-flight scrollLines flushes immediately', () async {
    final binding = _ScrollSlowBinding();
    final grid = MirrorGrid()..initializeEmpty(24, 80);
    var ptyResizeCount = 0;

    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
    );
    client.onPtyResize = (_, _) => ptyResizeCount++;

    unawaited(client.scrollLines(1));
    await Future<void>.delayed(Duration.zero);

    client.resize(120, 40);
    expect(binding.resizeCalls, 1);
    expect(binding.lastCols, 120);
    expect(ptyResizeCount, 1);
    expect(grid.columns, 120);

    binding.scrollRelease.complete();
    await Future<void>.delayed(Duration.zero);
  });
}
