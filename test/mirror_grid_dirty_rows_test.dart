import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

LineCells row(int line, String text) => LineCells(
      line: line,
      codepoints: Uint32List.fromList(text.codeUnits),
      fg: Uint32List.fromList(List.filled(text.length, 0xD8D8D8)),
      bg: Uint32List.fromList(List.filled(text.length, 0x181818)),
      flags: Uint16List(text.length),
    );

void main() {
  test('apply partial records dirty row indices and clears after take', () {
    final g = MirrorGrid();
    g.initializeEmpty(4, 8);
    g.takeDirtyRows(); // clear any dirt from initializeEmpty
    g.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [row(2, 'dirtyrow')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    expect(g.takeDirtyRows(), [2]);
    expect(g.takeDirtyRows(), isEmpty);
  });

  test('apply full dirties all rows and take clears', () {
    final g = MirrorGrid();
    g.initializeEmpty(4, 8);
    g.takeDirtyRows();
    g.apply(GridUpdate(
      full: true,
      rows: 4,
      columns: 8,
      lines: [row(0, 'aaaaaaaa'), row(1, 'bbbbbbbb')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    expect(g.takeDirtyRows(), [0, 1, 2, 3]);
    expect(g.takeDirtyRows(), isEmpty);
  });

  test('scrollLineDelta marks affected rows dirty', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true,
      rows: 3,
      columns: 2,
      lines: [row(0, 'A0'), row(1, 'B1'), row(2, 'C2')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    g.takeDirtyRows();
    g.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      scrollLineDelta: 1,
      lines: [row(0, 'N0')],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    ));
    final dirty = g.takeDirtyRows();
    // Rotation touches the whole viewport; at minimum row 0 (new line) is dirty.
    expect(dirty, contains(0));
    expect(dirty, isNotEmpty);
    expect(g.takeDirtyRows(), isEmpty);
  });
}
