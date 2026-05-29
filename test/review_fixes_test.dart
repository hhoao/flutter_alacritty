import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:flutter_alacritty/input/term_mode.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() {}
}

void main() {
  group('hoverCursorFor (MouseCursorDirty mode-driven pointer)', () {
    test('hyperlink wins → click pointer', () {
      expect(
        hoverCursorFor(
            hyperlink: true,
            modeFlags: kModeMouseClick,
            base: SystemMouseCursors.text),
        SystemMouseCursors.click,
      );
    });

    test('mouse-capturing app (MOUSE_MODE) → arrow', () {
      expect(
        hoverCursorFor(
            hyperlink: false,
            modeFlags: kModeMouseClick,
            base: SystemMouseCursors.text),
        SystemMouseCursors.basic,
      );
    });

    test('no link, no mouse mode → configured base (I-beam)', () {
      expect(
        hoverCursorFor(
            hyperlink: false, modeFlags: 0, base: SystemMouseCursors.text),
        SystemMouseCursors.text,
      );
    });
  });

  testWidgets('hot-reload applies new config: reconfigure + theme swap',
      (tester) async {
    final updates = StreamController<TerminalConfig>.broadcast();
    late FakeBinding binding;
    EngineBinding engineFactory({
      required int columns,
      required int rows,
      required void Function(Uint8List) onPtyWrite,
      required void Function(String) onTitle,
      required void Function() onBell,
      required void Function(String) onClipboard,
      required void Function() onClipboardLoad,
      required engineConfig,
    }) {
      binding = FakeBinding();
      return binding;
    }

    await tester.pumpWidget(MaterialApp(
      home: ExampleTerminalApp(
        title: ValueNotifier('t'),
        config: TerminalConfig.defaults(),
        configUpdates: updates.stream,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: engineFactory,
      ),
    ));
    await tester.pumpAndSettle();

    final reconfBefore = binding.reconfigureCalls;

    // Emit a new config with a changed background.
    final next = TerminalConfig.defaults().copyWith(
      colors:
          TerminalConfig.defaults().colors.copyWith(background: 0x112233),
    );
    updates.add(next);
    await tester.pumpAndSettle();

    // Engine-side delta applied...
    expect(binding.reconfigureCalls, greaterThan(reconfBefore));
    // ...and the widget rebuilt with the new theme.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF112233));

    await updates.close();
  });
}
