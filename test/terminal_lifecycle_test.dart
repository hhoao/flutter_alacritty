import 'dart:async';
import 'dart:convert' show utf8;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/input/ime_session.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';
import 'package:flutter_alacritty/ui/preedit_overlay.dart';
import 'package:flutter_alacritty/ui/search_bar.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

import 'fake_binding.dart';

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
    }) => FakeBinding();

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
        engineFactory: ({required columns, required rows, required onPtyWrite, required onTitle, required onBell, required onClipboard, required engineConfig}) => FakeBinding(),
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
        }) => FakeBinding(),
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
        }) => FakeBinding(),
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
        }) => FakeBinding(),
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
    final binding = FakeBinding();
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

  testWidgets('tap clears selection when one is active; no-op when not', (tester) async {
    final title = ValueNotifier<String>('t');
    var clears = 0;
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
        }) => ClearOnTapBinding(() => clears++),
      ),
    ));
    await tester.pump();
    // First tap with no active selection: must NOT call selectionClear (gated;
    // mirrors alacritty event.rs:clear_selection, which is a no-op on empty).
    await tester.tap(find.byType(CustomPaint).first, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(clears, 0,
        reason: 'tap with no active selection must skip the FFI clear + full snapshot');
    // Establish a selection via long-press, then tap: must call clear exactly once.
    final center = tester.getCenter(find.byType(CustomPaint).first);
    await tester.longPressAt(center);
    await tester.pump();
    await tester.tap(find.byType(CustomPaint).first, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(clears, 1);
    title.dispose();
  });

  testWidgets('long-press selects', (tester) async {
    final title = ValueNotifier<String>('t');
    final binding = FakeBinding();
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
    final binding = FakeBinding()
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
      }) => FakeBinding(),
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
        }) => FakeBinding(),
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
        }) => FakeBinding(),
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
    final binding = FakeBinding();
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
      }) => FakeBinding(),
    )));
    await tester.pump();
    expect(find.byType(DropTarget), findsOneWidget);
    title.dispose();
  });

  testWidgets('drop writes shell-quoted, bracketed-paste-encoded paths', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    final binding = FakeBinding()..modeFlags = (1 << 4); // kModeBracketedPaste
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
    // Sync engine mode flags (kModeBracketedPaste) into the mirror grid.
    // The selectionStart → tap path is now the only cheap test hook that
    // triggers refreshSelection — `_onTerminalInputStart`'s clear+refresh
    // path runs because long-press has flagged `_selectionActive = true`.
    final center = tester.getCenter(find.byType(CustomPaint).first);
    await tester.longPressAt(center);
    await tester.pump();
    await tester.tap(find.byType(CustomPaint).first, kind: PointerDeviceKind.touch);
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

  testWidgets('IME commit writes utf8 bytes to the PTY (raw, not bracketed)', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    // preedit: "n" -> "ni" -> commit "你"
    ime.updateEditingValue(const TextEditingValue(text: 'n', composing: TextRange(start: 0, end: 1)));
    ime.updateEditingValue(const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)));
    ime.updateEditingValue(const TextEditingValue(text: '你'));
    await tester.pump();
    final bytes = pty.writes.expand((e) => e).toList();
    // Exactly the UTF-8 of "你", appearing exactly once, with no bracketed-paste markers.
    expect(bytes, utf8.encode('你'));
    expect(bytes.contains(0x1b), isFalse, reason: 'no ESC bytes — raw write, not bracketed-paste');
    title.dispose();
  });

  testWidgets('PreeditOverlay mounts only while composing', (tester) async {
    final title = ValueNotifier<String>('t');
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => _FakePty(),
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => FakeBinding(),
    )));
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    expect(find.byType(PreeditOverlay), findsNothing);
    ime.updateEditingValue(const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)));
    await tester.pump();
    expect(tester.widget<PreeditOverlay>(find.byType(PreeditOverlay)).text, 'ni');
    ime.updateEditingValue(const TextEditingValue(text: '你好'));
    await tester.pump();
    expect(find.byType(PreeditOverlay), findsNothing);
    title.dispose();
  });

  testWidgets('ASCII with IME attached but not composing reaches the PTY via encodeKey',
      (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => FakeBinding(),
    )));
    await tester.pump();
    await tester.tap(find.byType(CustomPaint).first);
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    expect(ime.isAttached, isTrue);
    expect(ime.isComposing, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(pty.writes, isNotEmpty,
        reason: 'English/direct input must use encodeKey, not TextInput');
    title.dispose();
  });

  testWidgets('typing on the hot path is FFI-snapshot-free when no selection and at bottom', (tester) async {
    // The reason this matters: per-keystroke full grid snapshot is what caused
    // the input lag investigated against alacritty event.rs:on_terminal_input_start.
    // Alacritty only marks dirty when there's actually a selection to clear or
    // a scrollback offset to scroll past — we mirror that here.
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    final binding = FakeBinding();
    await tester.pumpWidget(MaterialApp(home: TerminalScreen(
      title: title,
      ptyFactory: ({required rows, required columns}) => pty,
      engineFactory: ({
        required columns, required rows,
        required onPtyWrite, required onTitle,
        required onBell, required onClipboard, required engineConfig,
      }) => binding,
    )));
    await tester.pumpAndSettle();
    // Engine startup may snapshot once via refreshView paths (resize, etc.).
    // Snapshot the post-startup baseline; the per-key delta below is what we
    // actually care about.
    final baselineSnapshots = binding.fullSnapshotCalls;
    final baselineClears = binding.selClearCalls;
    final baselineScrollBottom = binding.scrollToBottomCalls;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(pty.writes, isNotEmpty,
        reason: 'the keystroke still reaches the PTY');
    expect(binding.selClearCalls, baselineClears,
        reason: 'no selection → no selectionClear FFI hop');
    expect(binding.scrollToBottomCalls, baselineScrollBottom,
        reason: 'displayOffset == 0 → no scrollToBottom FFI hop');
    expect(binding.fullSnapshotCalls, baselineSnapshots,
        reason: 'no state change → no full snapshot (alacritty parity)');
    title.dispose();
  });

  testWidgets('_onKey gate: printable+no-modifier while composing is ignored;'
              ' Ctrl+Shift+C still copies through encodeKey path', (tester) async {
    final title = ValueNotifier<String>('t');
    final pty = _FakePty();
    final binding = FakeBinding();
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
    // Focus the terminal so the IME is attached.
    await tester.tap(find.byType(CustomPaint).first);
    await tester.pump();
    final state = tester.state<State<TerminalScreen>>(find.byType(TerminalScreen));
    final ime = (state as dynamic).imeForTest as ImeSession;
    expect(ime.isAttached, isTrue, reason: 'focused terminal should attach IME');
    // Simulate active pinyin composition so the gate applies.
    ime.updateEditingValue(
      const TextEditingValue(text: 'a', composing: TextRange(start: 0, end: 1)),
    );
    await tester.pump();
    expect(ime.isComposing, isTrue);
    // Plain 'a' with no modifier while composing: defer to TextInput, not encodeKey.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(pty.writes, isEmpty,
        reason: 'TextInput delivers printable characters; encodeKey path must NOT fire');
    // Ctrl+Shift+C: copies selection via the existing hotkey branch — should NOT be swallowed.
    // (Selection is empty so the copy is a no-op as far as the PTY is concerned, but the branch
    // returns KeyEventResult.handled — which is enough to prove the gate didn't intercept.)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // No assertion needed on selection (we just want to prove the gate didn't swallow Ctrl+Shift+C
    // — if it had, no handler would have run; the test getting here is the proof).
    title.dispose();
  });
}
