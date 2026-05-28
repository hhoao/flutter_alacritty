import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/ui/search_bar.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  bool killed = false;
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() => killed = true;
}

class _FakeBinding implements EngineBinding {
  int scrollCalls = 0;
  int selStartCalls = 0;

  GridUpdate _blank() => GridUpdate(
        full: true, rows: 1, columns: 1,
        lines: [LineCells(
          line: 0,
          codepoints: Int32List(1),
          fg: Int32List(1),
          bg: Int32List(1),
          flags: Uint16List(1),
        )],
        cursorRow: 0, cursorCol: 0, cursorVisible: true,
      );
  @override
  Future<void> advance(Uint8List bytes) async {}
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async => _blank();
  @override
  Future<GridUpdate> takeDamage() async => _blank();
  @override
  GridUpdate fullSnapshot() => _blank();
  @override
  void pumpEvents() {}
  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> scrollLines(int delta) async {
    scrollCalls++;
  }
  @override
  Future<void> scrollToBottom() async {}
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) {
    selStartCalls++;
  }
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  bool searchSet(String pattern) => false;
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() => _blank();
  @override
  void dispose() {}
}

void main() {
  testWidgets('shell exit shows overlay; input restarts', (tester) async {
    final ptys = <_FakePty>[];
    PtyBackend ptyFactory({required int rows, required int columns}) {
      final p = _FakePty();
      ptys.add(p);
      return p;
    }
    EngineBinding engineFactory({
      required int columns, required int rows,
      required void Function(Uint8List) onPtyWrite,
      required void Function(String) onTitle,
      required void Function() onBell,
      required void Function(String) onClipboard,
      required engineConfig,
    }) => _FakeBinding();

    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: ValueNotifier('t'),
        ptyFactory: ptyFactory,
        engineFactory: engineFactory,
      ),
    ));
    await tester.pumpAndSettle();
    expect(ptys.length, 1);

    ptys.first.exit.complete(0); // shell exits
    await tester.pumpAndSettle();
    expect(find.textContaining('process exited (0)'), findsOneWidget);

    await tester.tap(find.byType(TerminalScreen)); // any input restarts
    await tester.pumpAndSettle();
    expect(ptys.length, 2); // a fresh PTY was spawned
    expect(find.textContaining('process exited'), findsNothing);
  });

  testWidgets('spawn failure shows the error overlay', (tester) async {
    PtyBackend boom({required int rows, required int columns}) =>
        throw StateError('no shell');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: ValueNotifier('t'),
        ptyFactory: boom,
        engineFactory: ({required columns, required rows, required onPtyWrite, required onTitle, required onBell, required onClipboard, required engineConfig}) => _FakeBinding(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('failed to start'), findsOneWidget);
  });

  testWidgets('window background comes from config', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        config: TerminalConfig.defaults()
            .copyWith(colors: TerminalConfig.defaults().colors.copyWith(background: 0x102030)),
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns,
          required rows,
          required onPtyWrite,
          required onTitle,
          required onBell,
          required onClipboard,
          required engineConfig,
        }) => _FakeBinding(),
      ),
    ));
    await tester.pump();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF102030));
    title.dispose();
  });

  testWidgets('Ctrl+Shift+F toggles the search bar', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns, required rows,
          required onPtyWrite, required onTitle,
          required onBell, required onClipboard, required engineConfig,
        }) => _FakeBinding(),
      ),
    ));
    await tester.pump();
    expect(find.byType(TerminalSearchBar), findsNothing);
    // Open with Ctrl+Shift+F.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byType(TerminalSearchBar), findsOneWidget);
    title.dispose();
  });

  testWidgets('one-finger drag scrolls', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding();
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns,
          required rows,
          required onPtyWrite,
          required onTitle,
          required onBell,
          required onClipboard,
          required engineConfig,
        }) => binding,
      ),
    ));
    await tester.pump();
    await tester.drag(
      find.byType(CustomPaint).first,
      const Offset(0, -60),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(binding.scrollCalls, greaterThan(0));
    title.dispose();
  });

  testWidgets('long-press selects', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding();
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        ptyFactory: ({required rows, required columns}) => _FakePty(),
        engineFactory: ({
          required columns,
          required rows,
          required onPtyWrite,
          required onTitle,
          required onBell,
          required onClipboard,
          required engineConfig,
        }) => binding,
      ),
    ));
    await tester.pump();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    await tester.longPressAt(center);
    await tester.pump();
    expect(binding.selStartCalls, greaterThan(0));
    title.dispose();
  });
}
