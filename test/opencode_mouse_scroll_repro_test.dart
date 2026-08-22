import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/ui/terminal_scroll_controller.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'support/rust_test_lib.dart';

/// Regression coverage for the opencode TUI wheel-scroll complaint
/// ("the opencode screen inside the terminal cannot scroll").
///
/// Proves, against the REAL Rust engine:
/// 1. opencode's mouse-enable sequences (?1000h/?1006h + alt screen) land in
///    the Dart mirror grid's mode flags;
/// 2. the scroll controller converts a wheel notch into SGR 64/65 reports;
/// 3. a real [PointerScrollEvent] through [TerminalView] emits those reports
///    on the PTY-bound output stream;
/// 4. a trackpad pan through [TerminalView] reports at the hovered cell (not
///    the stale default (1,1)) so TUI hit-testing reaches scrollable regions.
TerminalEngine buildEngine(List<void Function()> pending) {
  final engine = TerminalEngine.fromBinding(
    FrbEngineBinding(
      columns: 80,
      rows: 24,
      onPtyWrite: (_) {},
      onTitle: (_) {},
      onBell: () {},
      onClipboard: (_) {},
      onClipboardLoad: () {},
      onWorkingDir: (_) {},
      onNotify: (_) {},
      engineConfig: TerminalConfig.defaults().engineConfig,
    ),
    config: TerminalConfig.defaults(),
    schedule: pending.add,
  );
  return engine;
}

/// Drives the engine's drain pipeline in a plain test: each scheduled callback
/// is executed, then real async FFI hops get a chance to complete.
Future<void> drain(
  TerminalEngine engine,
  List<void Function()> pending,
) async {
  for (var i = 0; i < 100 && pending.isNotEmpty; i++) {
    final cb = pending.removeAt(0);
    cb();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

const _boot = '\x1b[?1049h\x1b[?1000h\x1b[?1006h';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initRustLibForTests(preferRelease: false);
  });

  test('opencode TUI: mouse mode flags reach the Dart mirror grid', () async {
    final pending = <void Function()>[];
    final engine = buildEngine(pending);
    addTearDown(engine.dispose);
    engine.resize(columns: 80, rows: 24);

    engine.feed(utf8.encode('$_boot payload'));
    await drain(engine, pending);

    final flags = engine.grid.modeFlags;
    expect(anyMouse(flags), isTrue,
        reason: 'opencode enables ?1000h+?1006h; the mirror must see the bits');
    expect(flags & kModeAltScreen, isNot(0),
        reason: 'opencode runs fullscreen in the alternate screen');
  });

  test('opencode TUI: wheel in mouse mode emits SGR 64/65 reports', () async {
    final pending = <void Function()>[];
    final captured = <List<int>>[];
    final engine = buildEngine(pending);
    addTearDown(engine.dispose);
    engine.output.listen((b) => captured.add(b.toList()));
    engine.resize(columns: 80, rows: 24);

    engine.feed(utf8.encode('$_boot payload'));
    await drain(engine, pending);
    expect(anyMouse(engine.grid.modeFlags), isTrue,
        reason: 'precondition: mouse mode must be visible');

    final ctrl = TerminalScrollController(
      engine: engine,
      cellHeight: 20,
      scrollMultiplier: 3,
      scrollSensitivity: 1.15,
      tuiScrollSensitivity: 1,
    );
    ctrl.setWheelCell(col: 40, row: 12);
    ctrl.onWheelSignal(dyPx: 53, shiftHeld: false); // one mouse notch down
    await drain(engine, pending);
    ctrl.dispose();

    final bytes = captured.expand((b) => b).toList();
    expect(bytes, isNotEmpty, reason: 'wheel must be forwarded to the program');
    expect(String.fromCharCodes(bytes), contains('\x1b[<65;40;12M'),
        reason: 'SGR scroll-down report at the hovered cell');
  });

  testWidgets('opencode TUI: real PointerScrollEvent through TerminalView',
      (tester) async {
    final pending = <void Function()>[];
    final captured = <List<int>>[];
    final engine = buildEngine(pending);
    addTearDown(engine.dispose);
    engine.output.listen((b) => captured.add(b.toList()));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 800, height: 480, child: TerminalView(engine)),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => drain(engine, pending));

    // opencode-style startup sequences (real FFI must run outside FakeAsync)
    engine.feed(utf8.encode('$_boot payload'));
    await tester.runAsync(() => drain(engine, pending));

    expect(anyMouse(engine.grid.modeFlags), isTrue,
        reason: 'mouse mode must be visible before the wheel');

    final center = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 53),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => drain(engine, pending));

    final bytes = captured.expand((b) => b).toList();
    expect(bytes, isNotEmpty,
        reason: 'PointerScrollEvent over the TUI must emit SGR wheel reports');
    expect(
      String.fromCharCodes(bytes).contains('\x1b[<65;'),
      isTrue,
      reason: 'reports must be SGR scroll-down (button 64 + 1)',
    );
  });

  testWidgets('opencode TUI: trackpad pan reports at the hovered cell',
      (tester) async {
    final pending = <void Function()>[];
    final captured = <List<int>>[];
    final engine = buildEngine(pending);
    addTearDown(engine.dispose);
    engine.output.listen((b) => captured.add(b.toList()));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 800, height: 480, child: TerminalView(engine)),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => drain(engine, pending));

    // opencode-style startup sequences (real FFI must run outside FakeAsync)
    engine.feed(utf8.encode('$_boot payload'));
    await tester.runAsync(() => drain(engine, pending));
    expect(anyMouse(engine.grid.modeFlags), isTrue,
        reason: 'mouse mode must be visible before the pan');

    final center = tester.getCenter(find.byType(CustomPaint).first);
    tester.binding.handlePointerEvent(
      PointerPanZoomStartEvent(
        position: center,
      ),
    );
    tester.binding.handlePointerEvent(
      PointerPanZoomUpdateEvent(
        position: center,
        panDelta: const Offset(0, -33),
        scale: 1,
        rotation: 0,
      ),
    );
    await tester.pump();
    await tester.runAsync(() => drain(engine, pending));

    final bytes = captured.expand((b) => b).toList();
    final text = String.fromCharCodes(bytes);
    expect(bytes, isNotEmpty,
        reason: 'trackpad pan over the TUI must emit SGR wheel reports');
    // The report must carry the hovered cell, not the stale default (1,1) —
    // otherwise the TUI hit-test misses its scrollable message region.
    expect(text.contains('\x1b[<65;1;1M'), isFalse,
        reason: 'reports must not use the default top-left cell');
    expect(text.contains('\x1b[<65;'), isTrue,
        reason: 'SGR scroll reports must still be emitted');
  });
}
