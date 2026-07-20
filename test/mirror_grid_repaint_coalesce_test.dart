import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/render/mirror_grid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MirrorGrid coalesces burst applies to one notify per frame',
      (tester) async {
    final grid = MirrorGrid()..initializeEmpty(2, 2);
    var notifies = 0;
    grid.addListener(() => notifies++);

    // Burst applies in the same event turn before the next frame.
    for (var i = 0; i < 20; i++) {
      grid.apply(
        GridUpdate(
          full: false,
          rows: 0,
          columns: 0,
          lines: const [],
          cursorRow: 0,
          cursorCol: i % 2,
          cursorVisible: true,
        ),
      );
    }

    expect(notifies, 0, reason: 'notify must wait for the scheduled frame');
    await tester.pump();
    expect(notifies, 1, reason: 'burst applies collapse to one vsync notify');
    expect(grid.cursorCol, 1);
  });
}
