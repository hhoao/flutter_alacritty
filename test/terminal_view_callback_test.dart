import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/links/terminal_link_provider.dart';
import 'package:flutter_alacritty/links/url_link_provider.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

// ---------------------------------------------------------------------------
// Stub link provider for link-overlay tests.
// ---------------------------------------------------------------------------

class _StubProvider extends TerminalLinkProvider {
  _StubProvider(this.matchText, this.payload, {this.enabled = true});
  final String matchText;
  final String payload;
  bool enabled;

  @override
  Iterable<LinkSpan> scan(String lineText) {
    final i = lineText.indexOf(matchText);
    return i < 0
        ? const []
        : [LinkSpan(start: i, end: i + matchText.length, payload: payload)];
  }

  @override
  bool isEnabled(LinkSpan span) => enabled;
}

/// Provider whose spans start disabled and flip to enabled on [confirm], which
/// also fires `notifyListeners` — modelling an async validator (e.g. filesystem
/// existence check) confirming a candidate after the fact.
class _AsyncStubProvider extends TerminalLinkProvider {
  _AsyncStubProvider(this.matchText, this.payload);
  final String matchText;
  final String payload;
  bool _ready = false;

  @override
  Iterable<LinkSpan> scan(String lineText) {
    final i = lineText.indexOf(matchText);
    return i < 0
        ? const []
        : [LinkSpan(start: i, end: i + matchText.length, payload: payload)];
  }

  @override
  bool isEnabled(LinkSpan span) => _ready;

  void confirm() {
    _ready = true;
    notifyListeners();
  }
}

Future<TerminalEngine> _engineForView(FakeBinding binding) async {
  // Use the lazy constructor path; the view drives `resize` on its first
  // build via the LayoutBuilder, which boots the binding under the hood.
  // For tests we bind eagerly so the view can paint a non-empty grid.
  return TerminalEngine.fromBinding(
    binding,
    config: TerminalConfig.defaults(),
    schedule: (_) {},
  );
}

Future<void> _pumpView(
  WidgetTester tester, {
  required TerminalEngine engine,
  void Function(TapDownDetails, CellOffset)? onTapDown,
  void Function(TapUpDetails, CellOffset)? onTapUp,
  void Function(TapDownDetails, CellOffset)? onSecondaryTapDown,
  void Function(TapUpDetails, CellOffset)? onSecondaryTapUp,
  void Function(String)? onLinkActivate,
  void Function()? onBell,
  Duration bellDuration = Duration.zero,
  bool primaryTapActivatesLink = false,
  List<TerminalLinkProvider>? linkProviders,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TerminalView(
        engine,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onSecondaryTapDown: onSecondaryTapDown,
        onSecondaryTapUp: onSecondaryTapUp,
        onLinkActivate: onLinkActivate,
        onBell: onBell,
        bellDuration: bellDuration,
        primaryTapActivatesLink: primaryTapActivatesLink,
        linkProviders: linkProviders ?? const [],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _hoverAt(WidgetTester tester, Offset global) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.moveTo(global);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('onTapUp fires with the CellOffset of the tap', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    TapUpDetails? gotDetails;
    CellOffset? gotCell;
    await _pumpView(
      tester,
      engine: engine,
      onTapUp: (d, c) {
        gotDetails = d;
        gotCell = c;
      },
    );

    // Top-left of the painter, offset by ~2px so it lands inside cell (0,0).
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final tapPos = painterTopLeft + const Offset(2, 2);
    final g = await tester.startGesture(tapPos, kind: PointerDeviceKind.mouse);
    await g.up();
    await tester.pump();

    expect(gotDetails, isNotNull);
    expect(gotCell, isNotNull);
    expect(gotCell!.row, 0);
    expect(gotCell!.column, 0);
  });

  testWidgets('onSecondaryTapUp fires for right-click', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    CellOffset? gotCell;
    await _pumpView(
      tester,
      engine: engine,
      onSecondaryTapUp: (_, c) => gotCell = c,
    );

    final center = tester.getCenter(find.byType(CustomPaint).first);
    final g = await tester.startGesture(
      center,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pump();

    expect(gotCell, isNotNull);
  });

  testWidgets('onBell spy is called when bell fires', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    var bells = 0;
    await _pumpView(
      tester,
      engine: engine,
      onBell: () => bells++,
      bellDuration: const Duration(milliseconds: 100),
    );

    binding.onBell!();
    await tester.pump();

    expect(bells, 1);
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.bellControllerForTest.value, greaterThan(0.0));
  });

  testWidgets('bellDuration zero keeps animation at 0', (tester) async {
    final binding = FakeBinding();
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    var bells = 0;
    await _pumpView(
      tester,
      engine: engine,
      onBell: () => bells++,
      // Default Duration.zero — visual flash must short-circuit.
      bellDuration: Duration.zero,
    );

    binding.onBell!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));

    expect(bells, 1);
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.bellControllerForTest.value, 0.0);
  });

  // Regression for the engine-swap bug caught in 2W code review: TerminalView
  // subscribes to engine.bell in initState but didUpdateWidget originally
  // didn't compare widget.engine to oldWidget.engine, so after a host-driven
  // engine swap (e.g. shell restart) the bell stream pointed at the disposed
  // OLD engine and any Bell event was silently lost.
  testWidgets('bell after engine swap still flashes the visual bell',
      (tester) async {
    final binding1 = FakeBinding();
    final engine1 = TerminalEngine.fromBinding(
      binding1,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    final binding2 = FakeBinding();
    final engine2 = TerminalEngine.fromBinding(
      binding2,
      config: TerminalConfig.defaults(),
      schedule: (_) {},
    );
    addTearDown(() {
      engine1.dispose();
      engine2.dispose();
    });

    // The harness lets the test swap the engine prop and triggers
    // didUpdateWidget on the inner TerminalView.
    final engineNotifier = ValueNotifier<TerminalEngine>(engine1);
    addTearDown(engineNotifier.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<TerminalEngine>(
          valueListenable: engineNotifier,
          builder: (context, engine, _) => TerminalView(
            engine,
            // Non-zero duration so _flashBell actually animates the
            // controller (zero-duration short-circuits).
            bellDuration: const Duration(milliseconds: 100),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    AnimationController bellCtrl() {
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      return state.bellControllerForTest;
    }

    // Drive bell events through the rewired binding callback directly —
    // simpler than queueing a pendingEvent + feeding through the drain (which
    // would need the schedule shim wired). `_bindEager` populates binding.onBell
    // at fromBinding construction time, pointing at the engine's bellCtl.add.

    // Sanity: pre-swap bell fires through engine1.
    binding1.onBell!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(bellCtrl().value, greaterThan(0.0),
        reason: 'bell on the initial engine should animate the controller');

    // Let the animation settle so we observe a fresh trigger after the swap.
    await tester.pump(const Duration(milliseconds: 200));
    expect(bellCtrl().value, 0.0);

    // SWAP the engine — Without the didUpdateWidget fix, _bellSub still
    // points at engine1 (whose stream is about to close on dispose), so
    // the next bell would be dropped.
    engineNotifier.value = engine2;
    await tester.pump();

    binding2.onBell!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    expect(bellCtrl().value, greaterThan(0.0),
        reason:
            'bell on the swapped-in engine must also animate — TerminalView '
            'must cancel + re-subscribe _bellSub on engine identity change');
  });

  testWidgets('onLinkActivate fires for Ctrl+left-click on a hyperlink cell',
      (tester) async {
    final binding = FakeBinding()
      ..hyperlinkAt[(0, 0)] = 7
      ..hyperlinkUris[7] = 'https://example.org';
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
    );

    // Prime the mirror grid with the hyperlink-bearing snapshot — the view's
    // hyperlink lookup reads from the grid, and the grid is populated on
    // the engine's first refresh, which the FakeBinding ties to selection
    // events. A throwaway click registers that refresh.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    // Ctrl+left-click on the hyperlink cell.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, 'https://example.org');
  });

  testWidgets(
      'primaryTapActivatesLink: a plain left-click on a hyperlink fires '
      'onLinkActivate without falling through to selection', (tester) async {
    final binding = FakeBinding()
      ..hyperlinkAt[(0, 0)] = 7
      ..hyperlinkUris[7] = 'https://example.org';
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      primaryTapActivatesLink: true,
      onLinkActivate: (uri) => launched = uri,
    );

    final painterTopLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    // Prime the mirror grid with the hyperlink snapshot.
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    final selStartBefore = binding.selStartCalls;
    // Plain left-click (no modifiers) on the hyperlink cell.
    final click = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.pump();

    expect(launched, 'https://example.org');
    // The press was consumed by link activation, not by a selection start —
    // and the matching release is swallowed too (no double handling).
    expect(binding.selStartCalls, selStartBefore);
  });

  testWidgets(
      'without primaryTapActivatesLink, a plain left-click does NOT fire '
      'onLinkActivate (only Ctrl/Cmd-click does)', (tester) async {
    final binding = FakeBinding()
      ..hyperlinkAt[(0, 0)] = 7
      ..hyperlinkUris[7] = 'https://example.org';
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
    );

    final painterTopLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    final click = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.pump();

    expect(launched, isNull);
  });

  testWidgets('linkOverlay decorates hovered row when provider matches',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload');
    final binding = TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    await _pumpView(
      tester,
      engine: engine,
      linkProviders: [provider],
    );

    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    await _hoverAt(tester, pos);

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final overlay = state.linkOverlayForTest;
    expect(overlay.isLinkCell(0, 0), isTrue,
        reason: 'hovering a provider link row should decorate that row only');
    expect(overlay.isLinkCell(0, matchText.length + 5), isFalse,
        reason: 'columns outside the span should not be link cells');
  });

  testWidgets(
      'Ctrl+click on enabled provider span fires onLinkActivate(payload)',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload');
    final binding = TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
      linkProviders: [provider],
    );

    // Throwaway click to prime the grid.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    await _hoverAt(tester, pos);

    // Ctrl+left-click on cell (0,0) which is inside STUB_LINK.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, 'stub-payload',
        reason: 'Ctrl+click on an enabled overlay link should fire onLinkActivate');
  });

  testWidgets('Ctrl+click on disabled provider span does NOT fire onLinkActivate',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload', enabled: false);
    final binding = TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      onLinkActivate: (uri) => launched = uri,
      linkProviders: [provider],
    );

    // Throwaway click to prime the grid.
    final painterTopLeft =
        tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    await _hoverAt(tester, pos);

    // The overlay should be empty because the provider is disabled.
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isFalse,
        reason: 'disabled provider should not add cells to the overlay');

    // Ctrl+click should not fire the callback.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click =
        await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, isNull,
        reason: 'disabled span should not trigger onLinkActivate');
  });

  testWidgets('overlay refreshes hovered row after scroll', (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _StubProvider(matchText, 'stub-payload');
    final binding = TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    await _pumpView(tester, engine: engine, linkProviders: [provider]);

    final painterTopLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    await _hoverAt(tester, pos);

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isTrue,
        reason: 'hover should decorate the link row');

    engine.scrollLines(1);
    await tester.pump();

    await _hoverAt(tester, pos);
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isTrue,
        reason: 'overlay should refresh the hovered row after scroll');
  });

  testWidgets('provider notifyListeners refreshes the hovered row',
      (tester) async {
    const matchText = 'STUB_LINK';
    final provider = _AsyncStubProvider(matchText, 'stub-payload');
    final binding = TextFakeBinding(matchText);
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    await _pumpView(
      tester,
      engine: engine,
      linkProviders: [provider],
    );

    final painterTopLeft = tester.getTopLeft(find.byType(CustomPaint).first);
    final pos = painterTopLeft + const Offset(2, 2);
    final prime = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await prime.up();
    await tester.pump();

    await _hoverAt(tester, pos);

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.linkOverlayForTest.isLinkCell(0, 0), isFalse,
        reason: 'unconfirmed async span should not be a link cell');

    provider.confirm();
    await tester.pump();

    expect(state.linkOverlayForTest.isLinkCell(0, 0), isTrue,
        reason: 'provider notifyListeners should refresh the hovered row');
  });

  testWidgets('empty linkProviders: Ctrl+click does not scan provider URLs',
      (tester) async {
    final binding = TextFakeBinding('https://example.org');
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      linkProviders: const [],
      onLinkActivate: (uri) => launched = uri,
    );

    final pos = tester.getTopLeft(find.byType(CustomPaint).first) +
        const Offset(2, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, isNull);
  });

  testWidgets('provider link activates on Ctrl+click without prior hover',
      (tester) async {
    final binding = TextFakeBinding('https://example.org');
    final engine = await _engineForView(binding);
    addTearDown(engine.dispose);

    String? launched;
    await _pumpView(
      tester,
      engine: engine,
      linkProviders: [UrlLinkProvider()],
      onLinkActivate: (uri) => launched = uri,
    );

    final pos = tester.getTopLeft(find.byType(CustomPaint).first) +
        const Offset(2, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final click = await tester.startGesture(pos, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(launched, 'https://example.org');
  });
}
