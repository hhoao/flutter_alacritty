import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Sentinel `cursorColor` meaning "no OSC 12 set" (matches Rust CURSOR_COLOR_UNSET).
const int kCursorColorUnset = 0xFF000000;

/// One line's cells (native types — decoupled from FRB so MirrorGrid is
/// unit-testable without the native lib).
class LineCells {
  LineCells({
    required this.line,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.flags,
    Int32List? hyperlinkId,
  }) : hyperlinkId = hyperlinkId ?? Int32List(codepoints.length);

  final int line;
  final Int32List codepoints;
  final Int32List fg;
  final Int32List bg;
  final Uint16List flags;
  final Int32List hyperlinkId;
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
    this.modeFlags = 0,
    this.displayOffset = 0,
    this.defaultFg = 0xD8D8D8,
    this.defaultBg = 0x181818,
    this.cursorColor = 0xFF000000,
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
  final int modeFlags;
  final int displayOffset;
  final int defaultFg;
  final int defaultBg;
  final int cursorColor;
}

/// Read-only view of the terminal grid that the engine exposes to consumers.
///
/// Implemented by [MirrorGrid]; lets external code read cell content, cursor
/// state, mode flags, and listen for changes via the inherited [Listenable]
/// without being able to mutate the grid. The mutable `apply` /
/// `initializeEmpty` methods only exist on [MirrorGrid], which is
/// package-internal — consumers should never touch them, and a read-only
/// reference is sufficient for everything in the public API (painter rebind,
/// hyperlink lookup, modeFlags / displayOffset gates).
abstract class TerminalGridView implements Listenable {
  int get rows;
  int get columns;
  int get cursorRow;
  int get cursorCol;
  bool get cursorVisible;
  int get cursorShape;
  bool get cursorBlinking;
  int get modeFlags;
  int get displayOffset;
  /// Program-set cursor color (OSC 12), or 0xFF000000 ([kCursorColorUnset]) when
  /// unset — in which case painters keep their inverse-video cursor.
  int get cursorColor;

  /// Bumped on every grid mutation. Painters use this to short-circuit
  /// `shouldRepaint`.
  int get generation;

  int codepointAt(int row, int col);
  int fgAt(int row, int col);
  int bgAt(int row, int col);
  int flagsAt(int row, int col);
  int hyperlinkIdAt(int row, int col);
}

/// Mutable terminal grid. Applies incremental line deltas in place and notifies
/// the painter to repaint.
class MirrorGrid extends ChangeNotifier implements TerminalGridView {
  /// [defaultFg]/[defaultBg] fill empty/newly-grown cells. They must match the
  /// engine's blank-cell colors (the configured default fg/bg) so untouched rows
  /// — which the engine never sends partial damage for — render in the right
  /// color from the first frame instead of a stale hardcoded default.
  MirrorGrid({int defaultFg = 0xD8D8D8, int defaultBg = 0x181818})
      : _defaultFg = defaultFg,
        _defaultBg = defaultBg;

  int _defaultFg;
  int _defaultBg;
  int _cursorColor = kCursorColorUnset;
  int _generation = 0;
  int _rows = 0;
  int _columns = 0;
  List<Int32List> _codepoints = [];
  List<Int32List> _fg = [];
  List<Int32List> _bg = [];
  List<Uint16List> _flags = [];
  List<Int32List> _hyperlinkId = [];
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _cursorVisible = false;
  int _cursorShape = 0;
  bool _cursorBlinking = false;
  int _modeFlags = 0;
  int _displayOffset = 0;

  /// Bumps on every [apply] / [initializeEmpty]; used by [TerminalPainter.shouldRepaint].
  @override
  int get generation => _generation;

  @override
  int get rows => _rows;
  @override
  int get columns => _columns;
  @override
  int get cursorRow => _cursorRow;
  @override
  int get cursorCol => _cursorCol;
  @override
  bool get cursorVisible => _cursorVisible;
  @override
  int get cursorShape => _cursorShape;
  @override
  bool get cursorBlinking => _cursorBlinking;
  @override
  int get modeFlags => _modeFlags;
  @override
  int get displayOffset => _displayOffset;
  @override
  int get cursorColor => _cursorColor;

  @override
  int codepointAt(int row, int col) => _codepoints[row][col];
  @override
  int fgAt(int row, int col) => _fg[row][col];
  @override
  int bgAt(int row, int col) => _bg[row][col];
  @override
  int flagsAt(int row, int col) => _flags[row][col];
  @override
  int hyperlinkIdAt(int row, int col) => _hyperlinkId[row][col];

  void _ensureSize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows;
    _columns = columns;
    _codepoints = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, 32));
    _fg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, _defaultFg));
    _bg = List.generate(rows, (_) => Int32List(columns)..fillRange(0, columns, _defaultBg));
    _flags = List.generate(rows, (_) => Uint16List(columns));
    _hyperlinkId = List.generate(rows, (_) => Int32List(columns));
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
    _defaultFg = u.defaultFg;
    _defaultBg = u.defaultBg;
    _cursorColor = u.cursorColor;
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
      _hyperlinkId[l.line].setRange(0, copy, l.hyperlinkId);
    }
    _cursorRow = u.cursorRow;
    _cursorCol = u.cursorCol;
    _cursorVisible = u.cursorVisible;
    _cursorShape = u.cursorShape;
    _cursorBlinking = u.cursorBlinking;
    _modeFlags = u.modeFlags;
    _displayOffset = u.displayOffset;
    _generation++;
    notifyListeners();
  }
}
