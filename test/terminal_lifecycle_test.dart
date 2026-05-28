import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/ui/search_bar.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

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
}

class _ClearOnTapBinding extends _FakeBinding {
  _ClearOnTapBinding(this.onClear);
  final void Function() onClear;
  @override
  void selectionClear() => onClear();
}

class _FakeBinding implements EngineBinding {
  int scrollCalls = 0;
  int selStartCalls = 0;
  /// Forwarded into emitted GridUpdates so tests can flip kModeBracketedPaste
  /// etc. on the mirror grid via the existing refresh path.
  int modeFlags = 0;
  final Map<(int, int), int> hyperlinkAt = {};
  final Map<int, String> hyperlinkUris = {};

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
        modeFlags: modeFlags,
      );

  GridUpdate _hyperlinkSnapshot() {
    const cols = 80, rows = 24;
    final hyperlinks = Int32List(cols);
    final flags = Uint16List(cols);
    hyperlinkAt.forEach((rc, id) {
      if (rc.$1 == 0 && rc.$2 < cols) {
        hyperlinks[rc.$2] = id;
        flags[rc.$2] = kFlagHyperlink;
      }
    });
    final line0 = LineCells(
      line: 0,
      codepoints: Int32List(cols)..fillRange(0, cols, 32),
      fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
      bg: Int32List(cols)..fillRange(0, cols, 0x181818),
      flags: flags,
      hyperlinkId: hyperlinks,
    );
    LineCells blank(int i) => LineCells(
          line: i,
          codepoints: Int32List(cols)..fillRange(0, cols, 32),
          fg: Int32List(cols)..fillRange(0, cols, 0xD8D8D8),
          bg: Int32List(cols)..fillRange(0, cols, 0x181818),
          flags: Uint16List(cols),
          hyperlinkId: Int32List(cols),
        );
    return GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [line0, for (var i = 1; i < rows; i++) blank(i)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      modeFlags: modeFlags,
    );
  }

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
  bool searchSet(String pattern) => pattern != '(';
  @override
  bool searchNext() => false;
  @override
  bool searchPrev() => false;
  @override
  void searchClear() {}
  @override
  GridUpdate fullSnapshotSearched() => _hyperlinkSnapshot();
  @override
  String? resolveHyperlink(int id) => hyperlinkUris[id];
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

  testWidgets('invalid regex shows error indicator in search bar', (tester) async {
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
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '(');
    await tester.pump();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
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
    await tester.pumpAndSettle();
    // Bar is always mounted (Offstage prewarm); visibility tracked via its
    // own `visible` prop instead of widget presence.
    TerminalSearchBar bar() => tester.widget<TerminalSearchBar>(
        find.byType(TerminalSearchBar, skipOffstage: false));
    expect(bar().visible, isFalse);
    // Open with Ctrl+Shift+F.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(bar().visible, isTrue);
    // And the SAME hotkey closes it again (regression: the _searchOpen guard
    // used to swallow Ctrl+Shift+F before the toggle branch could fire).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(bar().visible, isFalse);
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

  testWidgets('tap clears selection', (tester) async {
    final title = ValueNotifier<String>('t');
    var cleared = false;
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
        }) => _ClearOnTapBinding(() => cleared = true),
      ),
    ));
    await tester.pump();
    await tester.tap(
      find.byType(CustomPaint).first,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(cleared, isTrue);
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

  testWidgets('Ctrl+left-click on a hyperlink cell launches the URI', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = _FakeBinding()
      ..hyperlinkAt[(0, 0)] = 5
      ..hyperlinkUris[5] = 'https://example.com';
    String? launched;
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
        launchUrl: (u) async {
          launched = u;
          return true;
        },
      ),
    ));
    await tester.pump();
    final pos = tester.getTopLeft(find.byType(CustomPaint).first) + const Offset(2, 2);
    // Prime the grid from the binding's searched snapshot (via selection refresh).
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(launched, 'https://example.com');
    title.dispose();
  });

  testWidgets('Ctrl+= increases cellHeight, Ctrl+0 restores', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    double cellH() {
      for (final paint in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
        if (paint.painter is TerminalPainter) {
          return (paint.painter as TerminalPainter).cellHeight;
        }
      }
      return 0.0;
    }
    final h0 = cellH();
    expect(h0, greaterThan(0));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(cellH(), greaterThan(h0));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(cellH(), h0);
    title.dispose();
  });

  testWidgets('plain right-click opens context menu with Copy/Paste/Search',
      (tester) async {
    final title = ValueNotifier<String>('t');
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
        }) => _FakeBinding(),
      ),
    ));
    await tester.pump();
    final center = tester.getCenter(find.byType(CustomPaint).first);
    final g = await tester.startGesture(
      center,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    expect(find.text('Search…'), findsOneWidget);
    title.dispose();
  });

  testWidgets('_flashBell with duration > 0 starts the bell animation',
      (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: title,
        config: TerminalConfig.defaults().copyWith(
          bell: const BellConfig(
            color: 0xFFFFFF,
            duration: 100,
            animation: 'linear',
          ),
        ),
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
    final state = tester.state(find.byType(TerminalScreen));
    (state as dynamic).flashBellForTest();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final ctrl = (state as dynamic).bellControllerForTest as AnimationController;
    expect(ctrl.value, lessThan(1.0));
    expect(ctrl.value, greaterThan(0.0));
    title.dispose();
  });

  testWidgets('Shift+right-click bypasses the menu (forwards to program)',
      (tester) async {
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
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final g = await tester.startGesture(
      center,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    title.dispose();
  });

  // Regression net for c9053a6: that font-zoom commit silently rewrote the
  // build() child chain in a way that lost the DropTarget wrapping AND
  // erased this test. 6b6f535 restored the implementation; we restore the
  // test here so any future re-rewrite of build() fails CI.
  testWidgets('DropTarget is wired into the widget tree', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => _FakeBinding(),
    )));
    await tester.pump();
    expect(find.byType(DropTarget), findsOneWidget);
    title.dispose();
  });

  testWidgets('drop writes shell-quoted, bracketed-paste-encoded paths', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    final binding = _FakeBinding()..modeFlags = (1 << 4); // kModeBracketedPaste
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => binding,
    )));
    await tester.pump();
    // Sync engine mode flags into the mirror grid (same path as selection refresh).
    await tester.tap(find.byType(CustomPaint).first);
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    (state as dynamic).simulateDrop([
      DropItemFile('/tmp/plain'),
      DropItemFile('/tmp/with space'),
    ]);
    await tester.pump();
    final bytes = pty.writes.expand((e) => e).toList();
    final written = String.fromCharCodes(bytes);
    expect(written.contains('\x1b[200~'), isTrue);
    expect(written.contains('/tmp/plain'), isTrue);
    expect(written.contains("'/tmp/with space'"), isTrue);
    expect(written.contains('\x1b[201~'), isTrue);
    title.dispose();
  });
}
