import 'package:flutter/scheduler.dart';
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

  // Background agent PTYs keep applying after TerminalView unmounts (compose
  // landing). Scheduling frames with no listeners starves Priority.idle and
  // leaves the landing TextField placeholder unfocusable.
  testWidgets(
    'MirrorGrid apply with no listeners does not schedule a frame',
    (tester) async {
      await tester.pump();
      expect(
        SchedulerBinding.instance.hasScheduledFrame,
        isFalse,
        reason: 'precondition: binding idle',
      );

      final grid = MirrorGrid()..initializeEmpty(2, 2);
      grid.apply(
        GridUpdate(
          full: false,
          rows: 0,
          columns: 0,
          lines: const [],
          cursorRow: 0,
          cursorCol: 1,
          cursorVisible: true,
        ),
      );

      expect(
        SchedulerBinding.instance.hasScheduledFrame,
        isFalse,
        reason: 'detached engine must not keep the frame pipeline busy',
      );
      expect(grid.cursorCol, 1);
    },
  );
}
