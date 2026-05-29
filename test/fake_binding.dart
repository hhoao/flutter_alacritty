import 'dart:typed_data';

import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

/// Shared fake [EngineBinding] used by widget/integration-style tests that
/// drive `ExampleTerminalApp` / `TerminalEngine` without the native engine.
/// Lifted out of `terminal_lifecycle_test.dart` so other tests (e.g.
/// `terminal_engine_test.dart`) can reuse the same shape.
class FakeBinding implements RewireableEngineBinding {
  int scrollCalls = 0;
  final List<int> scrollLinesArgs = [];
  int selStartCalls = 0;
  int selClearCalls = 0;
  int scrollToBottomCalls = 0;
  int fullSnapshotCalls = 0;
  int resizeCalls = 0;
  int lastResizeCols = 0;
  int lastResizeRows = 0;

  /// Forwarded into emitted GridUpdates so tests can flip kModeBracketedPaste
  /// etc. on the mirror grid via the existing refresh path.
  int modeFlags = 0;
  final Map<(int, int), int> hyperlinkAt = {};
  final Map<int, String> hyperlinkUris = {};

  /// Events the next [pumpEvents] should dispatch. Each entry is one of:
  ///   `('pty', Uint8List)`, `('title', String)`, `('reset_title', null)`,
  ///   `('bell', null)`, `('clipboard', String)`.
  /// The queue is drained on each [pumpEvents] call.
  final List<(String, Object?)> pendingEvents = [];

  GridUpdate _blank() => GridUpdate(
        full: true,
        rows: 1,
        columns: 1,
        lines: [
          LineCells(
            line: 0,
            codepoints: Int32List(1),
            fg: Int32List(1),
            bg: Int32List(1),
            flags: Uint16List(1),
          ),
        ],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
        modeFlags: modeFlags,
      );

  GridUpdate _hyperlinkSnapshot() {
    const cols = 80, rows = 24;
    final hyperlinks = Int32List(cols);
    final flags = Uint16List(cols);
    hyperlinkAt.forEach((rc, id) {
      if (rc.$1 == 0 && rc.$2 < cols) {
        hyperlinks[rc.$2] = id;
        flags[rc.$2] = kFlagHyperlink;
      }
    });
    final line0 = LineCells(
      line: 0,
      codepoints: Int32List(cols)..fillRange(0, cols, 32),
      fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Int32List(cols)..fillRange(0, cols, 0x181818),
      flags: flags,
      hyperlinkId: hyperlinks,
    );
    LineCells blank(int i) => LineCells(
          line: i,
          codepoints: Int32List(cols)..fillRange(0, cols, 32),
          fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Int32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Int32List(cols),
        );
    return GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [line0, for (var i = 1; i < rows; i++) blank(i)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      modeFlags: modeFlags,
    );
  }

  /// Hook used by `TerminalEngine.fromBinding` to deliver engine-side events
  /// (Title/Bell/PtyWrite/Clipboard). Set by the engine; default is a no-op so
  /// existing widget-tests (which only drive the binding indirectly) keep
  /// working unchanged.
  void Function(Uint8List)? onPtyWrite;
  void Function(String)? onTitle;
  void Function()? onBell;
  void Function(String)? onClipboard;

  @override
  Future<void> advance(Uint8List bytes) async {}
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async => _blank();
  @override
  Future<GridUpdate> takeDamage() async => _blank();
  @override
  GridUpdate fullSnapshot() => _blank();
  @override
  void pumpEvents() {
    if (pendingEvents.isEmpty) return;
    final batch = List<(String, Object?)>.from(pendingEvents);
    pendingEvents.clear();
    for (final (kind, payload) in batch) {
      switch (kind) {
        case 'pty':
          onPtyWrite?.call(payload as Uint8List);
        case 'title':
          onTitle?.call(payload as String);
        case 'reset_title':
          onTitle?.call('flutter_alacritty');
        case 'bell':
          onBell?.call();
        case 'clipboard':
          onClipboard?.call(payload as String);
        default:
          throw StateError(
              'FakeBinding.pumpEvents: unknown event kind: $kind');
      }
    }
  }

  @override
  void resize(int columns, int rows) {
    resizeCalls++;
    lastResizeCols = columns;
    lastResizeRows = rows;
  }
  @override
  Future<void> scrollLines(int delta) async {
    scrollCalls++;
    scrollLinesArgs.add(delta);
  }
  @override
  Future<void> scrollToBottom() async {
    scrollToBottomCalls++;
  }
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) {
    selStartCalls++;
  }
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {}
  @override
  void selectionClear() {
    selClearCalls++;
  }
  @override
  String? selectionText() => null;
  @override
  bool searchSet(String pattern) => pattern != '(';
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() {
    fullSnapshotCalls++;
    return _hyperlinkSnapshot();
  }
  @override
  String? resolveHyperlink(int id) => hyperlinkUris[id];
  @override
  void dispose() {}
}

/// `FakeBinding` subclass that invokes [onClear] on every `selectionClear()`.
class ClearOnTapBinding extends FakeBinding {
  ClearOnTapBinding(this.onClear);
  final void Function() onClear;
  @override
  void selectionClear() => onClear();
}
