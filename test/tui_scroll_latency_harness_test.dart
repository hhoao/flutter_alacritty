import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/debug/terminal_scroll_latency.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/ui/terminal_scroll_controller.dart';

import 'fake_binding.dart';

Future<void> _drain(List<void Function()> pending) async {
  while (pending.isNotEmpty) {
    pending.removeAt(0)();
  }
  await Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TerminalScrollLatency.harnessEnabled = false;
    TerminalScrollLatency.reset();
  });

  testWidgets(
    'harness records scheduleWrite→paint latency without a real PTY',
    (tester) async {
      TerminalScrollLatency.harnessEnabled = true;
      TerminalScrollLatency.reset();

      // Grid ready before start so initializeEmpty is not the scroll echo.
      final grid = MirrorGrid();
      grid.initializeEmpty(1, 2);

      final pending = <void Function()>[];
      final binding = FakeBinding()
        ..modeFlags = kModeAltScreen | kModeAlternateScroll;
      final engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
        schedule: (cb) => pending.add(cb),
      );
      addTearDown(engine.dispose);
      engine.output.listen((_) {});

      final ctrl = TerminalScrollController(
        engine: engine,
        cellHeight: 20,
        scrollMultiplier: 3,
        tuiScrollSensitivity: 1,
      );
      engine.refreshView();

      // Start: first program-scroll byte enqueue for the gesture batch.
      ctrl.onPanDelta(dyPx: 40, shiftHeld: false);
      expect(TerminalScrollLatency.pendingStartUs, isNotNull);
      await _drain(pending);

      // Simulate PTY echo → MirrorGrid update (no real PTY).
      grid.apply(
        GridUpdate(
          full: false,
          rows: 1,
          columns: 2,
          lines: [
            LineCells(
              line: 0,
              codepoints: Uint32List.fromList('ab'.codeUnits),
              fg: Uint32List.fromList([0xD8D8D8, 0xD8D8D8]),
              bg: Uint32List.fromList([0x181818, 0x181818]),
              flags: Uint16List.fromList([0, 0]),
            ),
          ],
          cursorRow: 0,
          cursorCol: 0,
          cursorVisible: true,
        ),
      );
      expect(TerminalScrollLatency.pendingEchoGeneration, grid.generation);

      final glyphs = GlyphCache(
        fontFamily: 'monospace',
        fontSize: 14,
        cellWidth: 8,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomPaint(
            size: const Size(16, 16),
            painter: TerminalPainter(
              grid: grid,
              glyphs: glyphs,
              cellWidth: 8,
              cellHeight: 16,
              selectionColor: 0x553A6EA5,
              searchColors: const SearchColors(
                matchBg: 0xAC4242,
                matchFg: 0x181818,
                focusedBg: 0xF4BF75,
                focusedFg: 0x181818,
              ),
              hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
            ),
          ),
        ),
      );
      await tester.pump();

      // CI asserts harness runs — not absolute ms.
      expect(TerminalScrollLatency.samples, isNotEmpty);
      final sample = TerminalScrollLatency.samples.last;
      expect(sample.stopUs, greaterThanOrEqualTo(sample.startUs));
      expect(sample.elapsedUs, greaterThanOrEqualTo(0));
    },
  );

  test('markScheduleWrite is a no-op when harness and trace are off', () {
    TerminalScrollLatency.harnessEnabled = false;
    TerminalScrollLatency.reset();
    TerminalScrollLatency.markScheduleWrite();
    expect(TerminalScrollLatency.pendingStartUs, isNull);
    expect(TerminalScrollLatency.samples, isEmpty);
  });
}
