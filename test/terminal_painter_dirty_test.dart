import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

/// Records [drawRect] calls so tests can assert which row Y bands were filled.
class _RecordingCanvas implements Canvas {
  final List<ui.Rect> rects = [];

  @override
  void drawRect(ui.Rect rect, ui.Paint paint) => rects.add(rect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const double _cw = 8;
const double _ch = 16;
const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;
const int _cols = 4;
const int _rows = 3;

/// Non-default row backgrounds so the painter emits per-row fills (default-bg
/// cells are skipped after the layer clear).
const List<int> _rowBg = [0x220000, 0x002200, 0x000022];

SearchColors get _search => const SearchColors(
      matchBg: 0xAC4242,
      matchFg: 0x181818,
      focusedBg: 0xF4BF75,
      focusedFg: 0x181818,
    );

HintColors get _hint => const HintColors(bg: 0xF4BF75, fg: 0x181818);

LineCells _coloredRow(int line, int bg, {String text = 'xxxx'}) => LineCells(
      line: line,
      codepoints: Uint32List.fromList(text.codeUnits),
      fg: Uint32List.fromList(List.filled(text.length, _defaultFg)),
      bg: Uint32List.fromList(List.filled(text.length, bg)),
      flags: Uint16List(text.length),
    );

MirrorGrid _gridWithColoredRows() {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  grid.apply(GridUpdate(
    full: true,
    rows: _rows,
    columns: _cols,
    lines: [
      for (var r = 0; r < _rows; r++) _coloredRow(r, _rowBg[r]),
    ],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    defaultFg: _defaultFg,
    defaultBg: _defaultBg,
  ));
  return grid;
}

TerminalPainter _painter(MirrorGrid grid) => TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: _cw),
      cellWidth: _cw,
      cellHeight: _ch,
      selectionColor: 0x553A6EA5,
      searchColors: _search,
      hintColors: _hint,
    );

/// True if [rect] is a per-cell/row band fill whose vertical center lies in
/// [row]'s Y range — excludes a full-layer clear covering the whole size.
bool _isRowBandFill(ui.Rect rect, int row, {required Size size}) {
  if (rect.width >= size.width && rect.height >= size.height) return false;
  final centerY = rect.top + rect.height / 2;
  return centerY >= row * _ch && centerY < (row + 1) * _ch;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial update does not draw bg fills for clean rows', () {
    final grid = _gridWithColoredRows();
    final painter = _painter(grid);
    const size = Size(_cols * _cw, _rows * _ch);

    // First paint consumes the full dirty set (all rows).
    final first = _RecordingCanvas();
    painter.paint(first, size);
    expect(
      [0, 1, 2].every(
          (r) => first.rects.any((rect) => _isRowBandFill(rect, r, size: size))),
      isTrue,
      reason: 'initial full paint should fill every colored row',
    );

    // Partial damage: only row 1 changes (new non-default bg).
    grid.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [_coloredRow(1, 0x004400)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final second = _RecordingCanvas();
    painter.paint(second, size);

    expect(
      second.rects.any((rect) => _isRowBandFill(rect, 1, size: size)),
      isTrue,
      reason: 'dirty row 1 must still get a bg fill',
    );
    expect(
      second.rects.any((rect) => _isRowBandFill(rect, 0, size: size)),
      isFalse,
      reason: 'clean row 0 must not be filled again',
    );
    expect(
      second.rects.any((rect) => _isRowBandFill(rect, 2, size: size)),
      isFalse,
      reason: 'clean row 2 must not be filled again',
    );
  });

  test('empty dirty after take falls back to painting all rows', () {
    final grid = _gridWithColoredRows();
    // Simulate another consumer draining dirty before paint.
    expect(grid.takeDirtyRows(), [0, 1, 2]);
    expect(grid.takeDirtyRows(), isEmpty);

    final painter = _painter(grid);
    const size = Size(_cols * _cw, _rows * _ch);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, size);

    expect(
      [0, 1, 2].every(
          (r) => canvas.rects.any((rect) => _isRowBandFill(rect, r, size: size))),
      isTrue,
      reason: 'empty dirty set must fall back to a full row paint',
    );
  });
}
