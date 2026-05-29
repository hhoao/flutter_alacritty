import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../config/terminal_config.dart';
import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/paste.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/cell_metrics.dart';
import '../ui/search_bar.dart';
import '../ui/terminal_shortcuts.dart';
import '../ui/terminal_view.dart';

String _shellQuote(String s) {
  const needs = [
    ' ',
    '\t',
    '\'',
    '"',
    r'$',
    '`',
    r'\',
    '*',
    '?',
    '|',
    '&',
    ';',
    '<',
    '>',
    '(',
    ')',
    '#',
    '!',
    '~',
  ];
  if (!needs.any(s.contains)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}

typedef PtyFactory = PtyBackend Function({
  required int rows,
  required int columns,
});

typedef UrlLauncher = Future<bool> Function(String url);

enum TermStatus { running, exited, error }

/// Reference consumer of the `flutter_alacritty` library API.
///
/// Wires `FlutterPtyBackend` to `TerminalEngine` + `TerminalController` and
/// renders `TerminalView` with the screen-level surface a real terminal needs:
/// restart overlay on shell exit, search bar (Ctrl+Shift+F), drag-and-drop
/// of file paths as bracketed-paste, right-click context menu with
/// Copy/Paste/Search and hyperlink open, and url_launcher for clicked links.
///
/// Owns its own `MaterialApp` so callers can do `runApp(ExampleTerminalApp())`
/// without an additional wrapper. The `title` notifier is optional — if not
/// supplied, an internal one is created and mirrors `engine.title`.
class ExampleTerminalApp extends StatefulWidget {
  const ExampleTerminalApp({
    this.title,
    this.ptyFactory,
    this.engineFactory,
    this.config,
    this.launchUrl,
    super.key,
  });

  /// Optional external title notifier. When null the example creates and
  /// owns its own (and disposes it). Pass one when the host wants to observe
  /// title changes (e.g. for window decorations or tests).
  final ValueNotifier<String>? title;
  final PtyFactory? ptyFactory;
  final EngineFactory? engineFactory;
  final TerminalConfig? config;
  final UrlLauncher? launchUrl;

  @override
  State<ExampleTerminalApp> createState() => _ExampleTerminalAppState();
}

class _ExampleTerminalAppState extends State<ExampleTerminalApp> {
  late final ValueNotifier<String> _title =
      widget.title ?? ValueNotifier<String>('flutter_alacritty');
  late final bool _ownsTitle = widget.title == null;
  late final UrlLauncher _launch = widget.launchUrl ??
      (u) async => launcher.launchUrl(Uri.parse(u));
  late final TerminalConfig _config = widget.config ?? TerminalConfig.defaults();
  // Cell metrics drive the cols/rows the engine is spawned/resized into. We
  // compute them once here from the textStyle so layoutBuilder→_ensureStarted
  // and the nested TerminalView agree on sizing (both derive from the same
  // measured style).
  late final CellMetrics _metrics =
      CellMetrics.measure(_config.textStyle.copyWith(fontSize: _config.font.size));

  TerminalEngine? _engine;
  TerminalController _controller = TerminalController();
  // Focus owner lives on the screen so the post-restart sequence re-uses the
  // same node (and the IME stays attached across restart).
  final FocusNode _focus = FocusNode();

  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<Uint8List>? _engineOutputSub;
  StreamSubscription<String>? _clipSub;
  int _cols = 0, _rows = 0;
  TermStatus _status = TermStatus.running;
  int? _exitCode;
  String? _errorMessage;
  bool _searchOpen = false;

  final GlobalKey<State<TerminalView>> _viewKey =
      GlobalKey<State<TerminalView>>();

  @override
  void initState() {
    super.initState();
  }

  /// Mirror engine.title → host-visible notifier.
  void _syncTitle() {
    final e = _engine;
    if (e != null) _title.value = e.title.value;
  }

  void _ensureStarted(int cols, int rows) {
    if (_engine != null) {
      if ((cols != _cols || rows != _rows) && _status == TermStatus.running) {
        _cols = cols;
        _rows = rows;
        _engine!.resize(columns: cols, rows: rows);
        _pty!.resize(rows, cols);
        _engine!.scrollToBottom();
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    if (_status != TermStatus.error) {
      _start(cols, rows);
    }
  }

  void _start(int cols, int rows) {
    try {
      final pty = (widget.ptyFactory ??
          ({required int rows, required int columns}) =>
              FlutterPtyBackend(rows: rows, columns: columns))(
        rows: rows,
        columns: cols,
      );
      _pty = pty;
      final engine = TerminalEngine(
        config: _config,
        engineFactory: widget.engineFactory,
      );
      _engine = engine;
      _controller.attach(engine);
      engine.title.addListener(_syncTitle);
      _clipSub = engine.clipboardStore
          .listen((t) => Clipboard.setData(ClipboardData(text: t)));
      _engineOutputSub = engine.output.listen(pty.write);
      engine.resize(columns: cols, rows: rows);
      engine.initializeEmpty(rows, cols);
      _outputSub = pty.output.listen(
        engine.feed,
        onDone: () => _exitIfCurrent(pty, null),
      );
      pty.exitCode.then((code) => _exitIfCurrent(pty, code));
      _status = TermStatus.running;
      _exitCode = null;
      _errorMessage = null;
    } catch (e) {
      _status = TermStatus.error;
      _errorMessage = '$e';
    }
    if (mounted) setState(() {});
  }

  void _exitIfCurrent(PtyBackend p, int? code) {
    if (!identical(_pty, p)) return;
    if (_status != TermStatus.running) return;
    setState(() {
      _status = TermStatus.exited;
      _exitCode = code;
    });
  }

  void _restart() {
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _clipSub?.cancel();
    _pty?.kill();
    _engine?.title.removeListener(_syncTitle);
    _controller.dispose();
    _engine?.dispose();
    _controller = TerminalController();
    _outputSub = null;
    _engineOutputSub = null;
    _clipSub = null;
    _pty = null;
    _engine = null;
    _exitCode = null;
    _errorMessage = null;
    _start(_cols, _rows);
  }

  void _searchChanged(String pattern) {
    if (pattern.isEmpty) {
      _controller.searchClear();
    } else {
      _controller.searchSet(pattern);
    }
    setState(() {});
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
    });
    _controller.searchClear();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
    });
    if (!_searchOpen) _controller.searchClear();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || _engine == null) return;
    _onTerminalInputStart();
    _engine!.write(pasteBytes(text, modeFlags: _engine!.gridForView.modeFlags));
  }

  /// Screen-level mirror of the View's _onTerminalInputStart, for the paste /
  /// drop paths whose entry point is on the screen rather than the View.
  /// Same alacritty event.rs:on_terminal_input_start semantics.
  void _onTerminalInputStart() {
    if (_engine == null) return;
    final grid = _engine!.gridForView;
    final scrolledBack = grid.displayOffset != 0;
    if (scrolledBack) _engine!.scrollToBottom();
    if (_controller.selectionActive) {
      _controller.clearSelection();
      if (!scrolledBack) _engine!.refreshView();
    }
  }

  void _copySelection() {
    final text = _engine?.selectionText();
    if (text != null && text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> _showContextMenu(Offset local, Offset global, CellOffset cell) async {
    final selText = _engine?.selectionText() ?? '';
    final hyperUri = _engine?.hyperlinkAt(cell.row, cell.column);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        size.width - global.dx,
        size.height - global.dy,
      ),
      items: [
        PopupMenuItem(
          enabled: selText.isNotEmpty,
          child: const Text('Copy'),
          onTap: () {
            if (selText.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: selText));
            }
          },
        ),
        PopupMenuItem(onTap: _paste, child: const Text('Paste')),
        if (hyperUri != null) ...[
          PopupMenuItem(
            child: const Text('Open Hyperlink'),
            onTap: () {
              _launch(hyperUri);
            },
          ),
          PopupMenuItem(
            child: const Text('Copy Hyperlink Address'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: hyperUri));
            },
          ),
        ],
        PopupMenuItem(
          child: const Text('Search…'),
          onTap: () => setState(() => _searchOpen = true),
        ),
      ],
    );
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    final paths = details.files.map((f) => f.path).where((p) => p.isNotEmpty);
    if (paths.isEmpty) return;
    final joined = paths.map(_shellQuote).join(' ');
    _onTerminalInputStart();
    _engine?.write(
        pasteBytes(joined, modeFlags: _engine!.gridForView.modeFlags));
  }

  @visibleForTesting
  void simulateDrop(List<DropItem> files) => _onDrop(DropDoneDetails(
        files: files,
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ));

  @override
  void dispose() {
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _clipSub?.cancel();
    _pty?.kill();
    _engine?.title.removeListener(_syncTitle);
    _controller.dispose();
    _engine?.dispose();
    _focus.dispose();
    if (_ownsTitle) _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF000000 | _config.colors.background),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols =
              (constraints.maxWidth / _metrics.width).floor().clamp(1, 1000);
          final rows =
              (constraints.maxHeight / _metrics.height).floor().clamp(1, 1000);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _ensureStarted(cols, rows));
          return DropTarget(
            onDragDone: _onDrop,
            // Screen-level Shortcuts+Actions ensures Ctrl+Shift+F toggles the
            // search bar even when the bar's TextField has focus (the search
            // bar is a sibling of TerminalView under the Stack, so the View's
            // own Shortcuts ancestor doesn't reach it). The view re-installs
            // its own Shortcuts/Actions internally; this just makes the
            // search-toggle chord available everywhere.
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.keyF,
                    control: true, shift: true): ToggleSearchIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(
                    onInvoke: (_) {
                      _toggleSearch();
                      return null;
                    },
                  ),
                },
                child: Stack(
                  children: [
                    if (_engine != null)
                      TerminalView(
                        _engine!,
                        key: _viewKey,
                        controller: _controller,
                        theme: _config.theme,
                        textStyle: _config.style,
                        focusNode: _focus,
                        autofocus: true,
                        cursorBlinkInterval: Duration(
                            milliseconds: _config.cursor.blinkInterval),
                        bellDuration:
                            Duration(milliseconds: _config.bell.duration),
                        doubleClickThreshold: Duration(
                            milliseconds: _config.mouse.doubleClickThreshold),
                        scrollMultiplier: _config.scrolling.multiplier,
                        preeditBg: _config.ime.preeditBg,
                        preeditFg: _config.ime.preeditFg,
                        preeditUnderline: _config.ime.underline,
                        // Host-side overrides only — the view's internal
                        // default actions cover zoom, and a no-host Copy
                        // would just write the engine selection to the
                        // clipboard. Here we override Copy/Paste/Search so
                        // the screen-level state (search-bar visibility,
                        // selection-clear-on-paste) stays consistent.
                        actions: <Type, Action<Intent>>{
                          CopyIntent: CallbackAction<CopyIntent>(
                            onInvoke: (_) {
                              _copySelection();
                              return null;
                            },
                          ),
                          PasteIntent: CallbackAction<PasteIntent>(
                            onInvoke: (_) => _paste(),
                          ),
                          ToggleSearchIntent:
                              CallbackAction<ToggleSearchIntent>(
                            onInvoke: (_) {
                              _toggleSearch();
                              return null;
                            },
                          ),
                        },
                        onSecondaryTapUp: _onViewSecondaryTapUp,
                        onLinkActivate: _onLinkActivate,
                      ),
                    if (_status != TermStatus.running) _buildRestartLayer(),
                    // Always mounted under Offstage so first-time costs (IME
                    // attach on Linux, Material icon/font load) are paid at
                    // app startup — opening search just toggles visibility.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Offstage(
                        offstage: !_searchOpen,
                        child: TerminalSearchBar(
                          visible: _searchOpen,
                          invalidPattern: !_controller.searchValid,
                          onChanged: _searchChanged,
                          onNext: _controller.searchNext,
                          onPrev: _controller.searchPrev,
                          onClose: _closeSearch,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Restart overlay: absorbs any tap / key and triggers `_restart`. Sits on
  /// top of the (possibly-mounted) TerminalView so the screen-level test
  /// `tester.tap(find.byType(ExampleTerminalApp))` triggers a restart even though
  /// the view's listener is underneath.
  Widget _buildRestartLayer() {
    return Positioned.fill(
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          _restart();
          return KeyEventResult.handled;
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _restart(),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xCC1A1A1A),
              child: Text(
                _status == TermStatus.error
                    ? 'failed to start: ${_errorMessage ?? ''} — press any key to retry'
                    : 'process exited${_exitCode != null ? ' ($_exitCode)' : ''} — press any key to restart',
                style: const TextStyle(
                  color: Color(0xFFEDEDED),
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onViewSecondaryTapUp(TapUpDetails details, CellOffset cell) {
    _showContextMenu(details.localPosition, details.globalPosition, cell);
  }

  void _onLinkActivate(String uri) {
    _launch(uri);
  }
}
