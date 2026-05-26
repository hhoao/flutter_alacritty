import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/render/mirror_grid.dart';

void main() {
  test('cellAt returns row-major cells from the latest snapshot', () {
    final grid = MirrorGrid();
    grid.update(MirrorSnapshot(
      rows: 2,
      columns: 3,
      // 'abc' on row 0, spaces on row 1
      codepoints: [97, 98, 99, 32, 32, 32],
      fg: List.filled(6, 0xD8D8D8),
      bg: List.filled(6, 0x181818),
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    expect(grid.rows, 2);
    expect(grid.columns, 3);
    expect(grid.codepointAt(0, 2), 99); // 'c'
    expect(grid.cursorCol, 1);
  });
}
