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

GridUpdate emptyPartial({
  int cursorRow = 0,
  int cursorCol = 0,
  bool cursorVisible = true,
  int cursorShape = 0,
  bool cursorBlinking = false,
  int cursorColor = kCursorColorUnset,
  int defaultFg = 0xD8D8D8,
  int defaultBg = 0x181818,
  List<LineCells> lines = const [],
}) =>
    GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: lines,
      cursorRow: cursorRow,
      cursorCol: cursorCol,
      cursorVisible: cursorVisible,
      cursorShape: cursorShape,
      cursorBlinking: cursorBlinking,
      cursorColor: cursorColor,
      defaultFg: defaultFg,
      defaultBg: defaultBg,
    );

void main() {
  test('apply partial records dirty row indices and clears after take', () {
    final g = MirrorGrid();
    g.initializeEmpty(4, 8);
    g.takeDirtyRows(); // clear any dirt from initializeEmpty
    g.apply(emptyPartial(lines: [row(2, 'dirtyrow')]));
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
    expect(g.takeDirtyRows(), [0, 1, 2]);
    expect(g.takeDirtyRows(), isEmpty);
  });

  test('cursor move dirties old and new cursor rows', () {
    final g = MirrorGrid();
    g.initializeEmpty(4, 8);
    g.takeDirtyRows();
    g.apply(emptyPartial(cursorRow: 2, cursorCol: 3));
    expect(g.takeDirtyRows(), [0, 2]);
    expect(g.takeDirtyRows(), isEmpty);
  });

  test('cursor visibility/shape/color change dirties cursor row', () {
    final g = MirrorGrid();
    g.initializeEmpty(3, 4);
    // Place cursor on row 1 first.
    g.apply(emptyPartial(cursorRow: 1));
    g.takeDirtyRows();

    g.apply(emptyPartial(cursorRow: 1, cursorVisible: false));
    expect(g.takeDirtyRows(), [1]);

    g.apply(emptyPartial(cursorRow: 1, cursorVisible: false, cursorShape: 2));
    expect(g.takeDirtyRows(), [1]);

    g.apply(emptyPartial(
      cursorRow: 1,
      cursorVisible: false,
      cursorShape: 2,
      cursorColor: 0x00FF00,
    ));
    expect(g.takeDirtyRows(), [1]);
    expect(g.takeDirtyRows(), isEmpty);
  });

  test('defaultFg/Bg change dirties all rows', () {
    final g = MirrorGrid();
    g.initializeEmpty(3, 4);
    g.takeDirtyRows();
    g.apply(emptyPartial(defaultFg: 0xAABBCC, defaultBg: 0x102030));
    expect(g.takeDirtyRows(), [0, 1, 2]);
    expect(g.takeDirtyRows(), isEmpty);
  });
}
