import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:flutter_alacritty/input/ime_session.dart';
import 'package:flutter_alacritty/input/modifier_latch.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

class _FakeTextInputConnection
    with IDebugImeConnection
    implements TextInputConnection {
  int showCount = 0;
  bool _attached = true;

  @override
  bool get attached => _attached;

  @override
  void show() => showCount++;

  @override
  void hide() {}

  @override
  void close() {
    _attached = false;
  }

  @override
  void setEditingState(TextEditingValue value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  final writes = <Uint8List>[];
  bool killed = false;

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void write(Uint8List data) => writes.add(data);

  @override
  void resize(int rows, int columns) {}

  @override
  void kill() => killed = true;

  @override
  ValueListenable<bool>? get isForegroundProcessRunning => null;
}

EngineBinding _fakeEngineFactory({
  required int columns,
  required int rows,
  required void Function(Uint8List) onPtyWrite,
  required void Function(String) onTitle,
  required void Function() onBell,
  required void Function(String) onClipboard,
  required void Function() onClipboardLoad,
  required void Function(String) onWorkingDir,
  required void Function(String) onNotify,
  required engineConfig,
}) =>
    FakeBinding();

void main() {
  testWidgets('second touch tap calls ensureVisible on attached IME',
      (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(ExampleTerminalApp(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: _fakeEngineFactory,
    ));
    await tester.pump();

    await tester.tap(
      find.byType(CustomPaint).first,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    final state = tester.state<State<TerminalView>>(find.byType(TerminalView));
    final ime = (state as dynamic).imeForTest as ImeSession;
    final fake = _FakeTextInputConnection();
    ime.debugBindConnection(fake);
    final showBefore = fake.showCount;

    await tester.tap(
      find.byType(CustomPaint).first,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    expect(fake.showCount, greaterThan(showBefore));
    title.dispose();
  });

  testWidgets('IME commit with ctrl latch sends control byte and clears latch',
      (tester) async {
    final title = ValueNotifier<String>('t');
    final latch = ModifierLatch();
    final pty = _FakePty();
    await tester.pumpWidget(ExampleTerminalApp(
      title: title,
      modifierLatch: latch,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: _fakeEngineFactory,
    ));
    await tester.pump();

    final state = tester.state<State<TerminalView>>(find.byType(TerminalView));
    final ime = (state as dynamic).imeForTest as ImeSession;
    latch.toggleCtrl();
    expect(latch.ctrl, isTrue);

    ime.updateEditingValue(const TextEditingValue(text: 'c'));
    await tester.pump();

    expect(pty.writes.expand((e) => e).toList(), [0x03]);
    expect(latch.ctrl, isFalse);
    title.dispose();
  });

  testWidgets('blur clears modifier latch', (tester) async {
    final title = ValueNotifier<String>('t');
    final latch = ModifierLatch();
    await tester.pumpWidget(ExampleTerminalApp(
      title: title,
      modifierLatch: latch,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: _fakeEngineFactory,
    ));
    await tester.pump();

    await tester.tap(find.byType(CustomPaint).first);
    await tester.pump();

    latch.toggleCtrl();
    expect(latch.ctrl, isTrue);

    final focusNode =
        tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!;
    focusNode.unfocus();
    await tester.pump();

    expect(latch.ctrl, isFalse);
    title.dispose();
  });
}
