import 'dart:typed_data';

import '../render/mirror_grid.dart';
import '../src/rust/api/terminal.dart';
import '../src/rust/engine.dart';
import '../src/rust/event_proxy.dart';

/// Abstracts the FRB engine calls so the client is testable without the native
/// lib. Returns native [GridUpdate]s (translation from FRB types lives in the
/// FRB-backed implementation).
abstract class EngineBinding {
  Future<void> advance(Uint8List bytes);
  Future<GridUpdate> takeDamage();
  /// Parse PTY bytes and return damage in one FFI hop (preferred hot path).
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes);
  /// Drain queued terminal→host events and dispatch them (PtyWrite/Title/…).
  /// Kept on the binding so the client stays free of FRB event types.
  void pumpEvents();
  void resize(int columns, int rows);
  /// Full viewport snapshot (sync). Used after resize when damage is `Full`.
  GridUpdate fullSnapshot();
  /// Full viewport snapshot with search match flags applied.
  GridUpdate fullSnapshotSearched();
  Future<void> scrollLines(int delta);
  Future<void> scrollToBottom();
  void selectionStart(int displayRow, int col, bool rightHalf, int kind);
  void selectionUpdate(int displayRow, int col, bool rightHalf);
  void selectionClear();
  String? selectionText();
  bool searchSet(String pattern);
  bool searchNext();
  bool searchPrev();
  void searchClear();
  String? resolveHyperlink(int id);
  void dispose();
}

/// FRB-backed binding. Owns the engine handle, translates FRB [RenderUpdate]
/// into native [GridUpdate], and dispatches polled terminal→host events.
class FrbEngineBinding implements EngineBinding {
  FrbEngineBinding({
    required int columns,
    required int rows,
    required this.onPtyWrite,
    required this.onTitle,
    required this.onBell,
    required this.onClipboard,
    required EngineConfig engineConfig,
  }) : _engine = engineNew(columns: columns, rows: rows, config: engineConfig);

  final TerminalEngine _engine;
  final void Function(Uint8List) onPtyWrite;
  final void Function(String) onTitle;
  final void Function() onBell;
  final void Function(String) onClipboard;

  @override
  Future<void> advance(Uint8List bytes) => engineAdvance(engine: _engine, bytes: bytes);

  @override
  Future<GridUpdate> takeDamage() async =>
      _toGridUpdate(await engineTakeDamage(engine: _engine));

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async =>
      _toGridUpdate(await engineAdvanceAndTakeDamage(engine: _engine, bytes: bytes));

  @override
  void pumpEvents() {
    for (final e in engineTakeEvents(engine: _engine)) {
      if (e is EngineEvent_PtyWrite) {
        onPtyWrite(e.field0);
      } else if (e is EngineEvent_Title) {
        onTitle(e.field0);
      } else if (e is EngineEvent_ResetTitle) {
        onTitle('flutter_alacritty');
      } else if (e is EngineEvent_Bell) {
        onBell();
      } else if (e is EngineEvent_ClipboardStore) {
        onClipboard(e.field0);
      }
    }
  }

  @override
  GridUpdate fullSnapshot() => _toGridUpdate(engineFullSnapshot(engine: _engine));

  @override
  GridUpdate fullSnapshotSearched() =>
      _toGridUpdate(engineFullSnapshotSearched(engine: _engine));

  @override
  void resize(int columns, int rows) =>
      engineResize(engine: _engine, columns: columns, rows: rows);

  @override
  Future<void> scrollLines(int delta) =>
      engineScrollLines(engine: _engine, delta: delta);

  @override
  Future<void> scrollToBottom() => engineScrollToBottom(engine: _engine);

  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) =>
      engineSelectionStart(
        engine: _engine,
        displayRow: displayRow,
        col: col,
        rightHalf: rightHalf,
        kind: kind,
      );

  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) =>
      engineSelectionUpdate(
        engine: _engine,
        displayRow: displayRow,
        col: col,
        rightHalf: rightHalf,
      );

  @override
  void selectionClear() => engineSelectionClear(engine: _engine);

  @override
  String? selectionText() => engineSelectionText(engine: _engine);

  @override
  bool searchSet(String pattern) =>
      engineSearchSet(engine: _engine, pattern: pattern);

  @override
  bool searchNext() => engineSearchNext(engine: _engine);

  @override
  bool searchPrev() => engineSearchPrev(engine: _engine);

  @override
  void searchClear() => engineSearchClear(engine: _engine);

  @override
  String? resolveHyperlink(int id) =>
      engineResolveHyperlink(engine: _engine, id: id);

  @override
  void dispose() {}

  GridUpdate _toGridUpdate(RenderUpdate u) => GridUpdate(
        full: u.full,
        // rows/columns only matter on a full update (MirrorGrid.apply resizes
        // only then); a full snapshot has contiguous lines 0..rows-1.
        rows: u.full ? u.lines.length : 0,
        columns: (u.full && u.lines.isNotEmpty) ? u.lines.first.cells.length : 0,
        cursorRow: u.cursorLine,
        cursorCol: u.cursorCol,
        cursorVisible: u.cursorVisible,
        cursorShape: u.cursorShape,
        cursorBlinking: u.cursorBlinking,
        modeFlags: u.modeFlags,
        displayOffset: u.displayOffset,
        lines: u.lines.map(_lineCells).toList(),
      );

  LineCells _lineCells(LineUpdate l) {
    final n = l.cells.length;
    final codepoints = Int32List(n);
    final fg = Int32List(n);
    final bg = Int32List(n);
    final flags = Uint16List(n);
    final hyperlinkId = Int32List(n);
    for (var i = 0; i < n; i++) {
      final c = l.cells[i];
      codepoints[i] = c.codepoint;
      fg[i] = c.fg;
      bg[i] = c.bg;
      flags[i] = c.flags;
      hyperlinkId[i] = c.hyperlinkId;
    }
    return LineCells(
      line: l.line,
      codepoints: codepoints,
      fg: fg,
      bg: bg,
      flags: flags,
      hyperlinkId: hyperlinkId,
    );
  }
}
