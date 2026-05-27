import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

void main() {
  test('shouldRepaint when grid generation changes', () {
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 2);
    final glyphs = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    final before = TerminalPainter(
      grid: grid,
      glyphs: glyphs,
      cellWidth: 8,
      cellHeight: 16,
    );
    grid.apply(GridUpdate(
      full: false,
      rows: 1,
      columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('ab'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([0, 0]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    final after = TerminalPainter(
      grid: grid,
      glyphs: glyphs,
      cellWidth: 8,
      cellHeight: 16,
    );
    expect(after.shouldRepaint(before), isTrue);
    expect(after.shouldRepaint(after), isFalse);
  });
}
