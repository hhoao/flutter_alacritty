# flutter_alacritty library API

This document walks through the public surface a host app uses when embedding
`flutter_alacritty` as a library. The reference consumer
(`ExampleTerminalApp` in `lib/example/example_app.dart`) wires every piece
described below — read this for the shape of the API, read that file for the
full integration example (drag-and-drop, right-click menu, restart overlay,
`url_launcher`).

Everything reachable from `package:flutter_alacritty/flutter_alacritty.dart`
is considered the public surface; anything else is internal.

## Library vs host

The library owns VT correctness, rendering, input, and opt-in composables.
The host owns app chrome, window management, and policy overrides.

| Capability | Library | Host |
|------------|:-------:|:----:|
| VT / damage / GPU atlas / scrollback | ✓ | |
| Selection, search engine, OSC 52 | ✓ | |
| Search **bar** UI | composable | may replace |
| Copy as HTML / write contents | API (+ helper) | menu wiring |
| Bell | `engine.bell` + `TerminalView` default `SystemSound` / `onBell` override; visual via `bellDuration` | custom audio / mute policy |
| OSC 8 + link providers | ✓ | open URL / context menu |
| Semantics / a11y tree | ✓ | platform AT bridge quirks |
| Vi mode / hints (later) | ✓ (opt-in) | keybinding chrome |
| SSH **backend** reference (later) | optional `PtyBackend` impl | SSH UI / auth |
| Tabs, profiles, confirm-close | | ✓ |
| Fullscreen / multi-window | | ✓ |

## Bell defaults

Bell behavior is locked to the current `TerminalView` defaults (not a breaking
change):

- When `onBell == null`, the view plays `SystemSoundType.alert` on each
  `engine.bell` event.
- Visual flash runs only when `bellDuration > Duration.zero` (default
  `Duration.zero` disables the overlay).
- Pass `onBell` to replace or mute the audible bell; adjust `bellDuration` and
  `theme.bellOverlay` (from `TerminalConfig.bell.color`) for visual policy.

## Config knobs (accepted vs wired)

Some alacritty-style TOML keys parse into `TerminalConfig` but are host-only or
not yet wired to paint/runtime. After loading config, call
`TerminalConfig.warnInertOrHostOnlyKeys()` and log each string (the example app
does this via `debugPrint`).

| Key | Status |
| --- | --- |
| `font.offset` / `font.glyph_offset` | Wired — offset grows cell size; glyph_offset shifts glyph paint origin |
| `window.opacity` | Host-only — apply to the native window (not `TerminalView.backgroundOpacity`) |
| `window.decorations` | Host-only — library does not change window chrome |
| `bell.animation` | Linear-only — other values are accepted but ignored at render time |

## Quick start

```dart
import 'dart:async';
import 'dart:typed_data';

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
  PtyBackend? _pty;

  StreamSubscription<Uint8List>? _ptyIn;
  StreamSubscription<Uint8List>? _ptyOut;

  void _onPtyResize(int cols, int rows) {
    if (_pty == null) {
      _pty = FlutterPtyBackend(rows: rows, columns: cols);
      _ptyIn = _pty!.output.listen(_engine.feed);
      _ptyOut = _engine.output.listen(_pty!.write);
    } else {
      _pty!.resize(rows, cols);
    }
  }

  @override
  void dispose() {
    _ptyIn?.cancel();
    _ptyOut?.cancel();
    _pty?.kill();
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
        body: TerminalView(
          _engine,
          controller: _controller,
          onPtyResize: _onPtyResize,
        ),
      ),
    );
  }
}
```

That is the minimum-viable consumer: ~50 lines including imports and lifecycle.
`TerminalView` measures its cell size on each layout pass, synchronously resizes
the engine and mirror via an internal `TerminalViewportController`, then fires
`onPtyResize` so the host can SIGWINCH the PTY **after** the engine grid
matches — the host does not compute columns/rows or call `engine.resize`
separately.

## Viewport model (`TerminalViewport`)

Resize is owned by a single viewport tuple (Alacritty `SizeInfo` analogue):

| Type | Role |
| --- | --- |
| `TerminalViewport` | Committed pixel layout: `columns`×`screenLines`, `cellWidth`/`cellHeight`, letterbox `paddingX`/`paddingY`, `cellRect`, `ptyWindowSize`. |
| `ViewportResolver` | Maps a `ViewportQuery` (available size + `CellMetrics`) to a `TerminalViewport`. Always returns a usable grid; fractional pixels become centered padding. |
| `TerminalViewportController` | Called from `TerminalView`'s `LayoutBuilder` on every layout; resizes engine+mirror synchronously; defers PTY SIGWINCH by one frame unless held. |

Hosts that animate chrome (sidebar) and want to avoid SIGWINCH spam bracket the
animation with `beginPtyHold` / `endPtyHold` on `TerminalViewState` (reach via
`GlobalKey<TerminalViewState>`):

```dart
final _terminalKey = GlobalKey<TerminalViewState>();

// ...
_terminalKey.currentState?.beginPtyHold();
// animate sidebar …
_terminalKey.currentState?.endPtyHold(); // flushes one SIGWINCH if grid changed
```

## TerminalEngine API

Construct with a `TerminalConfig`; everything below is a method or stream on
the resulting handle. Construction is lazy — the native engine boots on the
first `feed` or `resize` call, so cheap to hold in tests or before layout.

| Member | Shape | Semantics |
| --- | --- | --- |
| `TerminalEngine({config, engineFactory?})` | ctor | Build a handle; native engine deferred until first IO. |
| `feed(Uint8List bytes)` | `void` | PTY -> engine. Hot path; called from `pty.output.listen`. |
| `resize({columns, rows})` | `void` | Cell-grid resize. Does **not** resize the PTY — use `onPtyResize` on `TerminalView` or set `engine.onPtyResize` so SIGWINCH follows the engine grid. |
| `onPtyResize` | `void Function(int columns, int rows)?` | Optional hook invoked by the client **after** a pending resize flush completes (engine grid already updated). `TerminalView` wires its `onPtyResize` constructor arg here automatically. |
| `write(Uint8List bytes)` | `void` | View -> engine (keystrokes, paste, mouse reports). Echoes on `output`. |
| `output` | `Stream<Uint8List>` | Engine -> PTY. Drain into `pty.write` once. |
| `title` | `ValueListenable<String>` | OSC 0/2 title. Mirrors `Event::Title` / `Event::ResetTitle`. |
| `bell` | `Stream<void>` | One event per `Event::Bell`. Hook for custom audio/visual. |
| `clipboardStore` | `Stream<String>` | One event per OSC 52 SET; usually piped to `Clipboard.setData`. |
| `hyperlinkAt(row, col)` | `String?` | URI under the given cell, or null. Used for Ctrl+click and right-click "Open Hyperlink". |
| `repaint` | `Listenable` | Notifies on grid damage; if you write a custom painter, use this in `CustomPaint(repaint: ...)`. |
| `grid` | `TerminalGridView` | Read-only mirror: cells, cursor, `displayOffset`, `scrollFraction`, `historySize` (live scrollback lines above the viewport = `total_lines − screen_lines`), `modeFlags`. |
| `selectionText()` | `String?` | Engine-side selection text (already shaped & rewrapped). |
| `searchSet`, `searchNext`, `searchPrev`, `searchClear` | search proxies | Direct passthroughs; consumers usually go via `TerminalController`. |
| `scrollLines(delta)`, `scrollPixels(deltaPx)`, `scrollToBottom()`, `scrollToTop()`, `scrollToOffset(lines)` | `Future<void>` | Viewport scroll. `scrollToOffset` sets an absolute GtkAdjustment-style position (`0` = live bottom, `historySize` = top). Wheel/pan/fling gestures route through the internal `TerminalScrollController` (`scrollLines` / `scrollPixels`); absolute scroll (`scrollTo*`) cancels pending gesture scroll first. |
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
- **Search** — `searchSet(pattern, {options})` (returns compile success; empty
  pattern is always valid), `searchNext()`, `searchPrev()`, `searchClear()`.
  Pass `TerminalSearchOptions` (case / whole-word / regex / wrap; defaults
  match the engine) to recompile with flags. The notifier-backed
  `searchPattern` / `searchValid` / `searchOptions` getters drive the host's
  search-bar UI. `TerminalSearchBar` is an **opt-in composable** (exported from
  the library barrel); hosts may ignore it and drive the controller only.
- **Scroll** — `scrollLines(delta)`, `scrollToBottom()`, `scrollToTop()`,
  `scrollToOffset(lines)` (all `Future<void>`). Absolute edge hops cancel any
  coalesced wheel/pan accumulators so scrollbar / ScrollTo* gestures are not
  undone on the next frame.

Reading getters: `selectionActive`, `primary`, `searchPattern`, `searchValid`,
`searchOptions`.

## TerminalView parameters

`TerminalView` is a pure render + input widget over a `TerminalEngine`. It
takes the engine as a positional argument and a long list of optional named
parameters:

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `engine` | `TerminalEngine` | required | The handle the view reads/writes. |
| `controller` | `TerminalController?` | `null` (view owns one) | Share a controller across widgets, or let the view create + dispose its own. |
| `theme` | `TerminalTheme` | `TerminalTheme.defaults` | Colors (bg/fg, ANSI, selection, search, hint, bell overlay). |
| `textStyle` | `TerminalStyle` | `TerminalStyle()` | Font family, fallback, size, line height, offset, glyph_offset. |
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
| `linkProviders` | `List<TerminalLinkProvider>` | `const []` | Host-injectable regex/path link sources; pass `[UrlLinkProvider()]` for URLs. OSC 8 needs no provider. |
| `primaryTapActivatesLink` | `bool` | `false` | Plain left-click also fires `onLinkActivate` on link cells (Shift still selects). |
| `onBell` | `void Function()?` | `null` (plays system alert) | Override the default audible bell. |
| `onPtyResize` | `void Function(int columns, int rows)?` | `null` | Fires after the view commits an engine resize; resize your PTY here (lazy spawn on first callback). Replaces the removed `onViewportResize`. |

**Breaking change (resize API):** `onViewportResize`, `TerminalResizeController`,
and `StableFrameCommitPolicy` were removed. Resize policy now lives inside
`TerminalView` via `TerminalViewportController`; hosts only implement
`onPtyResize` (or `engine.onPtyResize` for headless wiring). Use
`beginPtyHold` / `endPtyHold` on `TerminalViewState` to suppress PTY SIGWINCH
during chrome animation.

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
- `onPtyResize(columns, rows)` — fires after the view's internal
  `TerminalViewportController` commits `engine.resize`. Typical handler:

  ```dart
  onPtyResize: (cols, rows) {
    _pty ??= FlutterPtyBackend(rows: rows, columns: cols);
    _pty!.resize(rows, cols);
  },
  ```

  Do **not** call `engine.resize` from the host for viewport changes — the view
  owns measurement. PTY SIGWINCH trails the engine grid (deferred one frame
  during layout; suppressed entirely while `beginPtyHold` is active).

## Link providers

Beyond OSC 8 hyperlinks (which the engine tracks and exposes via
`engine.hyperlinkAt`), the view supports **host-injectable link providers** that
detect clickable spans in rendered text. `onLinkActivate` fires for both: an OSC 8
cell yields its URI; a provider span yields the provider's `payload`.

```dart
abstract class TerminalLinkProvider extends ChangeNotifier {
  Iterable<LinkSpan> scan(String lineText);   // sync candidate detection per line
  bool isEnabled(LinkSpan span);              // sync gate: draw/clickable now?
}
class LinkSpan { final int start, end; final String payload; } // half-open [start,end)
```

The view, on each (debounced ~120 ms) grid change AND on any provider
`notifyListeners`, scans every visible line through each provider, decorates the
cells of **enabled** spans like a hyperlink (hint underline + click cursor), and
on Ctrl/Cmd+click hands the covering span's `payload` to `onLinkActivate`.

The library is IO-free: providers do their own work and call `notifyListeners`
when their enabled-set changes. A provider that validates asynchronously (e.g. a
filesystem check) returns `isEnabled == false` until confirmed, then notifies; the
view re-decorates on the next debounced pass.

```dart
TerminalView(
  engine,
  // Default is const [] (no regex link scan). Pass [UrlLinkProvider()] for URLs.
  linkProviders: [UrlLinkProvider(), MyFilePathProvider(...)],
  onLinkActivate: (payload) => openItSomehow(payload),
)
```

`UrlLinkProvider` (shipped, always enabled) detects `https?|ftp|file://…`. The host
owns provider lifecycle — the view adds/removes its own listener but never disposes
a provider. For live working-directory tracking, the engine exposes
`engine.workingDir` (`ValueListenable<String>`, the raw OSC 7 `file://host/path`);
a host can parse it to a local path and feed it to a path provider so relative
links re-resolve after `cd` inside the shell.

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
  final double offsetX;       // font.offset — grows cell size
  final double offsetY;
  final double glyphOffsetX;  // font.glyph_offset — shifts glyph paint origin
  final double glyphOffsetY;
}
```

Both classes have `copyWith` (style only) / `const` constructors for easy
overrides without touching the larger `TerminalConfig`.

If you build a `TerminalConfig` directly, you can also pass it to
`TerminalEngine` and read `config.theme` / `config.style` to feed
`TerminalView`. That is what `ExampleTerminalApp` does.

## Shell spawn (`FlutterPtyBackend`)

`FlutterPtyBackend` is the local-PTY implementation of `PtyBackend`. The
public control surface is [`ShellConfig`](lib/config/terminal_config.dart)
(on [`TerminalConfig.shell`](lib/config/terminal_config.dart) or in TOML under
`[shell]`):

| Field | Role |
| --- | --- |
| `program` | Shell binary; `null` → platform default (`$SHELL`, `/bin/bash`, `/system/bin/sh`, …) |
| `args` | argv after the program name |
| `working_directory` | Spawn cwd; `~` / `~/…` expand against `HOME`; `null` → platform default |
| `env` | Extra environment entries merged into the PTY child |

[`resolveShellSpec`](lib/pty/flutter_pty_backend.dart) and [`ShellSpec`](lib/pty/flutter_pty_backend.dart)
are exported so custom `PtyBackend` authors and tests can preview spawn
parameters without starting a process.

**Platform defaults (internal — no separate API):** when `program` and
`working_directory` are unset, `resolveShellSpec` applies sensible per-OS
behavior before `FlutterPtyBackend` calls `package:flutter_pty_new`:

- **Linux / macOS** — `$SHELL` or `/bin/bash`; cwd left unset (shell default).
- **Windows** — `cmd.exe`.
- **Android (experimental)** — first existing POSIX shell (`/system/bin/sh`, …);
  when `HOME` is missing or `/`, set `HOME` and default cwd to the app-private
  files directory. Call [`ShellDefaults.install`](lib/pty/shell_defaults.dart)
  from `main()` with `path_provider` (release builds block `/proc` reads):

```dart
if (Platform.isAndroid) {
  final dir = await getApplicationSupportDirectory();
  ShellDefaults.install(mobileHome: dir.path);
}
```

  Desktop paths like `/home/…` do not exist on Android.

To use Downloads, external storage, or Termux, the **host app** resolves the
path (e.g. `path_provider`) and passes it explicitly:

```dart
FlutterPtyBackend(
  shell: ShellConfig(
    workingDirectory: documentsPath,
    env: {'HOME': documentsPath},
  ),
)
```

Or in TOML:

```toml
[shell]
working_directory = "/storage/emulated/0/Download"
```

## Wiring SSH / remote PTY

Implement `PtyBackend` for your transport. The engine doesn't care where bytes
come from — it just needs a `Stream<Uint8List>` in and a `void write(Uint8List)`
out, plus `resize(rows, columns)` and `kill()` for lifecycle. The interface:

```dart
abstract class PtyBackend {
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  void kill();

  /// `null` when unknown (Windows, SSH, fakes).
  ValueListenable<bool>? get isForegroundProcessRunning => null;
}
```

`FlutterPtyBackend` (the v1 implementation) wraps `package:flutter_pty_new`.
Swapping in an SSH backend means returning bytes from the channel's stdout on
`output` and writing to its stdin on `write` — the engine stays unchanged.
See Plan 2S (TODO) for the upstream SSH/Mosh integration roadmap.

## Foreground process running (tab progress)

Hosts that want a tab loading indicator can listen to
`PtyBackend.isForegroundProcessRunning`. On Unix/Android,
`FlutterPtyBackend` exposes a non-null `ValueListenable<bool>` updated from
`flutter_pty_new`'s poll stream. On Windows (and for remote/SSH backends that do
not override the getter) the value is `null` — treat that as "unknown" and
skip the indicator. Polling is not started when the platform cannot report
foreground state.

```dart
final listenable = pty.isForegroundProcessRunning;
if (listenable != null) {
  return ValueListenableBuilder<bool>(
    valueListenable: listenable,
    builder: (_, running, __) => /* tab progress */,
  );
}
```

Do **not** retain the listenable past session teardown. On `kill()` / shell
exit the backend sets the value to `false` (notifying listeners) then
disposes the notifier and the getter returns `null`. Rebuild when the PTY
instance is replaced (e.g. after restart).

## Scroll input architecture

`TerminalView` routes all wheel / trackpad / touch-scroll gestures through an
internal `TerminalScrollController`: a program-scroll accumulator for TUI/mouse
reports and a separate history-wheel accumulator for discrete scrollback lines
(Alacritty `scroll_terminal` parity):

| Mode | Path |
|------|------|
| Normal scrollback wheel | `scrollLines` via controller (discrete lines + remainder) |
| Normal scrollback pan / fling | `scrollPixels` via controller (sub-cell, serialized) |
| Alt-screen + DEC 1007 (`kModeAlternateScroll`) | Batched SS3 arrow keys via `engine.scheduleWrite` |
| Mouse-report (`:set mouse=a`) | Batched SGR wheel reports via `scheduleWrite` |
| Shift + wheel (any mode) | Scrollback history (local) |

Scrollback history negates wheel dy (`PointerScrollEvent.scrollDelta`) but not
trackpad pan / touch drag dy — the platform uses opposite signs for the same
user intent. TUI program scroll applies the same wheel-vs-pan split before
line accumulation.

TUI scroll is **line-discrete** at the PTY boundary (arrow keys / mouse wheel
reports) — the same model as gnome-terminal/VTE and Alacritty. There is no
local `scrollFraction` preview in alt-screen; only scrollback uses sub-cell
pixels.

`engine.scheduleWrite(bytes)` coalesces PTY-bound scroll bytes to one `output`
event per microtask batch. TUI fling uses the program-scroll accumulator.

Absolute scroll (`scrollToBottom` / `scrollToTop` / `scrollToOffset`) cancels
pending gesture scroll, awaits [TerminalScrollController.drainHistoryScroll],
then applies the target position — so scrollbar drags do not race in-flight pan.

`scrollMultiplier` (default `3`) scales OS scroll deltas; `3` is neutral 1.0×.

### Program-scroll latency measurement

Locked start/stop markers and CI harness: see
[`docs/superpowers/specs/2026-07-16-tui-scroll-latency-method.md`](superpowers/specs/2026-07-16-tui-scroll-latency-method.md)
(`TERMINAL_SCROLL_TRACE=1` / `TerminalScrollLatency`).

## Reference example

`lib/example/example_app.dart` (`ExampleTerminalApp`) wires every piece
above plus the screen-level surface a real terminal needs:

- Restart overlay on shell exit (`pty.exitCode` -> dimmed banner over the view)
- Search bar (`TerminalSearchBar`) via `Ctrl+Shift+F`, with case / whole-word /
  regex / wrap toggles re-calling `searchSet` with `TerminalSearchOptions`
- File drag-and-drop via `desktop_drop` -> `pasteBytes` -> `engine.write`
- Right-click context menu with Copy / Paste / Open Hyperlink / Search
- `package:url_launcher` for Ctrl+click on hyperlinks
- Title mirroring via `engine.title.addListener` -> external `ValueNotifier`

That file is the canonical reference for "how do I do X in a real host"; the
quick-start above is enough to get a usable terminal on screen.
