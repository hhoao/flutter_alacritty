import 'package:flutter/foundation.dart';

/// One line's cells (native types — decoupled from FRB so MirrorGrid is
/// unit-testable without the native lib).
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
  });
  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
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
  });
  final bool full;
  final int rows;
  final int columns;
  final List<LineCells> lines;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
}

/// Mutable terminal grid. Applies incremental line deltas in place and notifies
/// the painter to repaint.
class MirrorGrid extends ChangeNotifier {
  int _rows = 0;
  int _columns = 0;
  List<Int32List> _codepoints = [];
  List<Int32List> _fg = [];
  List<Int32List> _bg = [];
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _cursorVisible = false;

  int get rows => _rows;
  int get columns => _columns;
  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;
  bool get cursorVisible => _cursorVisible;

  int codepointAt(int row, int col) => _codepoints[row][col];
  int fgAt(int row, int col) => _fg[row][col];
  int bgAt(int row, int col) => _bg[row][col];

  void _ensureSize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows;
    _columns = columns;
    _codepoints = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 32));
    _fg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0xD8D8D8));
    _bg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 0x181818));
  }

  void apply(GridUpdate u) {
    if (u.full || u.rows != _rows || u.columns != _columns) {
      _ensureSize(u.rows, u.columns);
    }
    for (final l in u.lines) {
      if (l.line < 0 || l.line >= _rows) continue;
      _codepoints[l.line].setAll(0, l.codepoints);
      _fg[l.line].setAll(0, l.fg);
      _bg[l.line].setAll(0, l.bg);
    }
    _cursorRow = u.cursorRow;
    _cursorCol = u.cursorCol;
    _cursorVisible = u.cursorVisible;
    notifyListeners();
  }
}
