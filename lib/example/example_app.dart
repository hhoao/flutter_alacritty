import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../config/terminal_config.dart';
import '../controller/terminal_controller.dart';
import '../controller/terminal_search_options.dart';
import '../engine/terminal_engine.dart';
import '../input/key_bindings.dart';
import '../input/paste.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../ui/search_bar.dart';
import '../ui/terminal_shortcuts.dart';
import '../links/url_link_provider.dart';
import '../ui/terminal_view.dart';
import 'terminal_history_scrollbar.dart';

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
    this.configUpdates,
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
  final Stream<TerminalConfig>? configUpdates;
  final UrlLauncher? launchUrl;

  @override
  State<ExampleTerminalApp> createState() => _ExampleTerminalAppState();
}

class _ExampleTerminalAppState extends State<ExampleTerminalApp> {
  late final ValueNotifier<String> _title =
      widget.title ?? ValueNotifier<String>(kDefaultTerminalTitle);
  late final bool _ownsTitle = widget.title == null;
  late final UrlLauncher _launch = widget.launchUrl ??
      (u) async => launcher.launchUrl(Uri.parse(u));
  late TerminalConfig _config = widget.config ?? TerminalConfig.defaults();
  late (Map<ShortcutActivator, Intent>, Map<Type, Action<Intent>>) _binds =
      bindingsToShortcuts(_config.keyboard.bindings);
  StreamSubscription<TerminalConfig>? _cfgSub;

  TerminalEngine? _engine;
  TerminalController _controller = TerminalController();
  // Focus owner lives on the screen so the post-restart sequence re-uses the
  // same node (and the IME stays attached across restart).
  final FocusNode _focus = FocusNode();

  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<Uint8List>? _engineOutputSub;
  StreamSubscription<String>? _clipSub;
  StreamSubscription<void>? _clipLoadSub;
  TermStatus _status = TermStatus.running;
  int? _exitCode;
  String? _errorMessage;
  bool _searchOpen = false;
  String _searchPattern = '';
  // Defaults match TerminalSearchOptions / GNOME-aligned engine defaults.
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = true;
  bool _wrap = true;

  final GlobalKey<State<TerminalView>> _viewKey =
      GlobalKey<State<TerminalView>>();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _cfgSub = widget.configUpdates?.listen(_applyConfig);
    if (_status != TermStatus.error) {
      _ensureEngine();
    }
  }

  void _applyConfig(TerminalConfig next) {
    final prev = _config;
    setState(() {
      _config = next;
      _binds = bindingsToShortcuts(next.keyboard.bindings);
    });
    _engine?.reconfigure(next);
    if (next.shell.program != prev.shell.program) {
      debugPrint('flutter_alacritty: [shell] change applies on restart');
    }
    for (final warning in next.warnInertOrHostOnlyKeys()) {
      debugPrint('flutter_alacritty: $warning');
    }
  }

  /// Mirror engine.title → host-visible notifier.
  void _syncTitle() {
    final e = _engine;
    if (e != null) _title.value = e.title.value;
  }

  /// Creates [TerminalEngine] once. PTY spawn is deferred to the first
  /// [TerminalView] layout commit via [_onPtyResize].
  void _ensureEngine() {
    if (_engine != null) return;
    for (final warning in _config.warnInertOrHostOnlyKeys()) {
      debugPrint('flutter_alacritty: $warning');
    }
    try {
      final engine = TerminalEngine(
        config: _config,
        engineFactory: widget.engineFactory,
      );
      _engine = engine;
      _controller.attach(engine);
      engine.title.addListener(_syncTitle);
      _clipSub = engine.clipboardStore
          .listen((t) => Clipboard.setData(ClipboardData(text: t)));
      _clipLoadSub = engine.clipboardLoad.listen((_) async {
        final data = await Clipboard.getData('text/plain');
        _engine?.respondClipboardLoad(data?.text ?? '');
      });
      _status = TermStatus.running;
      _exitCode = null;
      _errorMessage = null;
    } catch (e) {
      _status = TermStatus.error;
      _errorMessage = '$e';
    }
    if (mounted) setState(() {});
  }

  void _onPtyResize(int cols, int rows) {
    if (_status != TermStatus.running) return;
    if (_pty == null) {
      _startSession(cols, rows);
      return;
    }
    _pty!.resize(rows, cols);
  }

  void _startSession(int cols, int rows) {
    try {
      final pty = (widget.ptyFactory ??
          ({required int rows, required int columns}) =>
              FlutterPtyBackend(rows: rows, columns: columns, shell: _config.shell))(
        rows: rows,
        columns: cols,
      );
      _pty = pty;
      _engineOutputSub = _engine!.output.listen(pty.write);
      _outputSub = pty.output.listen(
        _engine!.feed,
        onDone: () => _exitIfCurrent(pty, null),
      );
      pty.exitCode.then((code) => _exitIfCurrent(pty, code));
    } catch (e) {
      _status = TermStatus.error;
      _errorMessage = '$e';
      if (mounted) setState(() {});
    }
  }

  void _tearDownSession() {
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _clipSub?.cancel();
    _clipLoadSub?.cancel();
    _pty?.kill();
    _engine?.title.removeListener(_syncTitle);
    _controller.dispose();
    _engine?.dispose();
    _controller = TerminalController();
    _outputSub = null;
    _engineOutputSub = null;
    _clipSub = null;
    _clipLoadSub = null;
    _pty = null;
    _engine = null;
    _exitCode = null;
    _errorMessage = null;
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
    _tearDownSession();
    setState(() {
      _status = TermStatus.running;
      _exitCode = null;
      _errorMessage = null;
    });
    _ensureEngine();
  }

  TerminalSearchOptions get _searchOptions => TerminalSearchOptions(
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        regex: _regex,
        wrap: _wrap,
      );

  void _applySearch(String pattern) {
    _searchPattern = pattern;
    if (pattern.isEmpty) {
      _controller.searchClear();
    } else {
      _controller.searchSet(pattern, options: _searchOptions);
    }
    // No setState for pattern-only updates — the search bar is wrapped in
    // ListenableBuilder over the controller (Fix #9), so it rebuilds when
    // searchValid flips. Toggle changes call setState themselves.
  }

  void _searchChanged(String pattern) => _applySearch(pattern);

  void _setSearchOption(void Function() update) {
    setState(update);
    _applySearch(_searchPattern);
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _searchPattern = '';
    });
    _controller.searchClear();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _searchPattern = '';
    });
    if (!_searchOpen) _controller.searchClear();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || _engine == null) return;
    // Single source of truth for the alacritty event.rs:on_terminal_input_start
    // gate — lives on the controller so the view's keystroke path and the
    // screen's paste/drop paths can't drift apart.
    _controller.onTerminalInputStart();
    _engine!.write(pasteBytes(text, modeFlags: _engine!.grid.modeFlags));
  }

  void _copySelection() {
    final text = _engine?.selectionText();
    if (text != null && text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> _showContextMenu(Offset local, Offset global, CellOffset cell) async {
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final menuContext = overlay.context;
    final selText = _engine?.selectionText() ?? '';
    final hyperUri = _engine?.hyperlinkAt(cell.row, cell.column);
    final renderBox = overlay.context.findRenderObject() as RenderBox?;
    final size = renderBox?.size ?? MediaQuery.of(menuContext).size;
    await showMenu<void>(
      context: menuContext,
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
    _controller.onTerminalInputStart();
    _engine?.write(pasteBytes(joined, modeFlags: _engine!.grid.modeFlags));
  }

  @visibleForTesting
  void simulateDrop(List<DropItem> files) => _onDrop(DropDoneDetails(
        files: files,
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ));

  @override
  void dispose() {
    _cfgSub?.cancel();
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _clipSub?.cancel();
    _clipLoadSub?.cancel();
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
    return ValueListenableBuilder<String>(
      valueListenable: _title,
      builder: (context, title, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        title: title,
        home: child,
      ),
      child: _buildShell(),
    );
  }

  Widget _buildShell() {
    return Scaffold(
      backgroundColor: Color(0xFF000000 | _config.colors.background),
      body: DropTarget(
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          if (_engine != null)
                            TerminalView(
                              _engine!,
                              key: _viewKey,
                              onPtyResize: _onPtyResize,
                              controller: _controller,
                              theme: _config.theme,
                              textStyle: _config.style,
                              padding: EdgeInsets.symmetric(
                                  horizontal: _config.window.padding.x,
                                  vertical: _config.window.padding.y),
                              focusNode: _focus,
                              autofocus: true,
                              cursorBlinkInterval: Duration(
                                  milliseconds:
                                      _config.cursor.blinkInterval),
                              cursorBlinkTimeout: Duration(
                                  seconds: _config.cursor.blinkTimeout),
                              bellDuration: Duration(
                                  milliseconds: _config.bell.duration),
                              doubleClickThreshold: Duration(
                                  milliseconds:
                                      _config.mouse.doubleClickThreshold),
                              scrollMultiplier: _config.scrolling.multiplier,
                              preeditBg: _config.ime.preeditBg,
                              preeditFg: _config.ime.preeditFg,
                              preeditUnderline: _config.ime.underline,
                              shortcuts: _binds.$1,
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
                              linkProviders: [UrlLinkProvider()],
                            ),
                          if (_status != TermStatus.running)
                            _buildRestartLayer(),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Offstage(
                              offstage: !_searchOpen,
                              child: ListenableBuilder(
                                listenable: _controller,
                                builder: (context, _) => TerminalSearchBar(
                                  visible: _searchOpen,
                                  invalidPattern: !_controller.searchValid,
                                  caseSensitive: _caseSensitive,
                                  wholeWord: _wholeWord,
                                  regex: _regex,
                                  wrap: _wrap,
                                  onChanged: _searchChanged,
                                  onNext: _controller.searchNext,
                                  onPrev: _controller.searchPrev,
                                  onClose: _closeSearch,
                                  onCaseSensitiveChanged: (v) =>
                                      _setSearchOption(() => _caseSensitive = v),
                                  onWholeWordChanged: (v) =>
                                      _setSearchOption(() => _wholeWord = v),
                                  onRegexChanged: (v) =>
                                      _setSearchOption(() => _regex = v),
                                  onWrapChanged: (v) =>
                                      _setSearchOption(() => _wrap = v),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_engine != null)
                      ListenableBuilder(
                        listenable: _engine!.grid,
                        builder: (context, _) => TerminalHistoryScrollbar(
                          engine: _engine!,
                          controller: _controller,
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
