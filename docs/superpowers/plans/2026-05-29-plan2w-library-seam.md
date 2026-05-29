# flutter_alacritty Plan 2W — Library Widget Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Treat each task as a single commit; the suite must stay green after every task** so we can stop or roll back at any boundary.

**Goal:** Refactor monolithic `TerminalScreen` into a three-layer library API matching xterm.dart's shape — `TerminalEngine` (engine handle, no PTY), `TerminalController` (selection/search/scroll state, `ChangeNotifier`), `TerminalView` (pure widget, `shortcuts` + callbacks). Current `TerminalScreen` becomes the reference consumer (example app) wiring PTY, restart overlay, search bar UI, context menu, drop, `url_launcher`. After 2W, flutter_alacritty is embeddable as a library.

**Architecture summary:** The library's public surface becomes `TerminalEngine` / `TerminalController` / `TerminalView` / `TerminalTheme` / `TerminalStyle` (plus the existing `PtyBackend` / `FlutterPtyBackend` / config types since the example app needs them). `TerminalView` only ever talks to `TerminalEngine`, never directly to a PTY; the consumer wires `pty.output → engine.feed` and `engine.output → pty.write` in two lines. The `shortcuts` map (top-level const `defaultTerminalShortcuts` over Flutter's `Shortcuts`/`Actions` framework) replaces the inline `_onKey` hotkey switch.

**Tech Stack:** Flutter `Shortcuts` / `Actions` / `Intent`; `dart:async.StreamController.broadcast`; existing `ChangeNotifier`, `ValueListenable`.

**Spec:** `docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md`
**Branch:** `feature/W-library-seam` off `main` @ `25b0ebb`.

**Verified facts (worktree-confirmed):**

- `lib/ui/terminal_screen.dart` is 894 lines. `class TerminalScreen` at line 74; `_TerminalScreenState` at line 94. Public constructor params (line 75-82): `title: ValueNotifier<String>`, `ptyFactory: PtyFactory?`, `engineFactory: EngineFactory?`, `config: TerminalConfig?`, `launchUrl: UrlLauncher?`. Typedefs `PtyFactory` / `EngineFactory` / `UrlLauncher` at lines 55-70.
- `lib/flutter_alacritty.dart` currently exports: `config/config_loader.dart`, `config/terminal_config.dart`, `engine/engine_binding.dart`, `engine/terminal_engine_client.dart`, `pty/pty_backend.dart`, `pty/flutter_pty_backend.dart`, `ui/terminal_screen.dart`.
- `lib/engine/terminal_engine_client.dart` (142 lines) is the closest existing approximation of `TerminalEngine`. Already owns `_buf` BytesBuilder + `_drain`/`_advancing` coalescing pipeline.
- `lib/engine/engine_binding.dart::FrbEngineBinding` is constructed with callbacks: `onPtyWrite`, `onTitle`, `onBell`, `onClipboard` (lines 44-55). These callbacks are currently set inside `_TerminalScreenState._start` and forward to `widget.title.value =`, `_flashBell`, etc.
- `TerminalScreen` private state inventory (lines 119-167):
  - Lifecycle: `_client`, `_pty`, `_outputSub`, `_cols`, `_rows`, `_status: TermStatus`, `_exitCode`, `_errorMessage`
  - Render/font: `_fontSize`, `_style`, `_metrics`, `_glyphs`, `_bellCtrl`, `_blinkOn`, `_blinkTimer`, `_grid`
  - Focus/IME: `_focus`, `_preedit`, `_ime`, `_lastReportedCaretRect`
  - Mouse/selection: `_pressedButton`, `_clickCount`, `_lastClick`, `_selecting`, `_selectionActive`, `_primary`, `_lastFocused`, `_hoverCursor`
  - Search: `_searchOpen`, `_searchInvalid`
  - Touch/fling: `_touchScrollAccum`, `_flingTimer`
- Hardcoded hotkeys live in `_onKey` (line 297 onwards): Ctrl+Shift+F toggle search (~298), Ctrl+= / Ctrl+- (font zoom +/-, ~309-318), Ctrl+0 (zoom reset, ~319-322), Ctrl+Shift+V (paste, ~326-330), Ctrl+Shift+C (copy selection, ~332-336). All call into `setState` / `_paste()` / `_setZoom()` / clipboard.
- 134 widget+unit tests on main, all green; `flutter analyze` clean.
- Build pitfalls (memory): `engine_bindings_test._findOrBuildLib` prefers `release > debug`; stale `build/linux/x64/release/...so` shadows fresh debug builds → FRB content-hash panic. **2W is Dart-only — no Rust changes**, so this should not bite, but if `engine_bindings_test` fails with the content-hash error, `rm -rf build/linux/x64/release`.

**Critical safety rule:** Each task is a *move*, not a *rewrite*. Existing widget tests are the regression net; if any of the 134 baseline tests fails during a task, you've changed behavior — stop and reconcile before continuing. New tests are *additions* pinning the new seams.

---

## File Structure

```
lib/engine/terminal_engine.dart           NEW    Engine handle: wraps client+grid+binding;
                                                 streams for output/title/bell/clipboard;
                                                 write(bytes); hyperlinkAt(r,c).
lib/controller/terminal_controller.dart   NEW    ChangeNotifier; selection/search/scroll/primary state.
lib/ui/terminal_view.dart                 NEW    Pure widget: render+input+IME. Required engine,
                                                 optional controller/theme/style/padding/callbacks/shortcuts.
lib/ui/terminal_shortcuts.dart            NEW    defaultTerminalShortcuts map + Intent classes
                                                 + defaultTerminalActions factory.
lib/theme/terminal_theme.dart             NEW    TerminalTheme (colors subset) + TerminalStyle (font subset).
lib/example/example_app.dart              NEW    Reference consumer; was lib/ui/terminal_screen.dart.
                                                 PTY lifecycle, restart overlay, search bar UI,
                                                 right-click menu, drop, url_launcher.
lib/ui/terminal_screen.dart               DEL    Removed after Task 4 (replaced by example_app.dart).
lib/main.dart                             MOD    Use example_app.dart.
lib/flutter_alacritty.dart                MOD    Export new public API; remove terminal_screen.dart.

test/terminal_engine_test.dart            NEW    write→output round-trip, title listenable,
                                                 hyperlinkAt, dispose closes streams.
test/terminal_controller_test.dart        NEW    Pure-Dart: ChangeNotifier semantics + selection
                                                 + search + scroll state.
test/terminal_view_shortcut_test.dart     NEW    defaults + override + disabled shortcuts.
test/terminal_view_callback_test.dart     NEW    onTapUp / onSecondaryTapUp / onLinkActivate.
test/terminal_lifecycle_test.dart         MOD    Switch to TerminalView for widget tests; existing
                                                 134 tests adjusted minimally.
docs/superpowers/plans/2026-05-29-plan2w-findings.md   NEW (Task 6)
```

---

## Task 0: Branch + worktree

- [ ] **Step 1: Create the feature branch in a worktree**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git worktree add .worktrees/W-library-seam -b feature/W-library-seam main
cd .worktrees/W-library-seam
git rev-parse --abbrev-ref HEAD   # expect: feature/W-library-seam
git submodule update --init --recursive   # ensure rust_lib submodule is at the right commit
flutter test 2>&1 | tail -3       # baseline: must say "All tests passed!" with 134
```

If the baseline is not 134/0 green, stop and reconcile with main before doing anything else.

---

## Task 1: Extract `TerminalEngine` (engine handle, no PTY)

**Goal:** Wrap `TerminalEngineClient` + `MirrorGrid` + `EngineBinding` behind a clean public surface; replace the four `onPtyWrite`/`onTitle`/`onBell`/`onClipboard` callbacks on `FrbEngineBinding` with streams/listenables. `TerminalScreen` migrates to use `TerminalEngine` internally; no consumer-visible behavior change.

**Files:**

- Create: `lib/engine/terminal_engine.dart`
- Modify: `lib/ui/terminal_screen.dart` (uses `TerminalEngine` instead of `_client`+`_pty` direct)
- Create test: `test/terminal_engine_test.dart`

**Public API for this task:**

```dart
class TerminalEngine {
  /// Default ctor: engineFactory defaults to FrbEngineBinding. The factory is
  /// invoked lazily on the first feed/resize, so a consumer can construct and
  /// inspect basics (default theme etc.) without paying native init cost yet.
  TerminalEngine({
    required TerminalConfig config,
    EngineFactory? engineFactory,
  });

  /// Test-only: wire a pre-built binding (e.g. _FakeBinding from widget tests).
  @visibleForTesting
  factory TerminalEngine.fromBinding(EngineBinding binding, {required TerminalConfig config});

  /// PTY → engine.
  void feed(Uint8List bytes);

  /// Cell-grid resize.
  void resize({required int columns, required int rows});

  /// Engine → PTY. Broadcast stream combining: (a) Event::PtyWrite payloads
  /// from the parser, (b) bytes pushed via [write]. Consumer drains this
  /// into the PTY in one line: `engine.output.listen(pty.write)`.
  Stream<Uint8List> get output;

  /// View → engine (keystrokes, paste bytes, mouse reports). Appears on
  /// [output] in the same tick.
  void write(Uint8List bytes);

  ValueListenable<String> get title;        // updated on Event::Title / Event::ResetTitle
  Stream<void> get bell;                    // each Event::Bell
  Stream<String> get clipboardStore;        // OSC 52 SET (Event::ClipboardStore)

  /// Listenable for the painter to bind via `CustomPaint(repaint: ...)`.
  Listenable get repaint;
  MirrorGrid get gridForView;               // package-private-via-comment; the view needs it

  /// URL launch helper: hyperlink id at (row, col), if any.
  String? hyperlinkAt(int row, int col);

  /// Search proxies (forwarded to the underlying client).
  bool searchSet(String pattern);
  bool searchNext();
  bool searchPrev();
  void searchClear();

  /// Selection proxies.
  void selectionStart(int row, int col, bool rightHalf, int kind);
  void selectionUpdate(int row, int col, bool rightHalf);
  void selectionClear();
  String? selectionText();

  /// Scroll.
  Future<void> scrollLines(int delta);
  Future<void> scrollToBottom();

  void dispose();
}
```

- [ ] **Step 1: Write the failing test** — create `test/terminal_engine_test.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

// Reuse the same _FakeBinding pattern as terminal_lifecycle_test; here only
// what we need to pin TerminalEngine's seam.
class _FakeBinding implements EngineBinding {
  final feeds = <Uint8List>[];
  final emitEvents = <_FakeEvent>[];
  GridUpdate _blank() => GridUpdate(
        full: true, rows: 1, columns: 1,
        lines: [LineCells(line: 0, codepoints: Int32List(1), fg: Int32List(1),
                          bg: Int32List(1), flags: Uint16List(1))],
        cursorRow: 0, cursorCol: 0, cursorVisible: true);
  @override
  Future<void> advance(Uint8List bytes) async { feeds.add(bytes); }
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async { feeds.add(bytes); return _blank(); }
  @override Future<GridUpdate> takeDamage() async => _blank();
  @override GridUpdate fullSnapshot() => _blank();
  @override GridUpdate fullSnapshotSearched() => _blank();
  @override void pumpEvents() { /* drain emitEvents — done via callback set by FrbEngineBinding;
                                 the equivalent here is done in the test by pushing to streams. */ }
  // ... remaining EngineBinding methods as no-op / counted ...
}

void main() {
  test('write(bytes) flows out via output stream', () async {
    // ... construct engine via fromBinding, write(b'hi'), expect first listen event b'hi' ...
  });

  test('Event::Title updates title ValueListenable', () async {
    // ... drive the binding to emit a title event, expect engine.title.value == 'hi' ...
  });

  test('hyperlinkAt forwards to engine.resolveHyperlink', () async {
    // ... populate fake's hyperlinkUris, engine.hyperlinkAt(0, 0) == expected ...
  });

  test('dispose closes output / bell / clipboard streams', () async {
    // ... engine.dispose(); expect streams isDone or hasError on subsequent listen attempts ...
  });
}
```

Flesh out each test body — the exact construction depends on how `_FakeBinding` is split out. To avoid duplicating it, **lift `_FakeBinding` from `test/terminal_lifecycle_test.dart` into `test/fake_binding.dart`** in this task and import it from both places. This is incidental but unblocks reusing the binding in `test/terminal_engine_test.dart`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
flutter test test/terminal_engine_test.dart 2>&1 | tail -5
# Expect: compile error (terminal_engine.dart doesn't exist yet) or all tests fail.
```

- [ ] **Step 3: Implement `lib/engine/terminal_engine.dart`** — wrap the existing client and grid; route binding callbacks through internal stream controllers.

Key design points:

1. **Output stream is `StreamController<Uint8List>.broadcast()`**. The engine's existing `TerminalEngineClient._drain` already calls `_binding.pumpEvents()` which dispatches `EngineEvent::PtyWrite` via the `onPtyWrite` callback set on `FrbEngineBinding`. Re-route that callback to push into the controller. Bytes from `write(bytes)` also push into the same controller — single ordered sink.
2. **Title is `ValueNotifier<String>`** exposed as `ValueListenable<String>`. The binding's `onTitle` callback writes into it.
3. **Bell is `StreamController<void>.broadcast()`**; clipboardStore is `StreamController<String>.broadcast()`. Same pattern.
4. **The lazy-factory promise** in the API doc means we can't construct `FrbEngineBinding` until the first `feed` / `resize` call. Implementation: keep `_binding` nullable; build it on first use using the cached `EngineConfig`.
5. **`gridForView`** exposes the `MirrorGrid`. We'll add `@internal` from `package:meta` on this getter so external library users get a static warning if they touch it; only `TerminalView` (same package) should call it.

Sketch:

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';
import '../config/terminal_config.dart';
import '../render/mirror_grid.dart';
import 'engine_binding.dart';
import 'terminal_engine_client.dart';

class TerminalEngine {
  TerminalEngine({required TerminalConfig config, EngineFactory? engineFactory})
      : _config = config,
        _factory = engineFactory ?? _defaultFactory;

  @visibleForTesting
  TerminalEngine.fromBinding(EngineBinding binding, {required TerminalConfig config})
      : _config = config,
        _factory = (_) => binding,
        _binding = binding {
    _wireBinding(binding);
  }

  final TerminalConfig _config;
  final EngineBinding Function(_EngineFactoryArgs) _factory;

  EngineBinding? _binding;
  TerminalEngineClient? _client;
  final MirrorGrid _grid = MirrorGrid(/* defaults from _config */);

  final _output = StreamController<Uint8List>.broadcast();
  final _title = ValueNotifier<String>('flutter_alacritty');
  final _bell = StreamController<void>.broadcast();
  final _clipboardStore = StreamController<String>.broadcast();

  // ... feed/resize/write/getters as in the public API ...

  void _wireBinding(EngineBinding b) {
    // The FrbEngineBinding takes onPtyWrite/onTitle/onBell/onClipboard in its
    // constructor; we wire them to our streams. For the @visibleForTesting
    // fromBinding path, the caller has already constructed the binding with
    // appropriate callbacks (typically a _FakeBinding that takes none).
  }
}
```

The wiring requires `FrbEngineBinding`'s constructor to accept our callback closures. Since the factory pattern is already there (`engineFactory` typedef), the engine constructs:

```dart
final binding = _factory(_EngineFactoryArgs(
  columns: cols, rows: rows,
  onPtyWrite: (bytes) => _output.add(bytes),
  onTitle: (t) => _title.value = t,
  onBell: () => _bell.add(null),
  onClipboard: (t) => _clipboardStore.add(t),
  engineConfig: _config.engineConfig,
));
```

The current `EngineFactory` typedef from `terminal_screen.dart:60` already accepts those callbacks; we re-use it.

- [ ] **Step 4: Migrate `TerminalScreen` to use `TerminalEngine` internally** — keep behavior identical.

In `_TerminalScreenState`:
- Replace `_client` field with `_engine: TerminalEngine?` (still nullable for spawn-failure path).
- Replace `_grid` field — read it from `_engine!.gridForView` (lazy: first build pass when engine exists).
- Replace `_start`'s direct `TerminalEngineClient` construction with `_engine = TerminalEngine(config: _config, engineFactory: widget.engineFactory)`.
- The widget callback `widget.title: ValueNotifier<String>` is now driven by listening to `engine.title`: `_engine!.title.addListener(() => widget.title.value = _engine!.title.value)`.
- `_writeCommittedText` and `_pty?.write(bytes)` in `_onKey` become `_engine?.write(bytes)`.
- The consumer's PTY is still wired by `_TerminalScreenState`: subscribe `_pty!.output.listen(_engine!.feed)` and `_engine!.output.listen(_pty!.write)`.

This is mechanical — the existing `TerminalEngineClient` already does the parser-drain work; `TerminalEngine` just hides it.

- [ ] **Step 5: Run the suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -3
# Expect: zero issues; 134+ tests passing (4-5 new tests in terminal_engine_test).
```

- [ ] **Step 6: Commit**

```bash
git add lib/engine/terminal_engine.dart lib/ui/terminal_screen.dart \
        test/terminal_engine_test.dart test/fake_binding.dart \
        test/terminal_lifecycle_test.dart
git commit -m "refactor(engine): extract TerminalEngine handle (wraps client+grid+binding)

Library-shape prep: TerminalEngine wraps TerminalEngineClient + MirrorGrid +
EngineBinding behind streams (output/bell/clipboardStore) + ValueListenable
(title). FrbEngineBinding callbacks are now internal — the public surface is
just feed/resize/write/output. TerminalScreen migrated to use it; behavior
is identical (regression-tested by the existing 134 widget tests).

Test-only TerminalEngine.fromBinding(EngineBinding) escape hatch lets the
existing _FakeBinding pattern keep working. _FakeBinding lifted to
test/fake_binding.dart so both lifecycle and engine tests can import it.

Spec: docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md §4.1.
"
```

---

## Task 2: Lift `TerminalController` (selection/search/scroll state)

**Goal:** Move selection / search / scroll / `_primary` / `_selectionActive` / `_clickCount` state out of `_TerminalScreenState` into a standalone `TerminalController extends ChangeNotifier`. `TerminalScreen` keeps a controller instance and proxies through it. No behavior change.

**Files:**
- Create: `lib/controller/terminal_controller.dart`
- Modify: `lib/ui/terminal_screen.dart` (state migrates to controller)
- Create test: `test/terminal_controller_test.dart` (pure Dart, no Flutter)

- [ ] **Step 1: Write pure-Dart tests** for the controller's `ChangeNotifier` semantics.

Cover: `clearSelection` notifies; `setSelection` notifies; `searchSet` updates `searchHits`+`searchHitIndex` and notifies; `scrollToBottom` does NOT notify if `displayOffset` was already 0 (gating, matches engine semantics); `selectionText` proxies to engine.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/controller/terminal_controller.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';

void main() {
  group('TerminalController + Engine wired', () {
    late TerminalEngine engine;
    late TerminalController controller;
    setUp(() {
      engine = TerminalEngine.fromBinding(_FakeBinding(), config: TerminalConfig.defaults());
      controller = TerminalController()..attach(engine);
    });
    tearDown(() { controller.dispose(); engine.dispose(); });

    test('clearSelection notifies + clears engine selection', () {
      controller.selectionStart(0, 0, false, 0);
      var notifies = 0; controller.addListener(() => notifies++);
      controller.clearSelection();
      expect(notifies, 1);
      expect(controller.selectionActive, isFalse);
    });

    // search/scroll/primary tests follow the same shape.
  });
}
```

- [ ] **Step 2: Run** — expect compile errors (the controller class doesn't exist yet).

- [ ] **Step 3: Implement `lib/controller/terminal_controller.dart`**.

```dart
import 'package:flutter/foundation.dart';
import '../engine/terminal_engine.dart';

class TerminalController extends ChangeNotifier {
  TerminalEngine? _engine;
  TerminalEngine? get engine => _engine;

  void attach(TerminalEngine engine) {
    _engine = engine;
    // No notify — attach is the binding step, not a state change.
  }

  // Selection.
  bool _selectionActive = false;
  bool get selectionActive => _selectionActive;
  String _primary = '';
  String get primary => _primary;

  void selectionStart(int row, int col, bool rightHalf, int kind) {
    _engine?.selectionStart(row, col, rightHalf, kind);
    _selectionActive = true;
    notifyListeners();
  }

  void selectionUpdate(int row, int col, bool rightHalf) {
    _engine?.selectionUpdate(row, col, rightHalf);
    // Drag-update; notify so the painter can refresh via the engine path.
    notifyListeners();
  }

  void clearSelection() {
    if (!_selectionActive) return;
    _engine?.selectionClear();
    _selectionActive = false;
    notifyListeners();
  }

  String? readSelectionText() => _engine?.selectionText();
  void capturePrimary() {
    final t = _engine?.selectionText() ?? '';
    if (t != _primary) { _primary = t; notifyListeners(); }
  }

  // Search.
  String _searchPattern = '';
  bool _searchValid = true;
  String get searchPattern => _searchPattern;
  bool get searchValid => _searchValid;
  bool searchSet(String pattern) {
    _searchPattern = pattern;
    final ok = _engine?.searchSet(pattern) ?? false;
    _searchValid = ok || pattern.isEmpty;
    notifyListeners();
    return ok;
  }
  void searchNext() { _engine?.searchNext(); notifyListeners(); }
  void searchPrev() { _engine?.searchPrev(); notifyListeners(); }
  void searchClear() {
    if (_searchPattern.isEmpty && _searchValid) return;
    _engine?.searchClear();
    _searchPattern = '';
    _searchValid = true;
    notifyListeners();
  }

  // Scroll.
  Future<void> scrollLines(int delta) async {
    await _engine?.scrollLines(delta);
    notifyListeners();
  }
  Future<void> scrollToBottom() async {
    await _engine?.scrollToBottom();
    notifyListeners();
  }
}
```

- [ ] **Step 4: Migrate `TerminalScreen` to use the controller** — every reference to `_selectionActive`, `_primary`, `_searchOpen`/`_searchInvalid`, `_client?.searchSet`, `_client?.binding.selectionClear` etc. now goes through `_controller`. The widget owns the controller instance (`final TerminalController _controller = TerminalController()..attach(_engine)`) for now; in Task 3 the view will accept an optional external controller.

Note: `_searchOpen` (visibility of the search bar) stays on `TerminalScreen` because it's about the UI, not engine state. The controller only tracks pattern + validity.

- [ ] **Step 5: Suite + analyze**

```bash
flutter test 2>&1 | tail -3       # baseline 134 + new controller tests
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(ui): lift selection/search/scroll state into TerminalController

State that was inline in _TerminalScreenState (_selectionActive, _primary,
_searchPattern, _searchValid; plus the corresponding engine-proxy methods)
now lives on TerminalController extends ChangeNotifier. TerminalScreen
constructs one and proxies; consumer-visible behavior unchanged.

New: pure-Dart test/terminal_controller_test.dart pins ChangeNotifier
semantics + gating (clearSelection no-op when inactive).

Spec: docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md §4.2.
"
```

---

## Task 3: Extract `TerminalView` (pure widget + shortcuts/callbacks)

**Goal:** Move render + input + IME out of `TerminalScreen` into `TerminalView`. Drop PTY ownership, title state, restart overlay, search bar UI, file drop, right-click menu, URL launching, and the hardcoded hotkey switch from the view. The hotkeys become `shortcuts: Map<ShortcutActivator, Intent>` with a top-level const default.

**Files:**
- Create: `lib/ui/terminal_view.dart`
- Create: `lib/ui/terminal_shortcuts.dart`
- Create: `lib/theme/terminal_theme.dart`
- Modify: `lib/ui/terminal_screen.dart` (now wraps `TerminalView` with the consumer-side concerns; this is the bridge state that lets us ship the suite green; Task 4 then rewrites it as `example_app.dart`)
- Create test: `test/terminal_view_shortcut_test.dart`
- Create test: `test/terminal_view_callback_test.dart`

This task is the largest. **Recommended split into two sub-commits** if it gets unwieldy:
- 3a: extract `TerminalView` + `terminal_shortcuts.dart`; `TerminalScreen` wraps it.
- 3b: convert hotkeys to Intent/Action so `TerminalView` is fully pure (no inline `_onKey`).

If 3a stays under ~600 lines moved, just do one commit.

- [ ] **Step 1: Move render + IME into `TerminalView`**

Pull these fields/methods out of `_TerminalScreenState` and into a new `_TerminalViewState`:
- Fields: `_fontSize`, `_style`, `_metrics`, `_glyphs`, `_bellCtrl`, `_blinkOn`, `_blinkTimer`, `_focus` (now optional, can come from widget), `_preedit`, `_ime`, `_lastReportedCaretRect`, `_hoverCursor`, `_pressedButton`, `_clickCount`, `_lastClick`, `_selecting`, `_touchScrollAccum`, `_flingTimer`.
- Methods: `_setZoom`, `_flashBell`, `_onPreeditChanged`, `_writeCommittedText` (now writes to `engine.write` not `_pty.write`), `_reportCaretRectToIme`, `_handleImeFocusChange`, `_updateHoverCursor`, `_cellAt`, `_reportMouse`, `_btn`, `_touchScrollBy`, `_stopFling`, `_onTerminalInputStart` (proxies to controller now), `_refreshSelection`.
- `build()`: keep Focus + Listener + GestureDetector + Stack(CustomPaint, blink, bell, preedit). Drop `Scaffold`, `LayoutBuilder`, `DropTarget` (consumer wraps), search bar `Offstage` (consumer mounts), exit-status overlay (consumer mounts).

What stays on `TerminalScreen`'s side after this step:
- PTY lifecycle + restart
- Title `ValueNotifier` injection (still listens to `engine.title`)
- Search bar widget + visibility (`_searchOpen`)
- `DropTarget`
- Right-click context menu
- URL launching
- The bell sound (`SystemSound.play(SystemSoundType.alert)`) actually — alacritty separates audible bell from visual bell. **For 2W keep the bell sound on the view side** (it's a render-time effect tied to the bell overlay animation), but expose `onBell: VoidCallback?` so consumers can override. Document this choice in the findings.

`TerminalView`'s `build` skeleton:

```dart
@override
Widget build(BuildContext context) {
  return Shortcuts(
    shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    child: Actions(
      actions: defaultTerminalActions(controller: _controller, engine: widget.engine),
      child: Focus(
        focusNode: _focus,
        autofocus: widget.autofocus,
        onKeyEvent: _onKey,  // remaining encodeKey logic — see Step 2
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerSignal: _onPointerSignal,
          onPointerPanZoomStart: _onPanZoomStart,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          child: GestureDetector(
            supportedDevices: const {PointerDeviceKind.touch},
            onTap: _onTouchTap,
            onLongPressStart: _onLongPressStart,
            // ... etc ...
            child: Container(
              color: Color(_themeBgWithOpacity()),
              padding: widget.padding,
              child: Stack(children: [
                MouseRegion(/* ... CustomPaint ... */),
                IgnorePointer(/* blink */),
                IgnorePointer(/* bell FadeTransition */),
                if (_preedit != null && _preedit!.isNotEmpty) PreeditOverlay(...),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
}
```

- [ ] **Step 2: Convert hotkeys to Intent / Action via `lib/ui/terminal_shortcuts.dart`**

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';

class CopyIntent extends Intent { const CopyIntent(); }
class PasteIntent extends Intent { const PasteIntent(); }
class ToggleSearchIntent extends Intent { const ToggleSearchIntent(); }
class IncreaseFontSizeIntent extends Intent { const IncreaseFontSizeIntent(); }
class DecreaseFontSizeIntent extends Intent { const DecreaseFontSizeIntent(); }
class ResetFontSizeIntent extends Intent { const ResetFontSizeIntent(); }

const Map<ShortcutActivator, Intent> defaultTerminalShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): CopyIntent(),
  SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): PasteIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): ToggleSearchIntent(),
  SingleActivator(LogicalKeyboardKey.equal, control: true): IncreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): IncreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.minus, control: true): DecreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true): DecreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.digit0, control: true): ResetFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpad0, control: true): ResetFontSizeIntent(),
};

Map<Type, Action<Intent>> defaultTerminalActions({
  required TerminalController controller,
  required TerminalEngine engine,
  required VoidCallback onToggleSearch,
  required ValueSetter<double> onSetZoom,
  required Future<void> Function() onPaste,
  required double baselineFontSize,
  required double currentFontSize,
}) {
  return <Type, Action<Intent>>{
    CopyIntent: CallbackAction<CopyIntent>(onInvoke: (_) {
      final t = engine.selectionText();
      if (t != null && t.isNotEmpty) Clipboard.setData(ClipboardData(text: t));
      return null;
    }),
    PasteIntent: CallbackAction<PasteIntent>(onInvoke: (_) { onPaste(); return null; }),
    ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(onInvoke: (_) { onToggleSearch(); return null; }),
    IncreaseFontSizeIntent: CallbackAction<IncreaseFontSizeIntent>(
        onInvoke: (_) { onSetZoom(currentFontSize + 1.0); return null; }),
    DecreaseFontSizeIntent: CallbackAction<DecreaseFontSizeIntent>(
        onInvoke: (_) { onSetZoom(currentFontSize - 1.0); return null; }),
    ResetFontSizeIntent: CallbackAction<ResetFontSizeIntent>(
        onInvoke: (_) { onSetZoom(baselineFontSize); return null; }),
  };
}
```

Note `onToggleSearch` / `onPaste` / `onSetZoom` are callbacks the **view** provides — these are still actions on the view's local state (search bar visibility, font zoom). The view passes them when building the `Actions` widget. For library consumers who want different paste semantics (e.g. read from a custom clipboard), they pass a custom `actions` map alongside `shortcuts`.

After this step `_onKey` becomes very small: just the IME gate + the `encodeKey` fallback. All hotkey branches are gone.

- [ ] **Step 3: Add `TerminalTheme` + `TerminalStyle`** in `lib/theme/terminal_theme.dart`. Pure data classes — slice from current `TerminalColors` / `BellConfig.color` / `FontConfig`. `TerminalConfig.defaults()` stays the source of truth; `TerminalConfig.theme` / `TerminalConfig.style` getters compose them.

- [ ] **Step 4: Make `TerminalScreen` wrap `TerminalView`** (intermediate state for green tests).

```dart
class _TerminalScreenState extends State<TerminalScreen> {
  late final TerminalEngine _engine = TerminalEngine(...);
  late final TerminalController _controller = TerminalController()..attach(_engine);
  // PTY, restart, search bar, drop, menu, url_launcher all stay here.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ...,
      body: DropTarget(
        onDragDone: _onDrop,
        child: Stack(children: [
          TerminalView(
            _engine,
            controller: _controller,
            theme: _config.theme,
            textStyle: _config.style,
            shortcuts: defaultTerminalShortcuts.cast<ShortcutActivator, Intent>(),
            onTapDown: _onViewTapDown,
            onTapUp: _onViewTapUp,
            onSecondaryTapUp: _onViewSecondaryTapUp,
            onLinkActivate: _onLinkActivate,
          ),
          // Search bar Offstage + status overlay live here.
        ]),
      ),
    );
  }
}
```

- [ ] **Step 5: Adjust existing widget tests** in `terminal_lifecycle_test.dart`. Most tests find `TerminalScreen` and tap it; they should keep working because `TerminalScreen` still renders the same widget tree (just split internally). Tests that reach into private state (`tester.state<State<TerminalScreen>>(...).imeForTest`) need to reach into the View's state instead — change `find.byType(TerminalScreen)` to `find.byType(TerminalView)` and `imeForTest` accessor moves to `TerminalView`'s state.

- [ ] **Step 6: New tests for shortcuts + callbacks**

`test/terminal_view_shortcut_test.dart` — pin three cases:

```dart
testWidgets('default shortcuts: Ctrl+Shift+C copies selection', (tester) async {
  // pumpWidget(MaterialApp(home: TerminalView(engine)));
  // tester.sendKeyEvent for Ctrl+Shift+C; expect Clipboard.setData was called.
});
testWidgets('custom shortcuts override default', (tester) async {
  // Pass {Ctrl+K: PasteIntent()}; expect paste action fired, not the default.
});
testWidgets('empty shortcuts disables all hotkeys', (tester) async {
  // Pass {}; expect Ctrl+Shift+F does NOT toggle search.
});
```

`test/terminal_view_callback_test.dart` — pin:

```dart
testWidgets('onTapUp fires with the CellOffset of the tap', (tester) async {
  TapUpDetails? gotDetails; CellOffset? gotCell;
  // pumpWidget(TerminalView(engine, onTapUp: (d, c) { gotDetails = d; gotCell = c; }));
  // tester.tapAt(cellCenter(2, 3));
  // expect gotCell.row == 2 && gotCell.col == 3.
});
testWidgets('onSecondaryTapUp fires for right-click', (tester) async { /* ... */ });
testWidgets('onLinkActivate fires for Ctrl+left-click on hyperlink', (tester) async { /* ... */ });
```

- [ ] **Step 7: Run the suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -3   # 134 baseline + new view tests
```

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(ui): TerminalView pure widget + shortcuts/callbacks API

TerminalView is the new library-public render widget: required engine,
optional controller/theme/style/padding/focusNode/autofocus + callbacks
(onTapDown/Up, onSecondaryTapDown/Up, onLinkActivate) + shortcuts map.

Hardcoded hotkeys (Ctrl+Shift+C/V/F, Ctrl+=/-/0) moved to top-level const
defaultTerminalShortcuts over Flutter's Shortcuts/Actions framework with
Intent subclasses (CopyIntent, PasteIntent, ToggleSearchIntent,
IncreaseFontSizeIntent, DecreaseFontSizeIntent, ResetFontSizeIntent).

TerminalTheme + TerminalStyle sliced from TerminalConfig as the public
theming surface.

TerminalScreen becomes a transitional wrapper that still owns PTY +
restart overlay + search bar UI + drop + context menu + url_launcher;
Task 4 rewrites it as the example_app.dart consumer reference.

Spec: docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md §4.3.
"
```

---

## Task 4: Rewrite `TerminalScreen` as `example_app.dart` (reference consumer)

**Goal:** Take the transitional wrapper from Task 3 and rename + restructure it into `lib/example/example_app.dart`. Remove `lib/ui/terminal_screen.dart`. Update `lib/main.dart` to use the example app. Update `lib/flutter_alacritty.dart` exports.

**Files:**
- Create: `lib/example/example_app.dart` (copy of post-Task-3 `terminal_screen.dart` with the right name + import paths)
- Delete: `lib/ui/terminal_screen.dart`
- Modify: `lib/main.dart`
- Modify: `lib/flutter_alacritty.dart`
- Adjust: any test that imports `terminal_screen.dart` → `example_app.dart` (preserving test names where possible).

- [ ] **Step 1: Move the file**

```bash
mkdir -p lib/example
git mv lib/ui/terminal_screen.dart lib/example/example_app.dart
```

Inside, rename the class `TerminalScreen` → `ExampleTerminalApp` (or `ExampleApp` — pick consistent naming; the demo's identity should be clear). Update imports accordingly.

- [ ] **Step 2: Update `lib/main.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/config/config_loader.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(ExampleTerminalApp(config: ConfigLoader.load()));
}
```

`MyApp` collapses into `ExampleTerminalApp` which builds its own `MaterialApp` so callers don't need a wrapper.

- [ ] **Step 3: Update `lib/flutter_alacritty.dart`**

```dart
/// Flutter terminal UI backed by an Alacritty-based Rust engine.
library;

export 'config/config_loader.dart';
export 'config/terminal_config.dart';
export 'controller/terminal_controller.dart';
export 'engine/engine_binding.dart';
export 'engine/terminal_engine.dart';
export 'engine/terminal_engine_client.dart' show TerminalEngineClient;  // advanced/internal
export 'pty/pty_backend.dart';
export 'pty/flutter_pty_backend.dart';
export 'theme/terminal_theme.dart';
export 'ui/terminal_shortcuts.dart';
export 'ui/terminal_view.dart';
// REMOVED: ui/terminal_screen.dart (was the god widget)
// example/example_app.dart is NOT exported — it's the reference, not the API.
```

- [ ] **Step 4: Test imports** — `test/terminal_lifecycle_test.dart` (and others) imports `package:flutter_alacritty/ui/terminal_screen.dart`. Either:
  - (a) Update the imports to `example/example_app.dart` and the type references to `ExampleTerminalApp`, or
  - (b) Migrate those tests to directly drive `TerminalView` + a `_FakeBinding`-backed `TerminalEngine` (cleaner; they're library-level tests now).

Prefer (b) for tests that don't actually need the example app's wiring (most of them — search, drag-drop, IME, key gate). The few tests that DO need the wiring (shell exit / restart / spawn failure, drop bracketed-paste end-to-end) become `test/example_app_test.dart` and target the example app.

- [ ] **Step 5: Suite + analyze**

```bash
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(example): rewrite TerminalScreen as example consumer

lib/ui/terminal_screen.dart removed; lib/example/example_app.dart is the
new reference consumer of the public library API (TerminalEngine +
TerminalController + TerminalView). It owns: FlutterPtyBackend lifecycle,
restart overlay, title ValueNotifier wired to engine.title, search bar
widget + visibility, DropTarget (file drop → engine.write(pasteBytes)),
right-click context menu (Copy/Paste/Search), url_launcher invocation
from TerminalView.onLinkActivate.

flutter_alacritty.dart now exports the library API only; example_app
is the consumer reference, not part of the public surface.

Existing widget tests split: TerminalView-level tests stay in
terminal_lifecycle_test.dart (driving TerminalView directly with a
_FakeBinding engine); example-app-level tests (shell exit, drop) move
to example_app_test.dart.

Spec: docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md §4.5.
"
```

---

## Task 5: Library API docs + walkthrough

**Goal:** Document the library surface so a future consumer can wire flutter_alacritty in ~50 lines.

**Files:**
- Create: `docs/library-api.md` — surface walkthrough
- Modify: `README.md` — link to library docs, 30-line consumer snippet

- [ ] **Step 1: Write `docs/library-api.md`** with these sections:
  - **Quick start** — the 30-line snippet a consumer copies (construct engine + controller, build TerminalView, wire PTY in/out, listen to title).
  - **TerminalEngine API** — feed/resize/output/write/title/bell/clipboardStore/hyperlinkAt/dispose, with one-line semantics each.
  - **TerminalController API** — selection/search/scroll groupings.
  - **TerminalView parameters** — table mirroring the spec §4.3.
  - **shortcuts customization** — three patterns (use defaults, override one entry, disable all).
  - **callbacks** — when each fires and the typical handler shape.
  - **Theming** — TerminalTheme + TerminalStyle fields.
  - **Wiring SSH / remote PTY** — short note pointing to 2S as the future expansion.

Aim for ~250 lines of markdown. Keep code snippets minimal — point at `example/example_app.dart` for the full demo.

- [ ] **Step 2: Update `README.md`** — add a "Use as a library" section above the existing "Run the demo" section, with a single fenced code block showing the minimum-viable consumer wiring.

- [ ] **Step 3: Commit**

```bash
git commit -m "docs(library): API surface walkthrough + consumer quick-start

Adds docs/library-api.md covering TerminalEngine / TerminalController /
TerminalView / shortcuts / theming with code snippets and a 30-line
quick-start. README links to it.

Spec: docs/superpowers/specs/2026-05-29-plan2w-library-seam-design.md.
"
```

---

## Task 6: Verification + findings doc + merge readiness

- [ ] **Step 1: Full verification sweep**

```bash
cargo test --manifest-path packages/rust_lib_flutter_alacritty/rust/Cargo.toml 2>&1 | tail -3
flutter analyze lib/ test/ integration_test/ 2>&1 | tail -3
flutter test 2>&1 | tail -3
flutter build linux --debug 2>&1 | tail -3   # optional; only if Rust changed
```

Expected: cargo 29/29 (no Rust changes; should match baseline), analyze zero issues, flutter test 134 baseline + new tests, all green.

- [ ] **Step 2: Manual smoke checklist** (Linux; run the example app)

```bash
flutter run -d linux
```

Verify in the running app:
- Typing ASCII works; latency feels the same as pre-2W (Plan 2L perf fix preserved through controller's `_onTerminalInputStart`).
- Ctrl+Shift+F toggles the search bar (Action wiring works).
- Ctrl+= / Ctrl+- / Ctrl+0 zoom works (callbacks into example app's `_setZoom`).
- Ctrl+Shift+C / V copies/pastes (default Actions hit clipboard).
- IME composition: pinyin → preedit overlay below cursor → commit reaches PTY.
- Right-click → context menu appears (TerminalView.onSecondaryTapUp wired to example_app's `_showContextMenu`).
- Drag a file → bracketed-paste appears (DropTarget → engine.write(pasteBytes)).
- Ctrl+click on a URL launches it (TerminalView.onLinkActivate wired to url_launcher).
- Process exit overlay appears when shell exits; click restarts.

Each line is a checkbox in the findings doc.

- [ ] **Step 3: Write findings doc** — `docs/superpowers/plans/2026-05-29-plan2w-findings.md`. Sections: What shipped (table per task), Spec deviations (anything that diverged from §2 of the spec; if nothing, say "none"), Test counts (before / after), Manual smoke checklist (mark `[x]` after live-running), Deferred / risks (e.g. the `output` stream perf assumption from spec §8.1; the example-app rename if naming chosen differs from the spec).

- [ ] **Step 4: Update the post-v1 roadmap memory** — add commit hash + DONE marker; remove 2W from the recommended pipeline; promote 2N / 2O / 2R per priority.

The roadmap file is at `/home/hhoa/.claude/projects/-home-hhoa-git-hhoa-flutter-alacritty/memory/flutter-alacritty-post-v1-roadmap.md`. Append to the Done section:

```markdown
- **2W library widget seam** (commit <HASH>, 2026-05-29) — split monolithic
  TerminalScreen into TerminalEngine + TerminalController + TerminalView
  three-layer library API. defaultTerminalShortcuts replaces hardcoded
  hotkeys via Flutter Shortcuts/Actions. Old TerminalScreen → example/
  reference consumer. See docs/library-api.md.
```

- [ ] **Step 5: Code review** — invoke `/code-review` (or dispatch superpowers:code-reviewer manually); fix Critical + Important issues; loop until clean.

- [ ] **Step 6: Merge readiness check**

Before fast-forwarding into main:

```bash
# In the main worktree:
cd /home/hhoa/git/hhoa/flutter_alacritty
git status   # expect only the pre-existing pubspec.yaml WIP from main
git log --oneline -1   # confirm main is at the expected base (25b0ebb)
# In the feature worktree:
cd .worktrees/W-library-seam
git log --oneline main..HEAD   # should show 5-6 commits, all task commits
```

Once green: `cd /home/hhoa/git/hhoa/flutter_alacritty && git merge --ff-only feature/W-library-seam`. Then clean up per the standard worktree teardown.

---

## Done criteria for the whole plan

- All 134 baseline widget tests pass.
- New test count: ~10-15 additions across `terminal_engine_test.dart` / `terminal_controller_test.dart` / `terminal_view_shortcut_test.dart` / `terminal_view_callback_test.dart` / `example_app_test.dart`.
- `flutter analyze` clean.
- `lib/flutter_alacritty.dart` exports `TerminalEngine`, `TerminalController`, `TerminalView`, `TerminalTheme`, `TerminalStyle`, `defaultTerminalShortcuts` (+ Intent classes), `defaultTerminalActions`, `PtyBackend`, `FlutterPtyBackend`, `TerminalConfig`, `ConfigLoader`. **No** `TerminalScreen` export.
- `lib/example/example_app.dart` exists and is the reference consumer; `lib/ui/terminal_screen.dart` is gone.
- `docs/library-api.md` exists and covers the public surface.
- Manual smoke (Task 6 Step 2) all `[x]`.
- Findings doc records what shipped + spec deviations + smoke status.
