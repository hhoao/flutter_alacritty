import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/ui/terminal_scroll_controller.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('trackpad wheel deltas coalesce to one ingest per microtask turn',
      () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeSgrMouse | kModeMouseClick;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 16,
      scrollMultiplier: 3,
      scrollSensitivity: 1.0,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();
    ctrl.setWheelCell(col: 1, row: 1);

    // 40 × 2px = 80px = 5 rows at cellHeight 16.
    for (var i = 0; i < 40; i++) {
      ctrl.onWheelSignal(dyPx: 2, shiftHeld: false);
    }
    expect(captured, isEmpty);
    expect(pending, isNotEmpty);

    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(captured, hasLength(1));
  });
}
