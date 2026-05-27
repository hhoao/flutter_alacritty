import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

LineCells row(int line, String text, {List<int>? flags}) => LineCells(
      line: line,
      codepoints: Int32List.fromList(text.codeUnits),
      fg: Int32List.fromList(List.filled(text.length, 0xD8D8D8)),
      bg: Int32List.fromList(List.filled(text.length, 0x181818)),
      flags: Uint16List.fromList(flags ?? List.filled(text.length, 0)),
    );

void main() {
  test('full update populates all rows', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 2, columns: 3,
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
    g.apply(GridUpdate(full: false, rows: 0, columns: 0,
        lines: [row(1, 'QQQ')], cursorRow: 1, cursorCol: 2, cursorVisible: true));
    expect(g.codepointAt(0, 0), 'a'.codeUnitAt(0));
    expect(g.codepointAt(1, 0), 'Q'.codeUnitAt(0));
    expect(g.cursorRow, 1);
  });

  test('carries display offset', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 1, lines: [row(0, ' ')],
      cursorRow: 0, cursorCol: 0, cursorVisible: true, displayOffset: 4,
    ));
    expect(g.displayOffset, 4);
  });

  test('carries mode flags', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 1, lines: [row(0, ' ')],
      cursorRow: 0, cursorCol: 0, cursorVisible: true, modeFlags: 0x22,
    ));
    expect(g.modeFlags, 0x22);
  });

  test('carries cursor shape and blinking', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true,
      rows: 1,
      columns: 1,
      lines: [row(0, ' ')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
      cursorShape: 2,
      cursorBlinking: true,
    ));
    expect(g.cursorShape, 2);
    expect(g.cursorBlinking, true);
  });

  test('stores per-cell flags', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [row(0, '中X', flags: [kFlagWide, kFlagWideSpacer])],
      cursorRow: 0, cursorCol: 0, cursorVisible: true,
    ));
    expect(g.flagsAt(0, 0) & kFlagWide, kFlagWide);
    expect(g.flagsAt(0, 1) & kFlagWideSpacer, kFlagWideSpacer);
  });

  test('partial line wider than viewport clamps without throwing', () {
    final g = MirrorGrid();
    g.initializeEmpty(2, 10);
    final wide = Int32List(15)..fillRange(0, 15, 65); // 'A' × 15
    g.apply(GridUpdate(
      full: false,
      rows: 1,
      columns: 15,
      lines: [
        LineCells(
          line: 0,
          codepoints: wide,
          fg: Int32List(15),
          bg: Int32List(15),
          flags: Uint16List(15),
        ),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    expect(g.columns, 10);
    expect(g.codepointAt(0, 0), 65);
    expect(g.codepointAt(0, 9), 65);
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
