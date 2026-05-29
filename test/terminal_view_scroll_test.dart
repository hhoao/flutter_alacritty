import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('multiple wheel events in one frame coalesce to one scrollLines',
      (tester) async {
    final binding = FakeBinding();
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TerminalView(engine)),
    ));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(CustomPaint).first);
    for (var i = 0; i < 5; i++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, 120),
        ),
      );
    }
    expect(binding.scrollCalls, 0);

    expect(pending, isNotEmpty);
    pending.removeAt(0)();
    await tester.pump();
    await Future<void>.value();

    expect(binding.scrollCalls, 1);
    expect(binding.scrollLinesArgs.single, -15);
  });
}
