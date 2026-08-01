import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/modifier_latch.dart';
import 'package:flutter_alacritty/input/terminal_accessory_layout.dart';
import 'package:flutter_alacritty/ui/terminal_accessory_bar.dart';

void main() {
  testWidgets('ctrl tap toggles latch highlight', (tester) async {
    final latch = ModifierLatch();
    final injected = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalAccessoryBar(
            layout: TerminalAccessoryLayout.serverBoxDualRow,
            latch: latch,
            onInjectKey: injected.add,
            onToggleIme: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(latch.ctrl, isTrue);
    await tester.tap(find.text('Esc'));
    await tester.pump();
    expect(injected, [LogicalKeyboardKey.escape]);
  });

  testWidgets('repeatable arrow starts periodic inject on long press',
      (tester) async {
    final latch = ModifierLatch();
    final injected = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalAccessoryBar(
            layout: TerminalAccessoryLayout.serverBoxDualRow,
            latch: latch,
            onInjectKey: injected.add,
            onToggleIme: () {},
          ),
        ),
      ),
    );
    final up = find.byIcon(Icons.arrow_upward);
    final gesture = await tester.startGesture(tester.getCenter(up));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 137));
    await tester.pump(const Duration(milliseconds: 137));
    await gesture.up();
    await tester.pump();
    expect(
      injected.where((k) => k == LogicalKeyboardKey.arrowUp).length,
      greaterThanOrEqualTo(3),
    );
  });

  testWidgets('ime toggle key calls onToggleIme when tapping keyboard icon',
      (tester) async {
    var toggled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalAccessoryBar(
            layout: TerminalAccessoryLayout.serverBoxDualRow,
            latch: ModifierLatch(),
            onInjectKey: (_) {},
            onToggleIme: () => toggled = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.keyboard));
    await tester.pump();
    expect(toggled, isTrue);
  });
}
