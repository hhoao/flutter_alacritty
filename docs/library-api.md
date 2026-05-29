# flutter_alacritty library API

This document walks through the public surface a host app uses when embedding
`flutter_alacritty` as a library. The reference consumer
(`ExampleTerminalApp` in `lib/example/example_app.dart`) wires every piece
described below — read this for the shape of the API, read that file for the
full integration example (drag-and-drop, right-click menu, restart overlay,
`url_launcher`).

Everything reachable from `package:flutter_alacritty/flutter_alacritty.dart`
is considered the public surface; anything else is internal.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(); // one-shot native engine bootstrap
  runApp(const MaterialApp(home: TerminalScaffold()));
}

class TerminalScaffold extends StatefulWidget {
  const TerminalScaffold({super.key});
  @override
  State<TerminalScaffold> createState() => _TerminalScaffoldState();
}

class _TerminalScaffoldState extends State<TerminalScaffold> {
  final _config = TerminalConfig.defaults();
  late final _engine = TerminalEngine(config: _config);
  late final _controller = TerminalController()..attach(_engine);
  late final PtyBackend _pty = FlutterPtyBackend(rows: 24, columns: 80);

  late final StreamSubscription _ptyIn = _pty.output.listen(_engine.feed);
  late final StreamSubscription _ptyOut = _engine.output.listen(_pty.write);

  @override
  void dispose() {
    _ptyIn.cancel();
    _ptyOut.cancel();
    _pty.kill();
    _controller.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: _engine.title,
      builder: (_, title, __) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: TerminalView(_engine, controller: _controller),
      ),
    );
  }
}
```

That is the minimum-viable consumer: ~50 lines including imports and lifecycle.
`TerminalView` measures its own cell size and calls `engine.resize` from its
`LayoutBuilder`; the host doesn't need to compute columns/rows.

## TerminalEngine API

Construct with a `TerminalConfig`; everything below is a method or stream on
the resulting handle. Construction is lazy — the native engine boots on the
first `feed` or `resize` call, so cheap to hold in tests or before layout.

| Member | Shape | Semantics |
| --- | --- | --- |
| `TerminalEngine({config, engineFactory?})` | ctor | Build a handle; native engine deferred until first IO. |
| `feed(Uint8List bytes)` | `void` | PTY -> engine. Hot path; called from `pty.output.listen`. |
| `resize({columns, rows})` | `void` | Cell-grid resize. Forward your PTY resize separately. |
| `write(Uint8List bytes)` | `void` | View -> engine (keystrokes, paste, mouse reports). Echoes on `output`. |
| `output` | `Stream<Uint8List>` | Engine -> PTY. Drain into `pty.write` once. |
| `title` | `ValueListenable<String>` | OSC 0/2 title. Mirrors `Event::Title` / `Event::ResetTitle`. |
| `bell` | `Stream<void>` | One event per `Event::Bell`. Hook for custom audio/visual. |
| `clipboardStore` | `Stream<String>` | One event per OSC 52 SET; usually piped to `Clipboard.setData`. |
| `hyperlinkAt(row, col)` | `String?` | URI under the given cell, or null. Used for Ctrl+click and right-click "Open Hyperlink". |
| `repaint` | `Listenable` | Notifies on grid damage; if you write a custom painter, use this in `CustomPaint(repaint: ...)`. |
| `selectionText()` | `String?` | Engine-side selection text (already shaped & rewrapped). |
| `searchSet`, `searchNext`, `searchPrev`, `searchClear` | search proxies | Direct passthroughs; consumers usually go via `TerminalController`. |
| `scrollLines(delta)`, `scrollToBottom()` | `Future<void>` | Viewport scroll. |
| `initializeEmpty(rows, columns)` | `void` | Optional: paints a blank grid before the first damage arrives. |
| `dispose()` | `void` | Closes streams + tears down the native engine. Idempotent. |

The four `on*` binding callbacks (`onPtyWrite`, `onTitle`, `onBell`,
`onClipboard`) are wired internally — consumers see them as the `output` /
`title` / `bell` / `clipboardStore` accessors above.

## TerminalController API

`TerminalController extends ChangeNotifier`. It owns engine-coupled UI state
(selection presence, primary-selection text, current search pattern + its
validity) and notifies the view on every transition. The controller does NOT
own the engine; the host disposes both.

Lifecycle:

```dart
final controller = TerminalController()..attach(engine);
// ...
controller.dispose(); // does not touch engine
engine.dispose();     // separate teardown
```

Groupings:

- **Selection** — `selectionStart(row, col, rightHalf, kind)`,
  `selectionUpdate(row, col, rightHalf)`, `clearSelection()`,
  `readSelectionText()`, `capturePrimary()`. The `primary` getter returns the
  middle-click paste buffer captured at the last selection end. `kind` is
  0=character, 1=word, 2=line (click count - 1).
- **Search** — `searchSet(pattern)` (returns compile success; empty pattern is
  always valid), `searchNext()`, `searchPrev()`, `searchClear()`. The
  notifier-backed `searchPattern` / `searchValid` getters drive the host's
  search-bar UI.
- **Scroll** — `scrollLines(delta)`, `scrollToBottom()` (both
  `Future<void>` so async scrolling sequences are awaitable).

Reading getters: `selectionActive`, `primary`, `searchPattern`, `searchValid`.

## TerminalView parameters

`TerminalView` is a pure render + input widget over a `TerminalEngine`. It
takes the engine as a positional argument and a long list of optional named
parameters:

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `engine` | `TerminalEngine` | required | The handle the view reads/writes. |
| `controller` | `TerminalController?` | `null` (view owns one) | Share a controller across widgets, or let the view create + dispose its own. |
| `theme` | `TerminalTheme` | `TerminalTheme.defaults` | Colors (bg/fg, ANSI, selection, search, hint, bell overlay). |
| `textStyle` | `TerminalStyle` | `TerminalStyle()` | Font family, fallback list, size, line height. |
| `padding` | `EdgeInsets?` | `null` | Inner padding around the cell grid. |
| `backgroundOpacity` | `double` | `1.0` | Reserved for translucent backgrounds. |
| `focusNode` | `FocusNode?` | `null` (view owns one) | Share focus with host widgets (e.g. restart overlay). |
| `autofocus` | `bool` | `true` | Whether to grab focus on mount. |
| `mouseCursor` | `MouseCursor` | `SystemMouseCursors.text` | Hover cursor; the view auto-switches to `click` over hyperlinks. |
| `readOnly` | `bool` | `false` | Drop key events without writing to the engine. |
| `cursorBlinkInterval` | `Duration` | `530 ms` | Half-period of the cursor blink. |
| `bellDuration` | `Duration` | `Duration.zero` | Visual-bell fade duration; zero disables the flash. |
| `doubleClickThreshold` | `Duration` | `300 ms` | Window for word/line selection on multi-click. |
| `scrollMultiplier` | `int` | `3` | Lines per wheel notch when not in mouse-report mode. |
| `preeditBg` / `preeditFg` | `int` | `0x282828` / `0xD8D8D8` | IME preedit overlay colors (packed RGB). |
| `preeditUnderline` | `bool` | `true` | Whether the preedit overlay is underlined. |
| `shortcuts` | `Map<ShortcutActivator, Intent>?` | `null` = `defaultTerminalShortcuts` | Hotkey bindings; see below. |
| `actions` | `Map<Type, Action<Intent>>?` | `null` = `defaultTerminalActions(...)` | Host-supplied actions overlay the view's defaults per intent type. |
| `onTapDown` / `onTapUp` | `void Function(TapDownDetails/TapUpDetails, CellOffset)?` | `null` | Primary-button hooks with cell coordinate. |
| `onSecondaryTapDown` / `onSecondaryTapUp` | `void Function(TapDownDetails/TapUpDetails, CellOffset)?` | `null` | Right-click hooks; the host shows its context menu here. |
| `onLinkActivate` | `void Function(String uri)?` | `null` | Fires on Ctrl+click over a hyperlink; the host launches the URI. |
| `onBell` | `void Function()?` | `null` (plays system alert) | Override the default audible bell. |

## Shortcuts customization

Three patterns, all valid:

```dart
// 1. Use the defaults (Ctrl+Shift+C/V/F, Ctrl+=/-/0).
TerminalView(engine)

// 2. Override one entry; supplied map is the COMPLETE shortcut set
// (the view does not merge with defaults — spread `defaultTerminalShortcuts`
// to keep the rest).
TerminalView(
  engine,
  shortcuts: <ShortcutActivator, Intent>{
    ...defaultTerminalShortcuts,
    const SingleActivator(LogicalKeyboardKey.keyP, control: true):
        const PasteIntent(),
  },
)

// 3. Disable every default — keystrokes hit the encodeKey fallback only.
TerminalView(engine, shortcuts: const <ShortcutActivator, Intent>{})
```

The defaults map (`defaultTerminalShortcuts`) wires:

- `Ctrl+Shift+C` -> `CopyIntent`
- `Ctrl+Shift+V` -> `PasteIntent`
- `Ctrl+Shift+F` -> `ToggleSearchIntent`
- `Ctrl+=` / `Ctrl++` (numpad) -> `IncreaseFontSizeIntent`
- `Ctrl+-` / `Ctrl+-` (numpad) -> `DecreaseFontSizeIntent`
- `Ctrl+0` / `Ctrl+0` (numpad) -> `ResetFontSizeIntent`

The view ships default actions for every intent above (zoom is fully internal;
Copy writes `engine.selectionText()` to the clipboard; Paste reads
`text/plain` and writes it through `pasteBytes` with bracketed-paste +
scrollback-rewind semantics; `ToggleSearchIntent` is a no-op because the view
ships no search bar). Host-supplied `actions` overlay these per-type — pass
just `CopyIntent`, `PasteIntent`, and `ToggleSearchIntent` to keep zoom on the
view but route everything else through your screen-level state.

## Callbacks

Each fires at the documented moment; pass `null` to keep the view's
self-contained default (where one exists).

- `onTapDown(details, cell)` — primary-button press starting a local selection
  (i.e. not in mouse-report mode, or Shift held). The view does the selection
  bookkeeping itself; this is purely an observer hook.
- `onTapUp(details, cell)` — primary-button release at the end of a local
  selection drag.
- `onSecondaryTapDown(details, cell)` / `onSecondaryTapUp(details, cell)` —
  right-click. Typical handler shape:

  ```dart
  onSecondaryTapUp: (details, cell) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx, details.globalPosition.dy, 0, 0),
      items: [/* Copy, Paste, Open Hyperlink, Search... */],
    );
  }
  ```

- `onLinkActivate(uri)` — Ctrl+left-click over a hyperlink cell. Typical
  handler shape (using `package:url_launcher`):

  ```dart
  onLinkActivate: (uri) async {
    if (await launcher.canLaunchUrl(Uri.parse(uri))) {
      await launcher.launchUrl(Uri.parse(uri));
    }
  }
  ```

- `onBell` — fires once per `Event::Bell`. If omitted, the view plays
  `SystemSoundType.alert`; supply this to replace or extend the default.

## Theming

Two pure-data classes own the visual surface.

### `TerminalTheme`

Packed-RGB colors (`0x00RRGGBB`) consumed by the painter. `null` cursor slots
mean "inverse of the cell under the cursor" (alacritty parity).

```dart
class TerminalTheme {
  final int background;             // window background
  final int foreground;             // default fg
  final int selection;              // selection overlay (alpha applied at paint)
  final List<int> ansi;             // length 16: 0..7 normal, 8..15 bright
  final ({int bg, int fg}) searchMatch;   // non-focused search highlight
  final ({int bg, int fg}) searchFocused; // focused search highlight
  final ({int bg, int fg}) hintStart;     // hint-start glyph
  final int? cursorText;            // null = inverse
  final int? cursorColor;           // null = inverse
  final int bellOverlay;            // full-viewport bell flash color
}
```

`TerminalTheme.defaults` is the stock alacritty-like palette.

### `TerminalStyle`

```dart
class TerminalStyle {
  final String family;        // 'monospace' by default
  final List<String> fallback;
  final double size;          // 14.0 by default
  final double lineHeight;    // 1.0 by default
}
```

Both classes have `copyWith` (style only) / `const` constructors for easy
overrides without touching the larger `TerminalConfig`.

If you build a `TerminalConfig` directly, you can also pass it to
`TerminalEngine` and read `config.theme` / `config.style` to feed
`TerminalView`. That is what `ExampleTerminalApp` does.

## Wiring SSH / remote PTY

Implement `PtyBackend` for your transport. The engine doesn't care where bytes
come from — it just needs a `Stream<Uint8List>` in and a `void write(Uint8List)`
out, plus `resize(rows, columns)` and `kill()` for lifecycle. The five-method
interface:

```dart
abstract class PtyBackend {
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  void kill();
}
```

`FlutterPtyBackend` (the v1 implementation) wraps `package:flutter_pty`.
Swapping in an SSH backend means returning bytes from the channel's stdout on
`output` and writing to its stdin on `write` — the engine stays unchanged.
See Plan 2S (TODO) for the upstream SSH/Mosh integration roadmap.

## Reference example

`lib/example/example_app.dart` (`ExampleTerminalApp`) wires every piece
above plus the screen-level surface a real terminal needs:

- Restart overlay on shell exit (`pty.exitCode` -> dimmed banner over the view)
- Search bar visible via `Ctrl+Shift+F`, wired to `TerminalController` search
- File drag-and-drop via `desktop_drop` -> `pasteBytes` -> `engine.write`
- Right-click context menu with Copy / Paste / Open Hyperlink / Search
- `package:url_launcher` for Ctrl+click on hyperlinks
- Title mirroring via `engine.title.addListener` -> external `ValueNotifier`

That file is the canonical reference for "how do I do X in a real host"; the
quick-start above is enough to get a usable terminal on screen.
