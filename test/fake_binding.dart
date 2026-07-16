import 'dart:typed_data';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/controller/terminal_search_options.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';

/// Shared fake [EngineBinding] used by widget/integration-style tests that
/// drive `ExampleTerminalApp` / `TerminalEngine` without the native engine.
/// Lifted out of `terminal_lifecycle_test.dart` so other tests (e.g.
/// `terminal_engine_test.dart`) can reuse the same shape.
class FakeBinding implements RewireableEngineBinding {
  int scrollCalls = 0;
  final List<int> scrollLinesArgs = [];
  final List<double> scrollPixelsArgs = [];
  int selStartCalls = 0;
  int selClearCalls = 0;
  int scrollToBottomCalls = 0;
  int scrollToTopCalls = 0;
  int scrollToOffsetCalls = 0;
  final List<double> scrollToOffsetArgs = [];
  int fullSnapshotCalls = 0;
  int resizeCalls = 0;
  int lastResizeCols = 0;
  int lastResizeRows = 0;
  TerminalSearchOptions? lastSearchOptions;

  /// Forwarded into emitted GridUpdates so tests can flip kModeBracketedPaste
  /// etc. on the mirror grid via the existing refresh path.
  int modeFlags = 0;
  final Map<(int, int), int> hyperlinkAt = {};
  final Map<int, String> hyperlinkUris = {};

  /// Simulated scrollback offset for widget tests that drive [scrollLines].
  int displayOffsetSim = 0;
  int historySizeSim = 0;

  /// Events the next [pumpEvents] should dispatch. Each entry is one of:
  ///   `('pty', Uint8List)`, `('title', String)`, `('reset_title', null)`,
  ///   `('bell', null)`, `('clipboard', String)`.
  /// The queue is drained on each [pumpEvents] call.
  final List<(String, Object?)> pendingEvents = [];

  GridUpdate _blank() => GridUpdate(
        full: true,
        rows: lastResizeRows > 0 ? lastResizeRows : 1,
        columns: lastResizeCols > 0 ? lastResizeCols : 1,
        lines: [
          LineCells(
            line: 0,
            codepoints: Uint32List(1),
            fg: Uint32List(1),
            bg: Uint32List(1),
            flags: Uint16List(1),
          ),
        ],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
        modeFlags: modeFlags,
        displayOffset: displayOffsetSim,
        historySize: historySizeSim,
      );

  GridUpdate _hyperlinkSnapshot() {
    final cols = lastResizeCols > 0 ? lastResizeCols : 80;
    final rows = lastResizeRows > 0 ? lastResizeRows : 24;
    final hyperlinks = Uint32List(cols);
    final flags = Uint16List(cols);
    hyperlinkAt.forEach((rc, id) {
      if (rc.$1 == 0 && rc.$2 < cols) {
        hyperlinks[rc.$2] = id;
        flags[rc.$2] = kFlagHyperlink;
      }
    });
    final line0 = LineCells(
      line: 0,
      codepoints: Uint32List(cols)..fillRange(0, cols, 32),
      fg: Uint32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Uint32List(cols)..fillRange(0, cols, 0x181818),
      flags: flags,
      hyperlinkId: hyperlinks,
    );
    LineCells blank(int i) => LineCells(
          line: i,
          codepoints: Uint32List(cols)..fillRange(0, cols, 32),
          fg: Uint32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Uint32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Uint32List(cols),
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
      displayOffset: displayOffsetSim,
      historySize: historySizeSim,
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
  void Function()? onClipboardLoad;
  void Function(String)? onWorkingDir;
  void Function(String)? onNotify;

  String? lastClipboardLoadText;
  int? lastCellWidth;
  int? lastCellHeight;

  @override
  void respondClipboardLoad(String text) => lastClipboardLoadText = text;

  @override
  void setCellPixels(int width, int height) {
    lastCellWidth = width;
    lastCellHeight = height;
  }

  /// Bytes handed to the engine via either advance path, in order — lets tests
  /// assert pre-bind buffered feed is flushed once the binding exists.
  final List<int> fedBytes = [];
  @override
  Future<void> advance(Uint8List bytes) async {
    fedBytes.addAll(bytes);
  }
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    fedBytes.addAll(bytes);
    return _blank();
  }
  @override
  Future<GridUpdate> takeDamage() async => _blank();
  @override
  GridUpdate fullSnapshot() {
    fullSnapshotCalls++;
    return _hyperlinkSnapshot();
  }
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
          onTitle?.call(kDefaultTerminalTitle);
        case 'bell':
          onBell?.call();
        case 'clipboard':
          onClipboard?.call(payload as String);
        case 'clipboard_load':
          onClipboardLoad?.call();
        case 'working_dir':
          onWorkingDir?.call(payload as String);
        case 'notify':
          onNotify?.call(payload as String);
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
  Future<GridUpdate> scrollLines(int delta) async {
    scrollCalls++;
    scrollLinesArgs.add(delta);
    displayOffsetSim = (displayOffsetSim + delta).clamp(0, 100000);
    final snap = fullSnapshot();
    return GridUpdate(
      full: snap.full,
      rows: snap.rows,
      columns: snap.columns,
      lines: snap.lines,
      cursorRow: snap.cursorRow,
      cursorCol: snap.cursorCol,
      cursorVisible: snap.cursorVisible,
      modeFlags: snap.modeFlags,
      displayOffset: displayOffsetSim,
      historySize: historySizeSim,
      scrollLineDelta: 0,
    );
  }
  @override
  Future<GridUpdate> scrollPixels(double deltaPx) async {
    scrollPixelsArgs.add(deltaPx);
    return _blank();
  }
  @override
  Future<GridUpdate> scrollToBottom() async {
    scrollToBottomCalls++;
    displayOffsetSim = 0;
    return _blank();
  }
  @override
  Future<GridUpdate> scrollToTop() async {
    scrollToTopCalls++;
    displayOffsetSim = historySizeSim;
    return _blank();
  }
  @override
  Future<GridUpdate> scrollToOffset(double offsetLines) async {
    scrollToOffsetCalls++;
    scrollToOffsetArgs.add(offsetLines);
    displayOffsetSim = offsetLines.round().clamp(0, historySizeSim);
    return _blank();
  }
  @override
  void clearHistory() {}
  int reconfigureCalls = 0;
  EngineConfig? lastReconfigure;
  @override
  void reconfigure(EngineConfig config) {
    reconfigureCalls++;
    lastReconfigure = config;
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
  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) {
    lastSearchOptions = options;
    return pattern != '(';
  }
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  bool searchIsActive() => false;
  @override
  GridUpdate fullSnapshotSearched() => fullSnapshot();
  @override
  String? resolveHyperlink(int id) => hyperlinkUris[id];
  @override
  void dispose() {}
}

/// `FakeBinding` subclass that puts [rowText] on row 0 of every
/// [fullSnapshotSearched] snapshot (80×24 grid, spaces elsewhere).
///
/// Useful for tests that need non-space glyphs in the grid so the painter
/// actually rasterizes cells into the glyph cache (spaces are skipped).
class TextFakeBinding extends FakeBinding {
  TextFakeBinding(this.rowText);
  final String rowText;

  GridUpdate _textSnapshot() {
    const cols = 80, rows = 24;
    final codepoints = Uint32List(cols)..fillRange(0, cols, 32);
    for (var i = 0; i < rowText.length && i < cols; i++) {
      codepoints[i] = rowText.codeUnitAt(i);
    }
    final line0 = LineCells(
      line: 0,
      codepoints: codepoints,
      fg: Uint32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Uint32List(cols)..fillRange(0, cols, 0x181818),
      flags: Uint16List(cols),
      hyperlinkId: Uint32List(cols),
    );
    LineCells blank(int i) => LineCells(
          line: i,
          codepoints: Uint32List(cols)..fillRange(0, cols, 32),
          fg: Uint32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Uint32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Uint32List(cols),
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
      displayOffset: displayOffsetSim,
      historySize: historySizeSim,
    );
  }

  @override
  GridUpdate fullSnapshot() => _textSnapshot();

  @override
  GridUpdate fullSnapshotSearched() => _textSnapshot();
}

/// `FakeBinding` subclass that invokes [onClear] on every `selectionClear()`.
class ClearOnTapBinding extends FakeBinding {
  ClearOnTapBinding(this.onClear);
  final void Function() onClear;
  @override
  void selectionClear() => onClear();
}
