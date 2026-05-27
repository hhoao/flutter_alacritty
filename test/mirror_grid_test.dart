import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

LineCells row(int line, String text) => LineCells(
      line: line,
      codepoints: Int32List.fromList(text.codeUnits),
      fg: Int32List.fromList(List.filled(text.length, 0xD8D8D8)),
      bg: Int32List.fromList(List.filled(text.length, 0x181818)),
    );

void main() {
  test('full update populates all rows', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true,
      rows: 2,
      columns: 3,
      lines: [row(0, 'abc'), row(1, '   ')],
      cursorRow: 0, cursorCol: 1, cursorVisible: true,
    ));
    expect(g.rows, 2);
    expect(g.columns, 3);
    expect(g.codepointAt(0, 2), 'c'.codeUnitAt(0));
  });

  test('partial update mutates only named lines', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(full: true, rows: 2, columns: 3,
        lines: [row(0, 'abc'), row(1, 'xyz')],
        cursorRow: 0, cursorCol: 0, cursorVisible: true));
    g.apply(GridUpdate(full: false, rows: 2, columns: 3,
        lines: [row(1, 'QQQ')], cursorRow: 1, cursorCol: 2, cursorVisible: true));
    expect(g.codepointAt(0, 0), 'a'.codeUnitAt(0)); // unchanged
    expect(g.codepointAt(1, 0), 'Q'.codeUnitAt(0)); // mutated
    expect(g.cursorRow, 1);
  });

  test('partial update does not shrink viewport from inferred rows', () {
    final g = MirrorGrid();
    g.initializeEmpty(24, 80);
    g.apply(GridUpdate(
      full: false,
      rows: 1, // wrong viewport hint from damage-only metadata
      columns: 80,
      lines: [row(0, 'x')],
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    expect(g.rows, 24);
    expect(g.columns, 80);
    expect(g.codepointAt(0, 0), 'x'.codeUnitAt(0));
  });
}
