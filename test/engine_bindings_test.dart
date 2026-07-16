import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';
import 'package:flutter_alacritty/src/rust/event_proxy.dart';

import 'support/rust_test_lib.dart';

void main() {
  setUpAll(() async {
    await initRustLibForTests(preferRelease: false);
  });

  test('advanceAndTakeDamage round-trips and DSR emits a PtyWrite event', () async {
    final engine = engineNew(
      columns: 20,
      rows: 5,
      config: TerminalConfig.defaults().engineConfig,
    );

    final u = await engineAdvanceAndTakeDamage(engine: engine, bytes: 'hi'.codeUnits);
    final line0 = u.lines.firstWhere((l) => l.line == 0);
    expect(String.fromCharCode(line0.codepoints[0]), 'h');
    expect(String.fromCharCode(line0.codepoints[1]), 'i');

    // DSR cursor-position query → a PtyWrite event, drained by polling.
    await engineAdvanceAndTakeDamage(engine: engine, bytes: '\x1b[6n'.codeUnits);
    final events = engineTakeEvents(engine: engine);
    expect(events.whereType<EngineEvent_PtyWrite>(), isNotEmpty);
  });

  test('search next/prev across the FFI boundary actually moves focus', () async {
    // Mirrors the user's failing scenario: 3 matches on a single line, then
    // verify next/prev cycle the focused match across the real dylib.
    final engine = engineNew(
        columns: 20, rows: 5, config: TerminalConfig.defaults().engineConfig);
    await engineAdvanceAndTakeDamage(engine: engine, bytes: 'foofoofoo'.codeUnits);

    expect(
      engineSearchSet(
        engine: engine,
        pattern: 'foo',
        options: const SearchOptions(
          caseSensitive: false,
          wholeWord: false,
          regex: true,
          wrap: true,
        ),
      ),
      isTrue,
    );
    const flagCurrent = 1 << 10;
    int focusedCol(RenderUpdate u) {
      for (var c = 0; c < u.lines[0].flags.length; c++) {
        if (u.lines[0].flags[c] & flagCurrent != 0) return c;
      }
      return -1;
    }

    var u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 0, reason: 'set focuses first match');

    expect(engineSearchNext(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 3, reason: 'next should reach col 3');

    expect(engineSearchNext(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 6, reason: 'next should reach col 6');

    expect(engineSearchPrev(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 3, reason: 'prev should move back to col 3');

    expect(engineSearchPrev(engine: engine), isTrue);
    u = engineFullSnapshotSearched(engine: engine);
    expect(focusedCol(u), 0, reason: 'prev should move back to col 0');
  });

  test('OSC 8 hyperlink carries hyperlinkId on the columnar line', () async {
    final engine = engineNew(
      columns: 40,
      rows: 3,
      config: TerminalConfig.defaults().engineConfig,
    );
    // OSC 8: ESC ] 8 ; id ; uri ESC \ TEXT ESC ] 8 ; ; ESC \
    const osc8 = '\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\';
    final u = await engineAdvanceAndTakeDamage(
      engine: engine,
      bytes: osc8.codeUnits,
    );
    final u2 = engineFullSnapshotSearched(engine: engine);
    final snap = u2.lines.isNotEmpty ? u2 : u;
    final line0 = snap.lines.firstWhere((l) => l.line == 0);
    expect(line0.hyperlinkId[0], isNonZero);
    expect(line0.flags[0] & (1 << 11), isNonZero);
  });
}
