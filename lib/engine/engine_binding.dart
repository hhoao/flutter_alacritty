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
  /// Drain queued terminal→host events and dispatch them (PtyWrite/Title/…).
  /// Kept on the binding so the client stays free of FRB event types.
  void pumpEvents();
  void resize(int columns, int rows);
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
  }) : _engine = engineNew(columns: columns, rows: rows);

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

  GridUpdate fullSnapshot() => _toGridUpdate(engineFullSnapshot(engine: _engine));

  @override
  void resize(int columns, int rows) =>
      engineResize(engine: _engine, columns: columns, rows: rows);

  @override
  void dispose() {}

  GridUpdate _toGridUpdate(RenderUpdate u) => GridUpdate(
        full: u.full,
        rows: u.lines.isNotEmpty ? _maxLine(u) + 1 : 0,
        columns: u.lines.isNotEmpty ? u.lines.first.cells.length : 0,
        cursorRow: u.cursorLine,
        cursorCol: u.cursorCol,
        cursorVisible: u.cursorVisible,
        lines: u.lines
            .map((l) => LineCells(
                  line: l.line,
                  codepoints: Int32List.fromList(l.cells.map((c) => c.codepoint).toList()),
                  fg: Int32List.fromList(l.cells.map((c) => c.fg).toList()),
                  bg: Int32List.fromList(l.cells.map((c) => c.bg).toList()),
                ))
            .toList(),
      );

  int _maxLine(RenderUpdate u) => u.lines.map((l) => l.line).reduce((a, b) => a > b ? a : b);
}
