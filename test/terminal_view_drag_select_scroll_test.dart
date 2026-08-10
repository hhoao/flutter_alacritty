import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

/// Records engine-side selection updates so the drag path's endpoint can be
/// asserted.
class _SelectionRecordingBinding extends FakeBinding {
  final List<(int, int, bool)> selectionUpdates = [];

  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {
    selectionUpdates.add((displayRow, col, rightHalf));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TerminalEngine> pumpTerminal(
    WidgetTester tester,
    _SelectionRecordingBinding binding,
  ) async {
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
    engine.refreshView(); // size the mirror grid (24 rows × 80 cols)
    await tester.pumpAndSettle();
    return engine;
  }

  testWidgets('dragging below the viewport auto-scrolls toward live bottom',
      (tester) async {
    final binding = _SelectionRecordingBinding()
      ..displayOffsetSim = 40
      ..historySizeSim = 100;
    final engine = await pumpTerminal(tester, binding);

    final start = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(PointerDownEvent(
      position: start,
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    // Hold the drag far below the last visible row.
    tester.binding.handlePointerEvent(PointerMoveEvent(
      position: start + const Offset(0, 2000),
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(binding.scrollLinesArgs, isNotEmpty,
        reason: 'the held drag must keep scrolling');
    expect(binding.scrollLinesArgs.every((d) => d < 0), isTrue,
        reason: 'below-edge drag scrolls down toward live bottom');
    expect(binding.displayOffsetSim, lessThan(40));
    expect(binding.selectionUpdates, isNotEmpty);
    expect(binding.selectionUpdates.last.$1, engine.grid.rows - 1,
        reason: 'endpoint re-anchors at the held bottom edge row');

    // Re-entering the cell area stops the auto-scroll.
    final scrolled = binding.scrollCalls;
    tester.binding.handlePointerEvent(PointerMoveEvent(
      position: start,
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(binding.scrollCalls, scrolled,
        reason: 'pointer back inside → no more auto-scroll');

    // Releasing ends the drag and keeps the viewport put.
    tester.binding.handlePointerEvent(PointerUpEvent(
      position: start,
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(binding.scrollCalls, scrolled,
        reason: 'release stops the auto-scroll ticker');
  });

  testWidgets('dragging above the viewport auto-scrolls into history',
      (tester) async {
    final binding = _SelectionRecordingBinding()
      ..displayOffsetSim = 0
      ..historySizeSim = 100;
    await pumpTerminal(tester, binding);

    final start = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(PointerDownEvent(
      position: start,
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    tester.binding.handlePointerEvent(PointerMoveEvent(
      position: start + const Offset(0, -2000),
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(binding.scrollLinesArgs, isNotEmpty);
    expect(binding.scrollLinesArgs.every((d) => d > 0), isTrue,
        reason: 'above-edge drag scrolls up into history');
    expect(binding.displayOffsetSim, greaterThan(0));
    expect(binding.selectionUpdates, isNotEmpty);
    expect(binding.selectionUpdates.last.$1, 0,
        reason: 'endpoint re-anchors at the held top edge row');
  });

  testWidgets('edge auto-scroll does not scroll past the buffer limits',
      (tester) async {
    final binding = _SelectionRecordingBinding()
      ..displayOffsetSim = 0
      ..historySizeSim = 0;
    await pumpTerminal(tester, binding);

    final start = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(PointerDownEvent(
      position: start,
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    tester.binding.handlePointerEvent(PointerMoveEvent(
      position: start + const Offset(0, 2000),
      buttons: kPrimaryButton,
      kind: PointerDeviceKind.mouse,
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(binding.scrollLinesArgs, isEmpty,
        reason: 'already at live bottom with no history → nothing to scroll');
    expect(binding.displayOffsetSim, 0);
  });
}
