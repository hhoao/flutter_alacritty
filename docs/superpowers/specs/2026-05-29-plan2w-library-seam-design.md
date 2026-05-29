# flutter_alacritty Plan 2W — Library Widget Seam

**Date:** 2026-05-29
**Status:** Design pending review
**Branch:** `feature/W-library-seam` (off `main` @ 25b0ebb)

---

## 1. Goal & Non-Goals

**Goal.** Refactor the monolithic `TerminalScreen` into a three-layer public API matching the
xterm.dart shape, so flutter_alacritty becomes embeddable as a library:

- **`TerminalEngine`** — engine handle. Owns engine binding + mirror grid + native lifecycle.
  Consumer feeds bytes in via `feed(Uint8List)`, listens to `output` (bytes the engine wants
  sent to the PTY) and to `title` / `bell` / `clipboardStore` / future events. No PTY, no UI.
- **`TerminalController extends ChangeNotifier`** — selection / search / scroll / pointer-input
  state. Lifted out of `TerminalScreen`'s private fields. Consumer can call `clearSelection()`,
  `searchSet(pattern)`, `scrollToBottom()` etc. from outside the widget.
- **`TerminalView`** — pure widget. Required `engine`; optional `controller`, `theme`,
  `textStyle`, `padding`, `backgroundOpacity`, `focusNode`, `autofocus`. Emits
  `onTapDown(TapDownDetails, CellOffset)`, `onTapUp(...)`, `onSecondaryTapUp(...)`,
  `onLinkActivate(String uri)`. `shortcuts: Map<ShortcutActivator, Intent>` replaces the
  hardcoded `_onKey` switch. **No PTY spawn, no title state, no right-click menu, no clipboard
  reads, no `url_launcher`.**

The current `TerminalScreen` becomes the **example/demo app** that uses the library — a
reference consumer that wires up PTY (`FlutterPtyBackend`), restart overlay, search bar widget,
context menu, file drop, and clipboard. Lives under `example/` (or stays in `lib/main.dart`
for now, but is no longer exported).

**Non-goals (explicitly deferred):**

- **Per-platform PTY backend abstractions** — `PtyBackend` already exists; library doesn't
  pick one. Consumer chooses (`FlutterPtyBackend` on desktop, future SSH/Mosh elsewhere).
- **No API for tabs / multi-engine** — that's 2R. 2W just makes 2R possible by giving each
  tab its own `TerminalEngine` instance.
- **No config schema overhaul** — `TerminalConfig` keeps its current shape; we split it into
  `TerminalTheme` (colors), `TerminalStyle` (font), and engine config. No new keys, just a
  re-grouping. 2O does the real schema work.
- **No keybinding config from TOML** — Plan 2W introduces the `shortcuts` map *programmatically*;
  reading bindings from TOML is 2O-a.
- **`Scrollable` integration** — xterm.dart wraps the view in a `Scrollable` to drive
  scrollback via `ScrollController`. Our engine handles scrollback internally; expose `scroll`
  methods on `TerminalController` and let the consumer choose whether to bolt on a
  `Scrollable`. Defer the Flutter-scroll integration.
- **OSC pump-through fixes** — 2N.
- **Web / WASM** — 2V.

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Library shape | xterm.dart's three-layer (engine + controller + view). Decision driven by [[flutter-alacritty-library-intent]]: keep public seams clean for embedding. |
| `TerminalEngine` API | Wraps `TerminalEngineClient` + `MirrorGrid`. Public surface: `feed(Uint8List)`, `resize(cols, rows)`, `output: Stream<Uint8List>` (engine→host writes the *terminal application* wants to send to the PTY — i.e. the current `EngineEvent::PtyWrite` payload), `title: ValueListenable<String>`, `bell: Stream<void>`, `clipboardStore: Stream<String>`, `grid: Listenable` (read-only view of `MirrorGrid`), `dispose()`. Consumer drives PTY itself: `engine.feed(ptyOutput)` and `pty.write(engine.output)`. |
| `TerminalController` API | `ChangeNotifier`. Selection state (`selection: BufferRange?`, `clearSelection()`, `setSelectionMode(mode)`); search (`searchSet(pattern)`, `searchNext/Prev`, `searchClear`); scroll (`scrollLines(delta)`, `scrollToBottom()`, `displayOffset: int`). Constructor is parameterless; engine is set when the View binds them together. |
| `TerminalView` shape | `StatefulWidget`. Required: `engine`. Optional: `controller` (created internally if null), `theme`, `textStyle`, `padding`, `backgroundOpacity`, `focusNode`, `autofocus`, `mouseCursor`, `cursorBlinking`, `readOnly`, `shortcuts`, `onTapDown/Up`, `onSecondaryTapDown/Up`, `onLinkActivate`. NOT included: title, PTY, restart, exit overlay, file drop, search bar widget, context menu, url_launcher, clipboard reads. |
| `TerminalTheme` | Subset of current `TerminalColors` + `BellConfig.color`. Pure data class. Lives in `lib/theme/terminal_theme.dart`. |
| `TerminalStyle` | `{ family, fallback, size, lineHeight, bold?, italic?, boldItalic? }` — the font portion of current `FontConfig`. Bold/italic fields land as `null` (use synthesis) for 2W; populated by 2O-b. |
| `shortcuts: Map<ShortcutActivator, Intent>` | Flutter's standard `Shortcuts`/`Actions` framework. Library ships a default `defaultTerminalShortcuts` map covering Ctrl+Shift+C/V/F/Ctrl+= etc. Consumer can pass `{}` (disable defaults) or override individual entries. `Intent` subclasses: `CopyIntent`, `PasteIntent`, `ToggleSearchIntent`, `IncreaseFontSizeIntent`, `DecreaseFontSizeIntent`, `ResetFontSizeIntent`. Each maps to a `TerminalAction` (an `Action<Intent>`) that calls into `controller` / `engine`. |
| Callbacks vs widget-owned UI | Match xterm.dart: View emits raw callbacks (`onTapUp(details, cellOffset)`) and the consumer decides what to do. **Right-click menu, link launching, file drop, search bar widget** all move to the example app. View only stays in charge of: cursor positioning, IME, selection drag, scroll wheel, blink, glyph cache, painter. |
| `IME / PreeditOverlay` | Stays inside `TerminalView`. IME is a property of the rendering surface, not a consumer concern. The `[ime]` config moves to `TerminalView.imeStyle` (PreeditStyle data class). |
| Title | Moves OUT of the widget. Consumer subscribes to `engine.title` and updates a `MaterialApp` title or a custom title bar. The current `widget.title: ValueNotifier<String>` injection pattern is replaced. |
| PTY | OUT. Consumer constructs `TerminalEngine` and a `PtyBackend` separately, pipes them with a 4-line `StreamSubscription`. The `PtyFactory` / `EngineFactory` typedefs become **engine-only** (`EngineFactory`) and are used by `TerminalEngine.test(...)` constructor for unit tests; consumer's normal path is direct `TerminalEngine(...)`. |
| Backwards compatibility | None promised for `TerminalScreen` — it's removed from the public export. The library exports change wholesale: `flutter_alacritty.dart` exports `TerminalEngine`, `TerminalController`, `TerminalView`, `TerminalTheme`, `TerminalStyle`, plus the existing `PtyBackend` / `FlutterPtyBackend` / `TerminalConfig` / config loader (since the example app needs them). Current main.dart is rewritten as the reference consumer. |
| Testing strategy | Three layers, three test groups: pure-Dart `TerminalController` tests (no Flutter, no native), `TerminalEngine` tests using the existing `_FakeBinding` (no widget tree), `TerminalView` widget tests via `pumpWidget`. Engine + Controller can be tested in isolation; widget tests can mock the engine. |

## 3. Architecture & data flow

### Today (monolithic)

```
TerminalScreen (StatefulWidget)
  ├── owns: TerminalConfig, TerminalEngineClient, MirrorGrid, FlutterPtyBackend,
  │         GlyphCache, FocusNode, AnimationController(bellCtrl),
  │         ImeSession, search state, hover cursor, selection state, _primary,
  │         status (running/exited/error), exitCode, errorMessage
  ├── builds: Scaffold → LayoutBuilder → Focus → DropTarget → Listener → GestureDetector
  │            → Stack(CustomPaint, blink overlay, search bar, bell, preedit)
  ├── handles in `_onKey`: Ctrl+Shift+F (search), Ctrl+=/-, Ctrl+0 (zoom),
  │                        Ctrl+Shift+C/V (copy/paste), arrow/text keys
  ├── handles in `onPointerDown`: Ctrl+click (URL launch), middle-click paste,
  │                                right-click (context menu), selection start
  └── handles `_onDrop`: shell-quote paths + bracketed-paste write
```

### After 2W (three-layer)

```
Library (flutter_alacritty/lib)
  TerminalEngine
    ├── owns: TerminalEngineClient + MirrorGrid + EngineBinding
    └── API:  feed/resize/output/title/bell/clipboardStore/grid/dispose

  TerminalController extends ChangeNotifier
    ├── owns: selection {base, extent, mode}, search {pattern, hits, activeIdx},
    │         displayOffset, hover state, _selectionActive bool, _primary
    └── API:  clear/setSelection, search*, scroll*, copySelection, ...

  TerminalView (StatefulWidget)
    ├── owns: GlyphCache (font-derived), bell AnimationController,
    │         blink timer, FocusNode (if not externally provided),
    │         ImeSession, PreeditOverlay, hover MouseCursor, post-frame caret IPC
    ├── builds: Focus → Listener → GestureDetector
    │            → Stack(CustomPaint, blink overlay, bell, preedit)
    ├── shortcuts: Map<ShortcutActivator, Intent> + Actions(actions: …)
    └── callbacks: onTapUp/Down, onSecondaryTapUp/Down, onLinkActivate

Example app (was lib/ui/terminal_screen.dart; becomes example/ or stays as
demo main.dart)
  AppScreen
    ├── creates: TerminalEngine, TerminalController, FlutterPtyBackend
    ├── pipes:   pty.output → engine.feed; engine.output → pty.write
    ├── wraps:   DropTarget (file drop → engine.feed(pasteBytes(...)))
    ├── owns:    title bar (listens engine.title), restart overlay, search bar widget
    ├── on TerminalView.onTapUp:        if Ctrl → openLink(url at cell)
    ├── on TerminalView.onSecondaryTapUp: showContextMenu (Copy/Paste/Search)
    └── on TerminalView.onLinkActivate:  url_launcher.launchUrl(uri)
```

Data flow for a single ASCII keystroke (illustrates the seam):

```
Key 'a' pressed
  → TerminalView's Focus.onKeyEvent
  → Shortcuts/Actions resolves: no match → falls through
  → TerminalView._encodeKeyToBytes('a', mods, modeFlags)
  → TerminalController._onTerminalInputStart()  (gated clear+scroll)
  → engine.feed-or-equivalent? NO — bytes go to the consumer:
      TerminalView calls onInputBytes?.call(bytes)
      OR
      TerminalView writes to a `engine.input: Sink<Uint8List>` that the
      consumer drains into the PTY.

PTY echoes 'a' back
  → consumer: pty.output stream
  → consumer: engine.feed(bytes)
  → engine: _drain → advanceAndTakeDamage → MirrorGrid.apply → notifyListeners
  → TerminalView CustomPaint repaints (already wired via `repaint: engine.grid`)
```

**Critical decision pending:** how do PTY-bound bytes (typing, paste, mouse reports)
leave the view? Two options:

- **Option A — View has an `input: Sink<Uint8List>` parameter.** Consumer wires it to PTY:
  `TerminalView(engine: e, input: pty)`. Clean unidirectional flow but adds a parameter.
- **Option B — Bytes flow through the engine.** `engine.write(bytes)` is added, and a
  separate `engine.output` stream emits everything that should reach the PTY (both
  app-generated PtyWrite events and view-generated key bytes). Single sink for the consumer.

Recommend **Option B** — matches xterm.dart (`terminal.keyInput(...)` writes through the
terminal object; consumer only sees one output stream). Also simplifies the seam: the View
only ever talks to the Engine, never directly to the consumer's PTY.

## 4. Components

### 4.1 `lib/engine/terminal_engine.dart` (NEW)

```dart
class TerminalEngine {
  TerminalEngine({
    required TerminalConfig config,
    EngineFactory? engineFactory,
  });

  /// PTY → engine: app output bytes that should advance the parser.
  void feed(Uint8List bytes);

  /// Cell-grid resize (e.g. after a layout pass).
  void resize({required int columns, required int rows});

  /// Engine → PTY: every byte the engine wants to send to the underlying
  /// program. Includes app-generated escape replies (Event::PtyWrite) AND
  /// view-generated key bytes (after they're posted via [write]).
  Stream<Uint8List> get output;

  /// View → engine: bytes generated by user input (key, paste, mouse report).
  /// They appear on [output] after a one-tick coalesce.
  void write(Uint8List bytes);

  ValueListenable<String> get title;
  Stream<void> get bell;
  Stream<String> get clipboardStore;
  // Future (2N): Stream<ColorChange>, Stream<int /* requested color idx */>...

  /// Read-only mirror grid for the painter. Same MirrorGrid we have today;
  /// `Listenable` instead of typed exposure so consumers can't mutate it.
  Listenable get repaint;
  MirrorGridSnapshot snapshot();   // immutable view for tests / debugging

  void dispose();
}
```

### 4.2 `lib/controller/terminal_controller.dart` (NEW)

```dart
class TerminalController extends ChangeNotifier {
  TerminalController();

  // Bound by TerminalView; package-private setter.
  TerminalEngine? get engine => _engine;

  BufferRange? get selection;
  SelectionMode get selectionMode;
  void clearSelection();
  void setSelection({required CellOffset begin, required CellOffset end, SelectionMode mode});

  // Search.
  bool searchSet(String pattern);
  bool searchNext();
  bool searchPrev();
  void searchClear();
  int get searchHitIndex;
  List<TerminalSearchHit> get searchHits;

  // Scroll.
  int get displayOffset;
  void scrollLines(int delta);
  void scrollToBottom();
}
```

### 4.3 `lib/ui/terminal_view.dart` (NEW)

```dart
class TerminalView extends StatefulWidget {
  const TerminalView(
    this.engine, {
    super.key,
    this.controller,
    this.theme = TerminalTheme.defaults,
    this.textStyle = const TerminalStyle(),
    this.padding,
    this.backgroundOpacity = 1.0,
    this.focusNode,
    this.autofocus = true,
    this.mouseCursor = SystemMouseCursors.text,
    this.readOnly = false,
    this.shortcuts,                    // null = defaults; {} = none
    this.imeStyle = const PreeditStyle(),
    this.onTapDown,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onLinkActivate,
  });

  final TerminalEngine engine;
  final TerminalController? controller;
  final TerminalTheme theme;
  final TerminalStyle textStyle;
  final EdgeInsets? padding;
  final double backgroundOpacity;
  final FocusNode? focusNode;
  final bool autofocus;
  final MouseCursor mouseCursor;
  final bool readOnly;
  final Map<ShortcutActivator, Intent>? shortcuts;
  final PreeditStyle imeStyle;
  final void Function(TapDownDetails, CellOffset)? onTapDown;
  final void Function(TapUpDetails, CellOffset)? onTapUp;
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;
  final void Function(String uri)? onLinkActivate;
}
```

### 4.4 `lib/theme/terminal_theme.dart` (NEW)

```dart
class TerminalTheme {
  const TerminalTheme({
    required this.background,
    required this.foreground,
    required this.selection,
    required this.ansi,             // length 16
    required this.searchMatch,      // (bg, fg)
    required this.searchFocused,    // (bg, fg)
    required this.hintStart,        // (bg, fg)
    required this.cursorText,       // null = inverse
    required this.cursorColor,      // null = inverse
    required this.bellOverlay,
  });
  static const TerminalTheme defaults = TerminalTheme(/* alacritty defaults */);
}
```

### 4.5 `lib/example/example_app.dart` (NEW; old `lib/ui/terminal_screen.dart` rewritten)

The reference consumer. Owns:

- `FlutterPtyBackend` lifecycle + restart logic + status overlay
- Title `ValueNotifier<String>` ← `engine.title` listener
- File drop wrapper (`DropTarget` around `TerminalView`)
- Search bar widget (controller-driven; the search-bar UI itself is example-app code, not library)
- Right-click context menu (called from `TerminalView.onSecondaryTapUp`)
- URL launching (`onLinkActivate: (uri) => url_launcher.launchUrl(Uri.parse(uri))`)
- Clipboard writes for `engine.clipboardStore` (was in `FrbEngineBinding.onClipboard`)

This file is what new consumers will copy-paste as a starting point.

## 5. Migration plan (incremental commits)

Five small commits, each independently shipping the codebase in a working state:

| # | Commit | Touches | Test status |
|---|---|---|---|
| 1 | `refactor(engine): extract TerminalEngine handle (wraps existing client+grid+binding)` | `lib/engine/terminal_engine.dart` new; `terminal_screen.dart` migrated to use it | all green |
| 2 | `refactor(ui): lift selection/search/scroll state into TerminalController` | new `lib/controller/`; `terminal_screen.dart` reads/writes via controller | all green |
| 3 | `feat(ui): TerminalView pure widget; shortcuts + callbacks API` | new `lib/ui/terminal_view.dart`; old `terminal_screen.dart` becomes a wrapper using TerminalView internally | all green (existing widget tests still pass against the wrapper) |
| 4 | `refactor(example): rewrite TerminalScreen as example consumer of TerminalView` | `lib/ui/terminal_screen.dart` → `lib/example/example_app.dart`; lib/main.dart updated; `flutter_alacritty.dart` exports change | adjusted widget tests; example app tests added |
| 5 | `docs(library): API surface notes + example consumer walkthrough` | README + `docs/library-api.md` | n/a |

After commit 3, the library is usable; after commit 4, the demo app is the reference. We can
stop after commit 3 if the demo can stay shaped as a wrapper for one release.

## 6. Risks & known unknowns

| Risk | Mitigation |
|---|---|
| `TerminalScreen`'s 894 lines have intricate ordering invariants (post-frame callbacks, focus-listener ordering, selection-grid sync). Splitting risks regressing them. | Move code, don't rewrite. Each commit reorganizes only — no behavioral diffs. Existing widget tests (134 of them) act as the regression net; new tests are added but old tests are preserved. |
| `shortcuts` map needs `Action<Intent>` plumbing that's verbose. | Provide `defaultTerminalShortcuts` + `defaultTerminalActions(controller, engine)` factories. Consumer can pass either, override individual entries, or pass `{}` to disable. |
| `engine.output` mixes app-PtyWrite and view-generated key bytes. A misbehaving consumer that loops `output` back into `feed` would echo their own typing. | Document. The contract is "drain `output` into PTY". Sample example code shows the correct one-line wire-up. |
| URL hit-testing (Ctrl+click on hyperlink) needs `MirrorGrid` access — but the consumer's `onTapUp` only gets a `CellOffset`. | Add `TerminalEngine.hyperlinkAt(row, col): String?` helper. Consumer queries the engine before launching. The example app shows this. |
| Title `ValueNotifier` injection pattern was hot-path (kept `TerminalScreen` stable across title rebuilds). Moving title to the example app must preserve that. | Example app wraps `MaterialApp.title` with `ValueListenableBuilder` like today but listens to `engine.title` directly. `TerminalView` never rebuilds on title change. |
| `ImeSession`'s lifecycle was tied to `_TerminalScreenState`'s focus listener. Moving to `TerminalView` should preserve the "register in initState, eager call" fix from Plan 2L review. | The 2L fix (focus listener in initState) gets carried into `_TerminalViewState.initState`. Findings doc cross-references this. |
| `_onTerminalInputStart()` (Plan 2L perf fix) gates `selectionClear + scrollToBottom`. Selection state was on TerminalScreen (`_selectionActive`); now it's on TerminalController. The gate needs controller access. | The View's input pipeline calls `controller._onTerminalInputStart()` (package-private). Engine ops (selectionClear, scrollToBottom) flow through the engine. Tests pin the same call counts. |

## 7. Test coverage targets

| Layer | Existing tests | New tests in 2W |
|---|---|---|
| Engine | `engine_bindings_test.dart`, hyperlink tests, etc. | `terminal_engine_test.dart` — pin `feed → output` round-trip, `engine.title` ValueListenable, `engine.write` flowing to `engine.output`, `engine.hyperlinkAt` |
| Controller | none (state was inside Widget) | `terminal_controller_test.dart` — selection invariants, search hits, scroll, ChangeNotifier semantics; pure Dart, no Flutter |
| View | `terminal_lifecycle_test.dart` (the 134 widget tests) | All 134 must pass. Add `terminal_view_shortcut_test.dart` for the `shortcuts` map (default + override + disabled), `terminal_view_callback_test.dart` for `onTapUp` / `onLinkActivate` callbacks firing correctly |
| Example app | none | `example_app_test.dart` — PTY restart overlay, search bar wiring, drop → engine.feed |

## 8. Resolved open questions (was: open for review; locked 2026-05-29)

1. **Engine `output` stream type → `Stream<Uint8List>` (broadcast), with `dart:async` coalesce.**
   - Reasoning: matches xterm.dart's `Terminal.output` shape. Keystroke latency on this path
     today is dominated by FFI snapshots, not by stream dispatch. If a profiler later flags
     stream overhead, swap for a custom `Sink<Uint8List>` without touching the public surface
     (consumer code keeps reading `engine.output.listen(pty.write)`).
   - Implementation note: bytes posted via `engine.write(bytes)` and bytes from
     `EngineEvent::PtyWrite` both flow through a single internal `StreamController.broadcast()`
     so the consumer sees one ordered stream.

2. **`TerminalController` is OPTIONAL** (xterm.dart style). `TerminalView` creates one
   internally if `controller` is null and owns its disposal. The internal one is
   accessible via `TerminalView.of(context).controller` (an `InheritedWidget` like
   `Scaffold.of`) for child widgets that need it (search bar, etc.). Consumers who want to
   drive selection from outside pass their own.

3. **`TerminalEngine` constructor takes `EngineFactory` (with a default to `FrbEngineBinding`)**,
   plus an `@visibleForTesting TerminalEngine.fromBinding(EngineBinding)` escape hatch for
   widget tests that already use a `_FakeBinding`. Two ctors, one public ergonomic + one
   test-only — matches the `PtyFactory? ptyFactory` / `EngineFactory? engineFactory` pattern
   from current `TerminalScreen`.

4. **`defaultTerminalShortcuts` ships as a top-level `const` map** in
   `lib/ui/terminal_shortcuts.dart`, alongside the `Intent` subclasses and a
   `defaultTerminalActions(controller, engine)` factory. Top-level const is the Flutter
   idiom (e.g. `WidgetsApp.defaultShortcuts`) and lets `TerminalView`'s default param
   express "use this map" without invoking a getter.

Plan doc: `docs/superpowers/plans/2026-05-29-plan2w-library-seam.md`.
