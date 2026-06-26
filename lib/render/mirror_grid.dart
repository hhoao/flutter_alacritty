import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Sentinel [LineCells.line] on incremental scroll FFI updates (matches Rust
/// `OVERSCAN_LINE_TAG`). Full snapshots tag overscan with `screen_lines` instead.
const int kOverscanLineTag = 0xFFFFFFFF;

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
    Uint32List? hyperlinkId,
  }) : hyperlinkId = hyperlinkId ?? Uint32List(codepoints.length);

  final int line;
  // Columnar, matching the FFI `LineUpdate` (Vec<u32>/Vec<u16>) so the engine
  // binding passes the FRB-decoded typed lists straight through with no per-cell
  // copy. fg/bg are packed 0x00RRGGBB; codepoints are Unicode scalar values.
  final Uint32List codepoints;
  final Uint32List fg;
  final Uint32List bg;
  final Uint16List flags;
  final Uint32List hyperlinkId;
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
    this.historySize = 0,
    this.defaultFg = 0xD8D8D8,
    this.defaultBg = 0x181818,
    this.cursorColor = 0xFF000000,
    this.scrollFraction = 0.0,
    this.overscan,
    this.scrollLineDelta = 0,
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

  /// Scrollback lines above the viewport (`total_lines - screen_lines`).
  final int historySize;
  final int defaultFg;
  final int defaultBg;
  final int cursorColor;

  /// Sub-cell scroll position in [0.0, 1.0). See [TerminalGridView.scrollFraction].
  final double scrollFraction;

  /// The line directly above the viewport top, used to fill the sliver revealed
  /// when [scrollFraction] > 0. Present only on full updates (null on partial
  /// damage, where the fraction is always 0).
  final LineCells? overscan;

  /// Net viewport line scroll for incremental scroll refresh. The mirror rotates
  /// existing rows by this delta before applying [lines].
  final int scrollLineDelta;
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

  /// Scrollback lines above the viewport; drives scrollbar geometry.
  int get historySize;
  /// Program-set cursor color (OSC 12), or 0xFF000000 ([kCursorColorUnset]) when
  /// unset — in which case painters keep their inverse-video cursor.
  int get cursorColor;

  /// Sub-cell scroll offset in [0.0, 1.0): how far the viewport is scrolled up
  /// past a line boundary, in fractions of a cell height. The painter shifts
  /// content down by `scrollFraction * cellHeight` and fills the revealed top
  /// sliver with the overscan row (cell `row == -1`). 0.0 on a line boundary.
  double get scrollFraction;

  /// Bumped on every grid mutation. Painters use this to short-circuit
  /// `shouldRepaint`.
  int get generation;

  /// Cell accessors. `row` in `0..rows-1` reads the viewport; `row == -1` reads
  /// the overscan line (the row just above the viewport top) used to paint the
  /// [scrollFraction] sliver. Other negative rows are not valid.
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
  List<Uint32List> _codepoints = [];
  List<Uint32List> _fg = [];
  List<Uint32List> _bg = [];
  List<Uint16List> _flags = [];
  List<Uint32List> _hyperlinkId = [];
  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _cursorVisible = false;
  int _cursorShape = 0;
  bool _cursorBlinking = false;
  int _modeFlags = 0;
  int _displayOffset = 0;
  int _historySize = 0;
  double _scrollFraction = 0;
  // Overscan line (row -1): the row just above the viewport top, painted in the
  // sliver revealed when _scrollFraction > 0. Always sized to _columns.
  Uint32List _overCodepoints = Uint32List(0);
  Uint32List _overFg = Uint32List(0);
  Uint32List _overBg = Uint32List(0);
  Uint16List _overFlags = Uint16List(0);
  Uint32List _overHyperlinkId = Uint32List(0);
  bool _repaintNotifyScheduled = false;
  bool _repaintDisposed = false;

  @override
  void dispose() {
    _repaintDisposed = true;
    super.dispose();
  }

  /// Notifies repaint listeners. Deferred to post-frame when called from layout
  /// (e.g. synchronous viewport apply inside [LayoutBuilder]) so dependents
  /// like [TerminalHistoryScrollbar] do not setState during build.
  void _notifyRepaint() {
    if (_repaintDisposed) return;
    try {
      final phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.persistentCallbacks ||
          phase == SchedulerPhase.midFrameMicrotasks) {
        if (_repaintNotifyScheduled) return;
        _repaintNotifyScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _repaintNotifyScheduled = false;
          if (_repaintDisposed) return;
          notifyListeners();
        });
        return;
      }
    } on Object {
      // No scheduler binding (headless unit tests) — notify synchronously.
    }
    if (_repaintDisposed) return;
    notifyListeners();
  }

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
  int get historySize => _historySize;
  @override
  int get cursorColor => _cursorColor;
  @override
  double get scrollFraction => _scrollFraction;

  /// The grid's current default background (packed 0x00RRGGBB). The painter
  /// skips filling cells equal to this — the layer is cleared to it by the host
  /// — mirroring native alacritty's `bg_alpha == 0` for untouched default cells.
  int get defaultBg => _defaultBg;
  int get defaultFg => _defaultFg;

  @override
  int codepointAt(int row, int col) =>
      row < 0 ? _overCodepoints[col] : _codepoints[row][col];
  @override
  int fgAt(int row, int col) => row < 0 ? _overFg[col] : _fg[row][col];
  @override
  int bgAt(int row, int col) => row < 0 ? _overBg[col] : _bg[row][col];
  @override
  int flagsAt(int row, int col) =>
      row < 0 ? _overFlags[col] : _flags[row][col];
  @override
  int hyperlinkIdAt(int row, int col) =>
      row < 0 ? _overHyperlinkId[col] : _hyperlinkId[row][col];

  void _ensureSize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows;
    _columns = columns;
    _codepoints = List.generate(rows, (_) => Uint32List(columns)..fillRange(0, columns, 32));
    _fg = List.generate(rows, (_) => Uint32List(columns)..fillRange(0, columns, _defaultFg));
    _bg = List.generate(rows, (_) => Uint32List(columns)..fillRange(0, columns, _defaultBg));
    _flags = List.generate(rows, (_) => Uint16List(columns));
    _hyperlinkId = List.generate(rows, (_) => Uint32List(columns));
    _overCodepoints = Uint32List(columns)..fillRange(0, columns, 32);
    _overFg = Uint32List(columns)..fillRange(0, columns, _defaultFg);
    _overBg = Uint32List(columns)..fillRange(0, columns, _defaultBg);
    _overFlags = Uint16List(columns);
    _overHyperlinkId = Uint32List(columns);
  }

  /// Empty viewport for startup — avoids a sync full_snapshot FFI round-trip.
  void initializeEmpty(int rows, int columns) {
    _ensureSize(rows, columns);
    _cursorRow = 0;
    _cursorCol = 0;
    _cursorVisible = true;
    _generation++;
    _notifyRepaint();
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
    final delta = u.scrollLineDelta;
    if (delta != 0 && _rows > 0) {
      _rotateRows(delta);
    }
    for (final l in u.lines) {
      if (l.line < 0) continue;
      if (l.line >= _rows) {
        _applyOverscanLine(l);
        continue;
      }
      // Partial damage can arrive with engine cols > mirror cols when resize races
      // the async drain (LayoutBuilder grew before post-frame resize ran).
      final copy = l.codepoints.length < _columns ? l.codepoints.length : _columns;
      if (copy == 0) continue;
      _codepoints[l.line].setRange(0, copy, l.codepoints);
      _fg[l.line].setRange(0, copy, l.fg);
      _bg[l.line].setRange(0, copy, l.bg);
      _flags[l.line].setRange(0, copy, l.flags);
      _hyperlinkId[l.line].setRange(0, copy, l.hyperlinkId);
      if (copy < _columns) {
        _codepoints[l.line].fillRange(copy, _columns, 32);
        _fg[l.line].fillRange(copy, _columns, _defaultFg);
        _bg[l.line].fillRange(copy, _columns, _defaultBg);
        _flags[l.line].fillRange(copy, _columns, 0);
        _hyperlinkId[l.line].fillRange(copy, _columns, 0);
      }
    }
    // Overscan from explicit field (full updates) or sentinel line index (scroll).
    final o = u.overscan;
    if (o != null) {
      _applyOverscanLine(o);
    }
    _scrollFraction = u.scrollFraction;
    _cursorRow = u.cursorRow;
    _cursorCol = u.cursorCol;
    _cursorVisible = u.cursorVisible;
    _cursorShape = u.cursorShape;
    _cursorBlinking = u.cursorBlinking;
    _modeFlags = u.modeFlags;
    _displayOffset = u.displayOffset;
    if (u.full || u.historySize > 0) {
      _historySize = u.historySize;
    }
    _generation++;
    _notifyRepaint();
  }

  void _rotateRows(int delta) {
    if (delta > 0) {
      final d = delta > _rows ? _rows : delta;
      for (var i = _rows - 1; i >= d; i--) {
        _copyRow(i - d, i);
      }
    } else if (delta < 0) {
      final d = (-delta) > _rows ? _rows : -delta;
      for (var i = 0; i < _rows - d; i++) {
        _copyRow(i + d, i);
      }
    }
  }

  void _copyRow(int from, int to) {
    _codepoints[to].setAll(0, _codepoints[from]);
    _fg[to].setAll(0, _fg[from]);
    _bg[to].setAll(0, _bg[from]);
    _flags[to].setAll(0, _flags[from]);
    _hyperlinkId[to].setAll(0, _hyperlinkId[from]);
  }

  void _applyOverscanLine(LineCells o) {
    final copy = o.codepoints.length < _columns ? o.codepoints.length : _columns;
    _overCodepoints.fillRange(0, _columns, 32);
    _overFg.fillRange(0, _columns, _defaultFg);
    _overBg.fillRange(0, _columns, _defaultBg);
    _overFlags.fillRange(0, _columns, 0);
    _overHyperlinkId.fillRange(0, _columns, 0);
    if (copy > 0) {
      _overCodepoints.setRange(0, copy, o.codepoints);
      _overFg.setRange(0, copy, o.fg);
      _overBg.setRange(0, copy, o.bg);
      _overFlags.setRange(0, copy, o.flags);
      _overHyperlinkId.setRange(0, copy, o.hyperlinkId);
    }
  }
}
