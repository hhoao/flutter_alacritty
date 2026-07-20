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

SearchColors get _search => const SearchColors(
      matchBg: 0xAC4242,
      matchFg: 0x181818,
      focusedBg: 0xF4BF75,
      focusedFg: 0x181818,
    );

HintColors get _hint => const HintColors(bg: 0xF4BF75, fg: 0x181818);

LineCells _row(int line, int bg, String text) => LineCells(
      line: line,
      codepoints: Uint32List.fromList(text.codeUnits),
      bg: Uint32List.fromList(List.filled(text.length, bg)),
      fg: Uint32List.fromList(List.filled(text.length, _defaultFg)),
      flags: Uint16List(text.length),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scrollLineDelta blit keeps shifted clean rows without full repaint',
      () async {
    const cols = 4;
    const rows = 3;
    const row0 = 0xCC0000;
    const row1 = 0x00CC00;
    const row2 = 0x0000CC;
    const rowNew = 0xFFFF00;

    final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
    grid.apply(GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [
        _row(0, row0, '    '),
        _row(1, row1, '    '),
        _row(2, row2, '    '),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: _cw),
      cellWidth: _cw,
      cellHeight: _ch,
      selectionColor: 0x553A6EA5,
      searchColors: _search,
      hintColors: _hint,
      retain: retain,
    );

    Future<ui.Image> paintOnce() async {
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), const Size(cols * _cw, rows * _ch));
      final pic = rec.endRecording();
      final img = await pic.toImage((cols * _cw).ceil(), (rows * _ch).ceil());
      pic.dispose();
      return img;
    }

    Future<int> sample(ui.Image img, int row) async {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final x = (_cw / 2).floor();
      final y = (row * _ch + _ch / 2).floor();
      final i = (y * img.width + x) * 4;
      return (bytes!.getUint8(i) << 16) |
          (bytes.getUint8(i + 1) << 8) |
          bytes.getUint8(i + 2);
    }

    var img = await paintOnce();
    expect(await sample(img, 0), row0);
    expect(await sample(img, 1), row1);
    img.dispose();

    // Scroll +1: old row0→row1, old row1→row2, new top row.
    grid.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      scrollLineDelta: 1,
      lines: [_row(0, rowNew, '    ')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    img = await paintOnce();
    expect(await sample(img, 0), rowNew, reason: 'exposed top row');
    expect(await sample(img, 1), row0, reason: 'blit-shifted former row0');
    expect(await sample(img, 2), row1, reason: 'blit-shifted former row1');
    img.dispose();
  });
}
