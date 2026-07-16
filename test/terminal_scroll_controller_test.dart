import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/program_scroll_encoder.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart' show GridUpdate;
import 'package:flutter_alacritty/ui/terminal_scroll_controller.dart';

import 'fake_binding.dart';

Future<void> drain(List<void Function()> pending) async {
  while (pending.isNotEmpty) {
    pending.removeAt(0)();
  }
  await Future<void>.value();
}

void wireHistoryScrollHooks(TerminalEngine engine, TerminalScrollController ctrl) {
  engine.onCancelCoalescedScroll = ctrl.cancelPendingHistory;
  engine.onDrainHistoryScroll = ctrl.drainHistoryScroll;
}

/// Defers [scrollPixels] until [completeScrollPixels] for in-flight cancel tests.
class DeferredScrollPixelsBinding extends FakeBinding {
  Completer<GridUpdate>? _scrollCompleter;

  @override
  Future<GridUpdate> scrollPixels(double deltaPx) async {
    scrollPixelsArgs.add(deltaPx);
    _scrollCompleter = Completer<GridUpdate>();
    return _scrollCompleter!.future;
  }

  void completeScrollPixels({int? displayOffset}) {
    if (displayOffset != null) displayOffsetSim = displayOffset;
    _scrollCompleter?.complete(
      GridUpdate(
        full: true,
        rows: 1,
        columns: 1,
        lines: const [],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
        displayOffset: displayOffsetSim,
        historySize: historySizeSim,
      ),
    );
    _scrollCompleter = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('alt-screen: multiple ingests coalesce to one batched write', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: 12, shiftHeld: false);
    ctrl.onPanDelta(dyPx: 12, shiftHeld: false);
    ctrl.onPanDelta(dyPx: 20, shiftHeld: false);
    expect(captured, isEmpty);

    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(captured.length, 1);
    expect(captured.single.length, 2 * 3);
  });

  test('history: routes to scrollPixels not output', () async {
    final binding = FakeBinding()..displayOffsetSim = 10;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs, isNotEmpty);
    expect(binding.scrollPixelsArgs.single, closeTo(-30.0, 1e-9));
  });

  test('history: multiple pan deltas in one frame coalesce px', () async {
    final binding = FakeBinding()
      ..displayOffsetSim = 45
      ..historySizeSim = 691;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs.length, 1);
    expect(binding.scrollPixelsArgs.single, closeTo(-90.0, 1e-9));
  });

  test('history pan at live bottom is a no-op', () async {
    final binding = FakeBinding()..displayOffsetSim = 0;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs, isEmpty);
  });

  test('history wheel negates dy like PointerScrollEvent', () async {
    final binding = FakeBinding()
      ..displayOffsetSim = 50
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onWheelSignal(dyPx: 120, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollPixelsArgs, isEmpty);
    expect(binding.scrollLinesArgs, [-6]);
  });

  test('history wheel snaps to bottom when crossing live edge', () async {
    final binding = FakeBinding()
      ..historySizeSim = 100
      ..displayOffsetSim = 2;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onWheelSignal(dyPx: 120, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollToBottomCalls, 1);
    expect(binding.scrollLinesArgs, isEmpty);
  });

  test('history wheel nets opposing ticks in one frame (no stale snap race)',
      () async {
    final binding = FakeBinding()
      ..historySizeSim = 100
      ..displayOffsetSim = 5;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    // Down then up in the same frame: net 0 lines — must not snap-then-scroll.
    ctrl.onWheelSignal(dyPx: 120, shiftHeld: false);
    ctrl.onWheelSignal(dyPx: -120, shiftHeld: false);
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.displayOffsetSim, 5);
    expect(binding.scrollToBottomCalls, 0);
    expect(binding.scrollLinesArgs, isEmpty);
  });

  Future<void> drain(List<void Function()> pending) async {
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();
  }

  test('alt-screen pan positive dy scrolls up (SS3 A)', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onPanDelta(dyPx: 40, shiftHeld: false);
    await drain(pending);

    expect(captured.single, [0x1b, 0x4f, 0x41, 0x1b, 0x4f, 0x41]);
  });

  test('alt-screen wheel positive dy scrolls down (SS3 B)', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final binding = FakeBinding()
      ..modeFlags = kModeAltScreen | kModeAlternateScroll;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onWheelSignal(dyPx: 40, shiftHeld: false);
    await drain(pending);

    expect(captured.single, [0x1b, 0x4f, 0x42, 0x1b, 0x4f, 0x42]);
  });

  test('mouse mode uses multiplier 1.0 not scrollMultiplier/3', () async {
    final captured = <Uint8List>[];
    final pending = <void Function()>[];
    final modeFlags = kModeSgrMouse | kModeMouseClick;
    final binding = FakeBinding()..modeFlags = modeFlags;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    engine.output.listen(captured.add);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 6,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();
    ctrl.setWheelCell(col: 1, row: 1);

    // scrollMultiplier 6 → _multiplier 2.0, but mouse mode forces 1.0 → 1 line.
    ctrl.onPanDelta(dyPx: 25, shiftHeld: false);
    await drain(pending);

    final oneLine = encodeMouseWheelLines(
      lines: 1,
      up: true,
      col: 1,
      row: 1,
      modeFlags: modeFlags,
    );
    expect(captured.single, oneLine);
  });

  test('scrollToBottom cancels pending history pixels via engine hook', () async {
    final binding = FakeBinding();
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.onCancelCoalescedScroll = ctrl.cancelPendingHistory;
    engine.onDrainHistoryScroll = ctrl.drainHistoryScroll;

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    expect(binding.scrollPixelsArgs, isEmpty);

    await engine.scrollToBottom();

    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    await Future<void>.value();

    expect(binding.scrollToBottomCalls, 1);
    expect(binding.scrollPixelsArgs, isEmpty);
  });

  test('in-flight pan scrollPixels loses to scrollToOffset after drain', () async {
    final binding = DeferredScrollPixelsBinding()
      ..displayOffsetSim = 45
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    wireHistoryScrollHooks(engine, ctrl);
    engine.refreshView();

    ctrl.onPanDelta(dyPx: -30, shiftHeld: false);
    await drain(pending);
    expect(binding.scrollPixelsArgs, hasLength(1));
    expect(ctrl.historyScrollInFlight, isTrue);

    final scrollFuture = engine.scrollToOffset(5);
    await Future<void>.value();
    binding.completeScrollPixels(displayOffset: 40);
    await scrollFuture;

    expect(binding.scrollToOffsetCalls, 1);
    expect(binding.scrollToOffsetArgs.single, closeTo(5.0, 1e-9));
    expect(binding.displayOffsetSim, 5);
    expect(ctrl.historyScrollInFlight, isFalse);
  });

  test('history wheel lines flush before pan pixels in one queue', () async {
    final binding = FakeBinding()
      ..displayOffsetSim = 20
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();

    ctrl.onWheelSignal(dyPx: -60, shiftHeld: false);
    ctrl.onPanDelta(dyPx: 30, shiftHeld: false);
    await drain(pending);

    expect(binding.scrollLinesArgs, isNotEmpty);
    expect(binding.scrollPixelsArgs, isNotEmpty);
    expect(binding.scrollLinesArgs.first, greaterThan(0));
    expect(binding.scrollPixelsArgs.single, closeTo(30.0, 1e-9));
  });

  test('cancelPendingHistory during in-flight pan invalidates generation',
      () async {
    final binding = DeferredScrollPixelsBinding()
      ..displayOffsetSim = 45
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    wireHistoryScrollHooks(engine, ctrl);
    engine.refreshView();

    ctrl.onPanDelta(dyPx: 30, shiftHeld: false);
    await drain(pending);
    expect(ctrl.historyScrollInFlight, isTrue);

    ctrl.cancelPendingHistoryFlushes();
    binding.completeScrollPixels(displayOffset: 60);
    await ctrl.drainHistoryScroll();

    expect(binding.scrollPixelsArgs, hasLength(1));
    expect(ctrl.historyScrollInFlight, isFalse);
  });

  test('pan snap scrollToBottom during flush does not deadlock drain', () async {
    final binding = FakeBinding()
      ..displayOffsetSim = 5
      ..historySizeSim = 100;
    final pending = <void Function()>[];
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    wireHistoryScrollHooks(engine, ctrl);
    engine.refreshView();

    ctrl.onPanDelta(dyPx: -500, shiftHeld: false);
    await drain(pending);
    await Future<void>.value();

    expect(binding.scrollToBottomCalls, 1);
    expect(ctrl.historyScrollInFlight, isFalse);
  });

  test('mouse-report trackpad pixels emit reports via TuiWheelDistance not ScrollAccumulator only', () async {
    final modeFlags = kModeSgrMouse | kModeMouseClick | kModeAltScreen;
    final pending = <void Function()>[];
    final binding = FakeBinding()..modeFlags = modeFlags;
    final engine = TerminalEngine.fromBinding(
      binding,
      config: TerminalConfig.defaults(),
      schedule: (cb) => pending.add(cb),
    );
    addTearDown(engine.dispose);
    final captured = <List<int>>[];
    engine.output.listen((b) => captured.add(b.toList()));

    final c = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      tuiScrollSensitivity: 1,
    );
    engine.refreshView();
    c.setWheelCell(col: 1, row: 1);
    // Two trackpad pixel events → 1 then 1 report at cellHeight 20 (1.5 + carry).
    c.onWheelSignal(dyPx: 30, shiftHeld: false);
    c.onWheelSignal(dyPx: 10, shiftHeld: false);
    await drain(pending);
    expect(captured, isNotEmpty);
    expect(captured.expand((e) => e).length, greaterThan(0));
  });
}
