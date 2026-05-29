import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

class _SearchFake implements EngineBinding {
  String? lastSet;
  int searchedSnapshots = 0;
  bool cleared = false;
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
  bool searchSet(String p) {
    lastSet = p;
    return true;
  }

  @override
  bool searchNext() => true;
  @override
  bool searchPrev() => true;
  @override
  void searchClear() {
    cleared = true;
  }

  @override
  GridUpdate fullSnapshotSearched() {
    searchedSnapshots++;
    return _empty();
  }

  @override
  GridUpdate fullSnapshot() => _empty();
  @override
  Future<void> advance(Uint8List b) async {}
  @override
  Future<GridUpdate> takeDamage() async => _empty();
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List b) async => _empty();
  @override
  void pumpEvents() {}
  @override
  void resize(int c, int r) {}
  @override
  Future<void> scrollLines(int d) async {}
  @override
  Future<void> scrollToBottom() async {}
  @override
  void clearHistory() {}
  @override
  void selectionStart(int r, int c, bool rh, int k) {}
  @override
  void selectionUpdate(int r, int c, bool rh) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

class _FakeBinding implements EngineBinding {
  int advanceCalls = 0;
  int resizeCalls = 0;
  int lastResizeCols = 0;
  int lastResizeRows = 0;
  final List<int> totalBytes = [];
  @override
  Future<void> advance(Uint8List bytes) async {
    advanceCalls++;
    totalBytes.addAll(bytes);
  }
  @override
  Future<GridUpdate> takeDamage() async => GridUpdate(
      full: false, rows: 1, columns: 1, lines: const [],
      cursorRow: 0, cursorCol: 0, cursorVisible: true);
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    await advance(bytes);
    return takeDamage();
  }
  @override
  void pumpEvents() {}
  @override
  void resize(int columns, int rows) {
    resizeCalls++;
    lastResizeCols = columns;
    lastResizeRows = rows;
  }
  @override
  GridUpdate fullSnapshot() => GridUpdate(
        full: true,
        rows: lastResizeRows,
        columns: lastResizeCols,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
      );
  @override
  Future<void> scrollLines(int delta) async {}
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
  GridUpdate fullSnapshotSearched() => fullSnapshot();
  @override
  String? resolveHyperlink(int id) => null;
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bursts within one frame coalesce into a single advance', () async {
    final binding = _FakeBinding();
    final grid = MirrorGrid();
    late void Function() pendingDrain;
    var scheduled = false;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) { scheduled = true; pendingDrain = cb; },
    );

    client.feed(Uint8List.fromList([1, 2]));
    client.feed(Uint8List.fromList([3]));
    client.feed(Uint8List.fromList([4, 5]));
    expect(scheduled, isTrue);

    pendingDrain(); // simulate the post-frame callback
    await Future<void>.delayed(Duration.zero);

    expect(binding.advanceCalls, 1);
    expect(binding.totalBytes, [1, 2, 3, 4, 5]);
  });

  test('drain apply bumps grid generation', () async {
    final binding = _FakeBinding();
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 1);
    late void Function() pendingDrain;
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => pendingDrain = cb,
    );
    final gen0 = grid.generation;

    client.feed(Uint8List.fromList([1]));
    pendingDrain();
    await Future<void>.delayed(Duration.zero);

    expect(grid.generation, greaterThan(gen0));
  });

  test('resize applies full snapshot dimensions to grid', () {
    final binding = _FakeBinding();
    final grid = MirrorGrid();
    grid.initializeEmpty(5, 20);
    final client = TerminalEngineClient(binding: binding, grid: grid);

    client.resize(40, 10);

    expect(binding.resizeCalls, 1);
    expect(binding.lastResizeCols, 40);
    expect(binding.lastResizeRows, 10);
    expect(grid.rows, 10);
    expect(grid.columns, 40);
  });

  test('searchSet activates the searched snapshot and refreshes', () async {
    final binding = _SearchFake();
    final grid = MirrorGrid();
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
    );
    client.searchSet('foo');
    expect(binding.lastSet, 'foo');
    expect(binding.searchedSnapshots, 1);
    client.searchClear();
    expect(binding.cleared, isTrue);
  });
}
