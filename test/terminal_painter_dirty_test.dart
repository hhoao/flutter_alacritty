import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

const double _cw = 8;
const double _ch = 16;
const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;
const int _cols = 4;
const int _rows = 3;

/// Distinct non-default row backgrounds (packed 0x00RRGGBB).
const int _row0Bg = 0xCC0000;
const int _row1Bg = 0x00CC00;
const int _row2Bg = 0x0000CC;
const int _row2BgUpdated = 0x00FFFF;

SearchColors get _search => const SearchColors(
      matchBg: 0xAC4242,
      matchFg: 0x181818,
      focusedBg: 0xF4BF75,
      focusedFg: 0x181818,
    );

HintColors get _hint => const HintColors(bg: 0xF4BF75, fg: 0x181818);

LineCells _coloredRow(int line, int bg, {String text = '    '}) => LineCells(
      line: line,
      codepoints: Uint32List.fromList(text.codeUnits),
      bg: Uint32List.fromList(List.filled(text.length, bg)),
      fg: Uint32List.fromList(List.filled(text.length, _defaultFg)),
      flags: Uint16List(text.length),
    );

MirrorGrid _gridWithColoredRows() {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  grid.apply(GridUpdate(
    full: true,
    rows: _rows,
    columns: _cols,
    lines: [
      _coloredRow(0, _row0Bg),
      _coloredRow(1, _row1Bg),
      _coloredRow(2, _row2Bg),
    ],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    defaultFg: _defaultFg,
    defaultBg: _defaultBg,
  ));
  return grid;
}

TerminalPainter _painter(MirrorGrid grid, GridPaintRetain retain) =>
    TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: _cw),
      cellWidth: _cw,
      cellHeight: _ch,
      selectionColor: 0x553A6EA5,
      searchColors: _search,
      hintColors: _hint,
      retain: retain,
    );

Future<ui.Image> _paintToImage(TerminalPainter painter) async {
  const size = Size(_cols * _cw, _rows * _ch);
  final rec = ui.PictureRecorder();
  painter.paint(Canvas(rec), size);
  final picture = rec.endRecording();
  final img = await picture.toImage(size.width.ceil(), size.height.ceil());
  picture.dispose();
  return img;
}

/// Opaque packed 0x00RRGGBB at the center of [row]'s first cell.
int _sampleRowBg(ByteData bytes, int row, {required int width}) {
  final x = (_cw / 2).floor();
  final y = (row * _ch + _ch / 2).floor();
  final i = (y * width + x) * 4;
  final r = bytes.getUint8(i);
  final g = bytes.getUint8(i + 1);
  final b = bytes.getUint8(i + 2);
  return (r << 16) | (g << 8) | b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial dirty paint keeps clean row colors via retained picture',
      () async {
    final grid = _gridWithColoredRows();
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    final width = (_cols * _cw).ceil();

    // Full paint establishes the retained frame.
    final firstImg = await _paintToImage(painter);
    final firstBytes =
        await firstImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    firstImg.dispose();
    expect(firstBytes, isNotNull);
    expect(_sampleRowBg(firstBytes!, 0, width: width), _row0Bg);
    expect(_sampleRowBg(firstBytes, 2, width: width), _row2Bg);

    // Partial damage: only row 2 changes color.
    grid.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [_coloredRow(2, _row2BgUpdated)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final secondImg = await _paintToImage(painter);
    final secondBytes =
        await secondImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    secondImg.dispose();
    expect(secondBytes, isNotNull);
    expect(
      _sampleRowBg(secondBytes!, 0, width: width),
      _row0Bg,
      reason: 'clean row 0 must survive from the retained frame',
    );
    expect(
      _sampleRowBg(secondBytes, 2, width: width),
      _row2BgUpdated,
      reason: 'dirty row 2 must show the updated color',
    );
  });

  test('empty dirty after take falls back to painting all rows', () async {
    final grid = _gridWithColoredRows();
    expect(grid.takeDirtyRows(), [0, 1, 2]);
    expect(grid.takeDirtyRows(), isEmpty);

    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    final width = (_cols * _cw).ceil();

    final img = await _paintToImage(painter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    expect(bytes, isNotNull);
    expect(_sampleRowBg(bytes!, 0, width: width), _row0Bg);
    expect(_sampleRowBg(bytes, 1, width: width), _row1Bg);
    expect(_sampleRowBg(bytes, 2, width: width), _row2Bg);
  });
}
