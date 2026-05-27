import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// One line's cells (native types — decoupled from FRB so MirrorGrid is
/// unit-testable without the native lib).
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.flags,
  });
  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
  final Uint16List flags;
}

/// A render update: either a full replace or a set of changed lines.
class GridUpdate {
  GridUpdate({
    required this.full,
    required this.rows,
    required this.columns,
    required this.lines,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
    this.cursorShape = 0,
    this.cursorBlinking = false,
  });
  final bool full;
  final int rows;
  final int columns;
  final List<LineCells> lines;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final int cursorShape;
  final bool cursorBlinking;
}

/// Mutable terminal grid. Applies incremental line deltas in place and notifies
/// the painter to repaint.
class MirrorGrid extends ChangeNotifier {
  int _generation = 0;
  int _rows = 0;
  int _columns = 0;
  List<Int32List> _codepoints = [];
  List<Int32List> _fg = [];
  List<Int32List> _bg = [];
  List<Uint16List> _flags = [];
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _cursorVisible = false;
  int _cursorShape = 0;
  bool _cursorBlinking = false;

  /// Bumps on every [apply] / [initializeEmpty]; used by [TerminalPainter.shouldRepaint].
  int get generation => _generation;

  int get rows => _rows;
  int get columns => _columns;
  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;
  bool get cursorVisible => _cursorVisible;
  int get cursorShape => _cursorShape;
  bool get cursorBlinking => _cursorBlinking;

  int codepointAt(int row, int col) => _codepoints[row][col];
  int fgAt(int row, int col) => _fg[row][col];
  int bgAt(int row, int col) => _bg[row][col];
  int flagsAt(int row, int col) => _flags[row][col];

  void _ensureSize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows;
    _columns = columns;
    _codepoints = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 32));
    _fg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0xD8D8D8));
    _bg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0x181818));
    _flags = List.generate(rows, (_) => Uint16List(columns));
  }

  /// Empty viewport for startup — avoids a sync full_snapshot FFI round-trip.
  void initializeEmpty(int rows, int columns) {
    _ensureSize(rows, columns);
    _cursorRow = 0;
    _cursorCol = 0;
    _cursorVisible = true;
    _generation++;
    notifyListeners();
  }

  void apply(GridUpdate u) {
    // Partial damage only names changed lines; rows/columns on GridUpdate are not
    // viewport size (see FrbEngineBinding._toGridUpdate). Resize on full only.
    if (u.full) {
      _ensureSize(u.rows, u.columns);
    }
    for (final l in u.lines) {
      if (l.line < 0 || l.line >= _rows) continue;
      // Partial damage can arrive with engine cols > mirror cols when resize races
      // the async drain (LayoutBuilder grew before post-frame resize ran).
      final copy = l.codepoints.length < _columns ? l.codepoints.length : _columns;
      if (copy == 0) continue;
      _codepoints[l.line].setRange(0, copy, l.codepoints);
      _fg[l.line].setRange(0, copy, l.fg);
      _bg[l.line].setRange(0, copy, l.bg);
      _flags[l.line].setRange(0, copy, l.flags);
    }
    _cursorRow = u.cursorRow;
    _cursorCol = u.cursorCol;
    _cursorVisible = u.cursorVisible;
    _cursorShape = u.cursorShape;
    _cursorBlinking = u.cursorBlinking;
    _generation++;
    notifyListeners();
  }
}
