import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey;

import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/ime_key_routing.dart';
import '../input/ime_session.dart';
import '../input/key_input.dart';
import '../input/mouse_input.dart';
import '../input/paste.dart';
import '../input/term_mode.dart';
import '../links/link_overlay.dart';
import '../links/terminal_link_provider.dart';
import '../render/cell_flags.dart';
import '../render/cell_metrics.dart';
import 'terminal_bell.dart';
import 'terminal_viewport.dart';
import 'terminal_viewport_controller.dart';
import 'terminal_scroll_controller.dart';
import 'viewport_geometry.dart';
import '../render/glyph_atlas.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import '../theme/terminal_theme.dart';
import 'preedit_overlay.dart';
import 'terminal_shortcuts.dart';

part 'terminal_view_pointer.dart';

// Kinetic-fling tuning, ported from GNOME Shell's js/ui/swipeTracker.js. The
// decelerations are per-millisecond velocity multipliers (the values that give
// the desktop's signature "coast"); start/stop cutoffs are in px/s and chosen
// for terminal scrolling (a coast distance of roughly half the fling speed).
const double _kFlingDecelerationTouch = 0.998;
// Tighter than GNOME's 0.997 — trackpad coast felt too long for terminal text.
const double _kFlingDecelerationTouchpad = 0.995;
// Trailing window over which a trackpad gesture's release velocity is averaged,
// matching swipeTracker.js EVENT_HISTORY_THRESHOLD_MS.
const int _kVelocityWindowMs = 150;

/// Logical cell coordinate (row, column) exposed to callback parameters so
/// consumers can act on tap location without reaching into the painter.
class CellOffset {
  const CellOffset(this.row, this.column);
  final int row;
  final int column;
}

/// The mouse pointer shape over a terminal cell, mirroring alacritty's
/// `reset_mouse_cursor` (`MouseCursorDirty` handling): a link shows the click
/// pointer; when the app captures the mouse (`MOUSE_MODE`) the pointer reverts
/// to the platform arrow; otherwise the configured [base] (an I-beam) is used.
/// Pure so it's unit-testable without driving pointer events.
MouseCursor hoverCursorFor({
  required bool hyperlink,
  required int modeFlags,
  required MouseCursor base,
}) {
  if (hyperlink) return SystemMouseCursors.click;
  if (anyMouse(modeFlags)) return SystemMouseCursors.basic;
  return base;
}

// Hosts opt in to regex/file-path links via [linkProviders]. OSC 8 hyperlinks
// from the engine need no provider. An empty default avoids scanning every
// visible row on each PTY update (Orca/xterm only scan a line on hover).
const List<TerminalLinkProvider> _defaultLinkProviders = [];

/// Pure render + input view over a [TerminalEngine].
///
/// Owns render state (font, metrics, glyph cache, bell controller, blink
/// timer), IME session, and pointer/selection state. Hotkeys are dispatched
/// through Flutter's `Shortcuts` + `Actions` framework rather than an
/// inline switch — see [shortcuts] and [actions]. Does NOT own the engine,
/// the PTY, the search bar widget, drop handling, the right-click context
/// menu, or URL launching — those stay on the host (the reference example
/// is `ExampleTerminalApp`) and are wired in via the callback hooks below.
class TerminalView extends StatefulWidget {
  TerminalView(
    this.engine, {
    super.key,
    this.controller,
    this.theme = TerminalTheme.defaults,
    TerminalStyle? textStyle,
    this.padding,
    this.backgroundOpacity = 1.0,
    this.focusNode,
    this.autofocus = true,
    this.mouseCursor = SystemMouseCursors.text,
    this.readOnly = false,
    this.cursorBlinkInterval = const Duration(milliseconds: 530),
    this.cursorBlinkTimeout = const Duration(seconds: 5),
    this.bellDuration = Duration.zero,
    this.doubleClickThreshold = const Duration(milliseconds: 300),
    this.scrollMultiplier = 3,
    this.tuiScrollSensitivity = 1,
    this.preeditBg = 0x282828,
    this.preeditFg = 0xD8D8D8,
    this.preeditUnderline = true,
    this.shortcuts,
    this.actions,
    this.onTapDown,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onLinkActivate,
    this.primaryTapActivatesLink = false,
    this.onBell,
    this.onPtyResize,
    List<TerminalLinkProvider>? linkProviders,
  })  : linkProviders = linkProviders ?? _defaultLinkProviders,
        textStyle = textStyle ?? TerminalStyle.defaults();

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

  /// Cursor blink half-period.
  final Duration cursorBlinkInterval;

  /// Stop blinking after this much inactivity (no terminal input); the cursor
  /// then stays solid until the next input. `Duration.zero` = never stop.
  /// Mirrors alacritty's `cursor.blink_timeout`.
  final Duration cursorBlinkTimeout;

  /// Bell flash duration (zero disables the visual bell).
  final Duration bellDuration;

  /// Double/triple-click window for word/line selection.
  final Duration doubleClickThreshold;

  /// Approximate lines scrolled per wheel notch (alacritty's
  /// `scrolling.multiplier`; default 3). History wheel uses discrete
  /// [scrollLines]; touch pan/fling use sub-cell [scrollPixels]. The multiplier
  /// is applied to the platform pixel delta as `scrollMultiplier / 3` — a raw
  /// wheel notch is ~3 lines of pixels, so the default reproduces alacritty's
  /// 3-lines/notch and e.g. `1` ≈ one line/notch.
  final int scrollMultiplier;

  /// Mouse-report TUI wheel sensitivity (1..10). Alternate-scroll still uses
  /// [scrollMultiplier]; only the mouse-report wheel path uses this.
  final int tuiScrollSensitivity;

  /// Preedit overlay colors / underline (packed RGB, alpha forced full).
  final int preeditBg;
  final int preeditFg;
  final bool preeditUnderline;

  /// Hotkey bindings. `null` means use [defaultTerminalShortcuts]; pass an
  /// empty map (`const {}`) to disable every default; pass any other map to
  /// override individual entries (the view does NOT merge with defaults —
  /// the supplied map is the complete shortcut set).
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Action handlers for the intents dispatched by [shortcuts]. `null`
  /// means the view builds [defaultTerminalActions] internally (with a
  /// no-op paste/search/zoom and a self-contained copy that writes the
  /// engine selection to the system clipboard). Hosts typically supply
  /// their own actions to wire host-side semantics (search-bar visibility,
  /// custom paste filtering, etc.).
  final Map<Type, Action<Intent>>? actions;

  // Pointer / hyperlink callback hooks — the host wires these
  // (context menu, URL launch). These cover screen-driven UI bits the
  // view itself can't decide.
  final void Function(TapDownDetails, CellOffset)? onTapDown;
  final void Function(TapUpDetails, CellOffset)? onTapUp;
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;
  final void Function(String uri)? onLinkActivate;

  /// When true, a plain (unmodified) left-click on a hyperlink or detected-link
  /// cell fires [onLinkActivate] instead of forwarding the click to the program
  /// (or starting a selection). Ctrl/Cmd-click always activates links
  /// regardless. Non-link cells are unaffected — they still select / report to
  /// the program as usual. Defaults to `false` to preserve standard terminal
  /// mouse semantics; hosts that prefer click-to-open opt in.
  final bool primaryTapActivatesLink;

  /// Bell event hook (fires in addition to the visual flash). If null, the
  /// view plays a system alert sound (current behavior).
  final void Function()? onBell;

  /// Fired after the engine and mirror grid adopt `(columns, rows)`. Wire to
  /// `PtyBackend.resize(rows, columns)`. The engine resizes before this fires.
  final void Function(int columns, int rows)? onPtyResize;

  /// Host-injectable link sources. Defaults to `const []` (no per-line regex scan
  /// on PTY output); pass e.g. `[UrlLinkProvider()]` to enable URL detection.
  /// OSC 8 hyperlinks from the engine work without any provider.
  final List<TerminalLinkProvider> linkProviders;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView>
    with TickerProviderStateMixin {
  TerminalEngine get _engine => widget.engine;
  late TerminalController _controller;
  bool _ownsController = false;
  late FocusNode _focus;
  bool _ownsFocus = false;

  late AnimationController _bellCtrl;
  late double _fontSize;
  late TextStyle _style;
  late CellMetrics _metrics;
  late GlyphCache _glyphs;
  // GPU glyph atlas for the grid layer: one drawRawAtlas per frame instead of
  // per-cell drawParagraph. Created lazily in build() (needs devicePixelRatio
  // from context) and rebuilt when the font metrics or DPR change. The cursor
  // layer keeps using [_glyphs] (a single glyph, not worth atlasing).
  GlyphAtlas? _atlas;
  double _atlasDpr = 0;

  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;

  late TerminalViewportController _viewportController;
  TerminalViewport? _viewport;

  // Wall-clock of the last terminal input; drives `cursorBlinkTimeout` (blink
  // pauses after inactivity, resumes solid-then-blinking on the next input).
  DateTime _lastInputAt = DateTime.now();

  String? _preedit;
  late final ImeSession _ime = ImeSession(
    onCommit: _writeCommittedText,
    onPreeditChanged: _onPreeditChanged,
    onBackspace: _onImeBackspace,
  );
  Rect? _lastReportedCaretRect;

  bool _lastFocused = false;
  int _pressedButton = 0;
  int _clickCount = 0;
  // Secondary-tap (right click) state: filled on press, drained on release.
  // Lets us fire `onSecondaryTapUp` at the correct moment instead of
  // synchronously on press (which was the original bug — both Down and Up
  // fired in [_onPointerDown], breaking any consumer wiring both).
  CellOffset? _secondaryDownCell;
  Offset? _secondaryDownLocal;
  Offset? _secondaryDownGlobal;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
  // Set when a primary-button press activated a link, so the matching release
  // is swallowed instead of reported to the program (which would otherwise see
  // a phantom click and open the link a second time externally).
  bool _linkActivatedOnDown = false;
  late TerminalScrollController _scrollController;
  // Trailing (timestamp, dy) samples for estimating trackpad release velocity,
  // since pan-zoom gestures carry no velocity of their own (unlike DragEnd).
  final List<(Duration, double)> _panSamples = [];
  MouseCursor _hoverCursor = MouseCursor.defer;

  StreamSubscription<void>? _bellSub;

  LinkOverlay _linkOverlay = LinkOverlay.empty;
  /// Viewport row under the pointer; drives lazy provider scans (one row only).
  int? _hoverLinkRow;
  /// Guards [MouseRegion.onExit] during rebuilds (spurious exit when overlay setState).
  bool _mouseInGridLayer = false;
  int _lastDisplayOffset = 0;
  double _lastScrollFraction = 0;

  // The painter and UI helpers read the grid directly; the engine owns the
  // grid (single source of truth), and the view never paints before the
  // engine has been built (the host gates this with its error/exit
  // overlay).
  MirrorGrid get _grid => _engine.gridForView;

  @visibleForTesting
  ImeSession get imeForTest => _ime;

  @visibleForTesting
  String? get preeditForTest => _preedit;

  @visibleForTesting
  AnimationController get bellControllerForTest => _bellCtrl;

  @visibleForTesting
  void flashBellForTest() => _flashBell();

  @visibleForTesting
  LinkOverlay get linkOverlayForTest => _linkOverlay;

  @visibleForTesting
  GlyphCache get glyphCacheForTest => _glyphs;

  @visibleForTesting
  GlyphAtlas? get atlasForTest => _atlas;

  @visibleForTesting
  bool get isFlingingForTest => _scrollController.isFlinging;

  @visibleForTesting
  void startFlingForTest(double velocityPxPerSec) {
    _scrollController.startFling(
      velocityPxPerSec: velocityPxPerSec,
      deceleration: _kFlingDecelerationTouch,
      shiftHeld: false,
      createTicker: createTicker,
    );
  }

  @visibleForTesting
  TerminalViewportController get viewportControllerForTest => _viewportController;

  /// Last committed viewport from the most recent layout pass.
  TerminalViewport? get viewport => _viewportController.committed;

  /// Suppress PTY SIGWINCH while host chrome animates (e.g. sidebar). Engine
  /// and mirror still track the live layout; call [endPtyHold] to flush one
  /// SIGWINCH. Use a [GlobalKey<TerminalViewState>] to reach these from the host.
  void beginPtyHold() => _viewportController.beginPtyHold();

  /// Ends a [beginPtyHold] bracket; when [flush] is true, fires one deferred
  /// `onPtyResize` if the grid changed during the hold.
  void endPtyHold({bool flush = true}) =>
      _viewportController.endPtyHold(flush: flush);

  @override
  void initState() {
    super.initState();
    _viewportController = TerminalViewportController(
      engine: widget.engine,
      onPtyResize: widget.onPtyResize,
    );
    _controller = widget.controller ?? (TerminalController()..attach(_engine));
    _ownsController = widget.controller == null;
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _fontSize = widget.textStyle.size;
    _style = widget.textStyle.toTextStyle().copyWith(fontSize: _fontSize);
    _metrics = _measureMetrics();
    _scrollController = _newScrollController();
    _wireCoalescedScrollCancel();
    widget.engine.setCellPixels(_metrics.width.round(), _metrics.height.round());
    _glyphs = _newGlyphCache();
    _bellCtrl = AnimationController(
      vsync: this,
      duration: widget.bellDuration > Duration.zero
          ? widget.bellDuration
          : const Duration(milliseconds: 1),
    );
    _blinkTimer = Timer.periodic(widget.cursorBlinkInterval, (_) => _blinkTick());
    _focus.addListener(_reportFocus);
    _focus.addListener(_handleImeFocusChange);
    _bellSub = _engine.bell.listen((_) => _flashBell());
    for (final p in widget.linkProviders) {
      p.addListener(_onProviderChanged);
    }
    if (widget.linkProviders.isNotEmpty) {
      _lastDisplayOffset = _grid.displayOffset;
      _lastScrollFraction = _grid.scrollFraction;
      _grid.addListener(_onGridLinkContextChanged);
    }
  }

  @override
  void didUpdateWidget(covariant TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Engine swap: the host replaced the engine (e.g. ExampleTerminalApp
    // restart after shell exit). Cancel the bell subscription pointing at
    // the OLD engine — whose stream controller has already been closed by
    // `engine.dispose()` — and re-subscribe to the new engine's bell. Without
    // this, post-restart Bell events flow into a dead stream and the visual
    // / audible bell silently breaks. Pinned by the regression test
    // `bell after engine swap still flashes`.
    if (!identical(widget.engine, oldWidget.engine)) {
      oldWidget.engine.onCancelCoalescedScroll = null;
      _bellSub?.cancel();
      _bellSub = widget.engine.bell.listen((_) => _flashBell());
      _lastReportedCaretRect = null;
      // Re-wire grid listener to the new engine's grid.
      if (oldWidget.linkProviders.isNotEmpty) {
        oldWidget.engine.gridForView.removeListener(_onGridLinkContextChanged);
      }
      if (widget.linkProviders.isNotEmpty) {
        widget.engine.gridForView.addListener(_onGridLinkContextChanged);
        _lastDisplayOffset = widget.engine.gridForView.displayOffset;
        _lastScrollFraction = widget.engine.gridForView.scrollFraction;
      }
      _hoverLinkRow = null;
      _linkOverlay = LinkOverlay.empty;
      // The view is reused across engine swaps (TeamPilot host swaps engines
      // per member/tab). Abandon any in-flight IME pre-edit so a stale
      // composition can't commit into the swapped-in engine. notify:false +
      // direct field assignment because build() runs right after didUpdateWidget
      // (calling setState here would throw).
      if (_ime.isComposing || _preedit != null) {
        _ime.resetComposing(notify: false);
        _preedit = null;
      }
      // Reused view: a kinetic fling coasting at swap time would scroll the
      // swapped-in engine. Rebuild the scroll controller so PTY writes and
      // history scroll target the swapped-in engine (same pattern as resize).
      _scrollController.dispose();
      _scrollController = _newScrollController();
      _wireCoalescedScrollCancel();
      _scrollController.onGestureStart();
      _viewportController.dispose();
      _viewportController = TerminalViewportController(
        engine: widget.engine,
        onPtyResize: widget.onPtyResize,
      );
    }
    if (widget.onPtyResize != oldWidget.onPtyResize) {
      _viewportController.updateHostPtyResize(widget.onPtyResize);
    }
    // Re-attach controller / focus if the caller swapped them out. Rare; the
    // host typically creates both once.
    if (!identical(widget.controller, oldWidget.controller)) {
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? (TerminalController()..attach(_engine));
      _ownsController = widget.controller == null;
    }
    if (!identical(widget.focusNode, oldWidget.focusNode)) {
      // Always remove our listeners from the old node regardless of ownership
      // — otherwise a host-supplied node that gets swapped out retains our
      // listeners forever (memory leak + spurious callbacks against the
      // disposed view).
      _focus.removeListener(_reportFocus);
      _focus.removeListener(_handleImeFocusChange);
      if (_ownsFocus) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _ownsFocus = widget.focusNode == null;
      _focus.addListener(_reportFocus);
      _focus.addListener(_handleImeFocusChange);
    }
    if (oldWidget.bellDuration != widget.bellDuration) {
      _bellCtrl.duration = widget.bellDuration > Duration.zero
          ? widget.bellDuration
          : const Duration(milliseconds: 1);
    }
    if (oldWidget.cursorBlinkInterval != widget.cursorBlinkInterval) {
      _blinkTimer?.cancel();
      _blinkTimer =
          Timer.periodic(widget.cursorBlinkInterval, (_) => _blinkTick());
    }
    if (oldWidget.textStyle != widget.textStyle) {
      setState(() {
        _fontSize = widget.textStyle.size;
        _glyphs.dispose();
        _style = widget.textStyle.toTextStyle().copyWith(fontSize: _fontSize);
        _metrics = _measureMetrics();
        _scrollController.updateCellHeight(_metrics.height);
        widget.engine.setCellPixels(
            _metrics.width.round(), _metrics.height.round());
        _glyphs = _newGlyphCache();
        _disposeAtlas(); // rebuilt lazily in build() with the new metrics
      });
    }
    if (!identical(widget.linkProviders, oldWidget.linkProviders)) {
      for (final p in oldWidget.linkProviders) {
        p.removeListener(_onProviderChanged);
      }
      for (final p in widget.linkProviders) {
        p.addListener(_onProviderChanged);
      }
      if (oldWidget.linkProviders.isNotEmpty) {
        _grid.removeListener(_onGridLinkContextChanged);
      }
      if (widget.linkProviders.isNotEmpty) {
        _lastDisplayOffset = _grid.displayOffset;
        _lastScrollFraction = _grid.scrollFraction;
        _grid.addListener(_onGridLinkContextChanged);
      } else {
        _hoverLinkRow = null;
        if (_linkOverlay != LinkOverlay.empty) {
          setState(() => _linkOverlay = LinkOverlay.empty);
        }
      }
      _refreshHoverLinkOverlay();
    }
  }

  /// Strut multiplier matching measured *content* height (primary-font
  /// ascent+descent × configured height — Alacritty-style; #5).
  /// Uses [CellMetrics.contentHeight] so `font.offset` Y grows the cell without
  /// stretching the strut the same way content growth does.
  double get _effectiveLineHeight => _fontSize > 0
      ? _metrics.strutLineHeight(_fontSize)
      : widget.textStyle.lineHeight;

  GlyphCache _newGlyphCache() => GlyphCache(
        fontFamily: widget.textStyle.family,
        fontFamilyFallback: widget.textStyle.fallback,
        boldFamily: widget.textStyle.boldFamily,
        italicFamily: widget.textStyle.italicFamily,
        boldItalicFamily: widget.textStyle.boldItalicFamily,
        fontSize: _fontSize,
        cellWidth: _metrics.width,
        lineHeight: _effectiveLineHeight,
        glyphOffsetX: widget.textStyle.glyphOffsetX,
        glyphOffsetY: widget.textStyle.glyphOffsetY,
      );

  CellMetrics _measureMetrics() => CellMetrics.measure(
        _style,
        offsetX: widget.textStyle.offsetX,
        offsetY: widget.textStyle.offsetY,
      );

  /// Ensures [_atlas] exists and matches the current font metrics and [dpr].
  /// Cheap no-op once built; recreated only when the cache was invalidated
  /// (font zoom / style change null it) or the device pixel ratio changes.
  void _ensureAtlas(double dpr) {
    if (_atlas != null && _atlasDpr == dpr) return;
    _atlas?.dispose();
    _atlasDpr = dpr;
    _atlas = GlyphAtlas(
      fontFamily: widget.textStyle.family,
      fontFamilyFallback: widget.textStyle.fallback,
      boldFamily: widget.textStyle.boldFamily,
      italicFamily: widget.textStyle.italicFamily,
      boldItalicFamily: widget.textStyle.boldItalicFamily,
      fontSize: _fontSize,
      cellWidth: _metrics.width,
      cellHeight: _metrics.height,
      lineHeight: _effectiveLineHeight,
      glyphOffsetX: widget.textStyle.glyphOffsetX,
      glyphOffsetY: widget.textStyle.glyphOffsetY,
      devicePixelRatio: dpr,
    );
    _atlas!.prewarmAscii();
  }

  void _disposeAtlas() {
    _atlas?.dispose();
    _atlas = null;
  }

  TerminalScrollController _newScrollController() => TerminalScrollController(
        engine: widget.engine,
        cellHeight: _metrics.height,
        scrollMultiplier: widget.scrollMultiplier,
        tuiScrollSensitivity: widget.tuiScrollSensitivity,
      );

  void _wireCoalescedScrollCancel() {
    widget.engine.onCancelCoalescedScroll =
        _scrollController.cancelPendingHistory;
    widget.engine.onDrainHistoryScroll =
        _scrollController.drainHistoryScroll;
  }

  @override
  void dispose() {
    widget.engine.onCancelCoalescedScroll = null;
    widget.engine.onDrainHistoryScroll = null;
    _scrollController.dispose();
    _viewportController.dispose();
    _blinkTimer?.cancel();
    _blinkOn.dispose();
    _bellSub?.cancel();
    _focus.removeListener(_reportFocus);
    _focus.removeListener(_handleImeFocusChange);
    _ime.detach(notify: false);
    if (_ownsFocus) _focus.dispose();
    if (_ownsController) _controller.dispose();
    _bellCtrl.dispose();
    _glyphs.dispose();
    _disposeAtlas();
    if (widget.linkProviders.isNotEmpty) {
      _grid.removeListener(_onGridLinkContextChanged);
    }
    for (final p in widget.linkProviders) {
      p.removeListener(_onProviderChanged);
    }
    super.dispose();
  }

  void _flashBell() {
    handleTerminalBell(
      onBell: widget.onBell,
      bellDuration: widget.bellDuration,
      flashVisual: (duration) {
        _bellCtrl.value = 1.0;
        _bellCtrl.animateTo(0.0, duration: duration);
      },
    );
  }

  /// Provider cache/async confirmation changed — refresh the hovered row only.
  void _onProviderChanged() => _refreshHoverLinkOverlay();

  /// Grid moved or the hovered row's content may have changed.
  void _onGridLinkContextChanged() {
    if (widget.linkProviders.isEmpty) return;
    final scrollChanged = _grid.displayOffset != _lastDisplayOffset ||
        _grid.scrollFraction != _lastScrollFraction;
    _lastDisplayOffset = _grid.displayOffset;
    _lastScrollFraction = _grid.scrollFraction;
    if (scrollChanged) {
      _refreshHoverLinkOverlay();
      return;
    }
    if (_hoverLinkRow != null) {
      _setLinkOverlayForRow(_hoverLinkRow!);
    }
  }

  void _onHoverRowChanged(int row) {
    if (widget.linkProviders.isEmpty) return;
    if (_hoverLinkRow == row) return;
    _hoverLinkRow = row;
    _setLinkOverlayForRow(row);
  }

  void _clearHoverLinkOverlay() {
    if (_hoverLinkRow == null && _linkOverlay == LinkOverlay.empty) return;
    _hoverLinkRow = null;
    if (_linkOverlay != LinkOverlay.empty) {
      setState(() => _linkOverlay = LinkOverlay.empty);
    }
  }

  void _onGridMouseEnter(PointerEnterEvent _) => _mouseInGridLayer = true;

  void _onGridMouseExit(PointerExitEvent _) {
    _mouseInGridLayer = false;
    // Rebuild after hover overlay setState can dispose the old MouseRegion and
    // fire a spurious onExit; defer clear so a matching onEnter cancels it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mouseInGridLayer) return;
      _clearHoverLinkOverlay();
    });
  }

  void _refreshHoverLinkOverlay() {
    final row = _hoverLinkRow;
    if (row == null) {
      if (_linkOverlay != LinkOverlay.empty) {
        setState(() => _linkOverlay = LinkOverlay.empty);
      }
      return;
    }
    _setLinkOverlayForRow(row);
  }

  List<LinkCellRange> _rangesForRow(int row) {
    if (row < 0 || row >= _grid.rows) return const [];
    final text = _lineText(row);
    if (text.trim().isEmpty) return const [];
    final ranges = <LinkCellRange>[];
    for (final provider in widget.linkProviders) {
      for (final span in provider.scan(text)) {
        if (provider.isEnabled(span)) {
          ranges.add(LinkCellRange(start: span.start, end: span.end));
        }
      }
    }
    return ranges;
  }

  void _setLinkOverlayForRow(int row) {
    if (!mounted || widget.linkProviders.isEmpty) return;
    final ranges = _rangesForRow(row);
    final next = ranges.isEmpty
        ? LinkOverlay.empty
        : LinkOverlay({row: ranges});
    if (next != _linkOverlay) setState(() => _linkOverlay = next);
  }

  String _lineText(int row) {
    final sb = StringBuffer();
    for (var c = 0; c < _grid.columns; c++) {
      final cp = _grid.codepointAt(row, c);
      sb.writeCharCode(cp == 0 ? 32 : cp);
    }
    return sb.toString();
  }

  // LinkOverlay stores only cell ranges (not payloads); re-scan the line on
  // click to recover the covering span's payload.
  String? _payloadAt(int row, int col) {
    if (widget.linkProviders.isEmpty) return null;
    final text = _lineText(row);
    for (final provider in widget.linkProviders) {
      for (final span in provider.scan(text)) {
        if (provider.isEnabled(span) && span.contains(col)) return span.payload;
      }
    }
    return null;
  }

  void _setZoom(double next) {
    final clamped = next.clamp(6.0, 72.0);
    if (clamped == _fontSize) return;
    setState(() {
      _fontSize = clamped;
      _glyphs.dispose();
      _style = widget.textStyle.toTextStyle().copyWith(fontSize: _fontSize);
      _metrics = _measureMetrics();
      _scrollController.updateCellHeight(_metrics.height);
      widget.engine.setCellPixels(_metrics.width.round(), _metrics.height.round());
      _glyphs = _newGlyphCache();
      _disposeAtlas(); // rebuilt lazily in build() with the new metrics
    });
  }

  /// Encode-and-write fallback. Runs after the Shortcuts framework has had
  /// a chance to match the chord against [defaultTerminalShortcuts] (or the
  /// consumer-supplied map). For matched chords we early-return so the
  /// encodeKey path doesn't double-fire (e.g. Ctrl+Shift+F would otherwise
  /// also produce the 0x06 control byte).
  ///
  /// Why this ordering rather than nesting Shortcuts below: with `Focus` as
  /// the focused widget, Flutter dispatches `onKeyEvent` bottom-up before
  /// reaching any ancestor `Shortcuts` widget, so we have to perform the
  /// activator match ourselves here and bail before the encodeKey hop.
  KeyEventResult _onKeyFallback(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    // Let the Shortcuts/Actions framework claim the chord first. If any
    // registered activator matches, we dispatch via `Actions.maybeFind` +
    // explicit invocation (the `maybeInvoke` shortcut would only report
    // success via its return value, but our actions return null on purpose
    // since they wrap void callbacks). On a successful dispatch we return
    // `handled` so the event doesn't continue propagating into ancestor
    // Shortcuts widgets (e.g. a screen-level Ctrl+Shift+F override would
    // otherwise double-fire).
    final shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    for (final entry in shortcuts.entries) {
      if (entry.key.accepts(event, hw)) {
        final ctx = node.context;
        if (ctx == null) return KeyEventResult.ignored;
        final action = Actions.maybeFind<Intent>(ctx, intent: entry.value);
        if (action == null) return KeyEventResult.ignored;
        Actions.of(ctx).invokeActionIfEnabled(action, entry.value, ctx);
        return KeyEventResult.handled;
      }
    }
    // Alacritty `input/keyboard.rs`: while `display.ime.preedit()` is set, key_input
    // returns immediately — Backspace/arrows/printables stay with the OS IME, not
    // the PTY. Shortcuts above still run (Ctrl+Shift+C, etc.).
    if (_ime.isComposing) {
      return KeyEventResult.ignored;
    }
    if (ImeKeyRouting.isDeferrablePrintableKeyEvent(event, hw) &&
        ImeKeyRouting.shouldDeferPrintableToTextInput(
          imeAttached: _ime.isAttached,
          imeComposing: false,
        )) {
      return KeyEventResult.ignored;
    }
    final bytes = encodeKey(
      event.logicalKey,
      event.character,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
      meta: hw.isMetaPressed,
      modeFlags: _grid.modeFlags,
    );
    if (bytes == null) return KeyEventResult.ignored;
    _onTerminalInputStart();
    _writeToEngine(bytes);
    return KeyEventResult.handled;
  }

  /// Mirror alacritty event.rs:on_terminal_input_start. Delegates to the
  /// controller so the host paste/drop paths (`ExampleTerminalApp._paste` /
  /// `_onDrop` / `defaultPasteAction`) share the same gated implementation.
  void _onTerminalInputStart() => _controller.onTerminalInputStart();

  /// Write helper that drops bytes when [TerminalView.readOnly] is set.
  /// Centralizes the gate so every PTY-bound path (keys, mouse reports,
  /// IME commits, paste, focus reports, scroll-as-arrows) honors readOnly
  /// uniformly. Without this the prop would only have gated `_onKeyFallback`,
  /// leaving mouse/IME/middle-paste paths leaking bytes — caught in review.
  void _writeToEngine(Uint8List bytes) {
    if (widget.readOnly) return;
    // Reset the blink-idle timer and show a solid cursor immediately so the
    // caret reappears the instant the user types (alacritty parity).
    _lastInputAt = DateTime.now();
    if (!_blinkOn.value) _blinkOn.value = true;
    _engine.write(bytes);
  }

  /// One blink period: toggle the caret unless we're past the inactivity
  /// timeout, in which case hold it solid until the next input.
  void _blinkTick() {
    final timeout = widget.cursorBlinkTimeout;
    if (timeout > Duration.zero &&
        DateTime.now().difference(_lastInputAt) > timeout) {
      if (!_blinkOn.value) _blinkOn.value = true; // hold solid while idle
      return;
    }
    _blinkOn.value = !_blinkOn.value;
  }

  void _reportFocus() {
    if (!focusReport(_grid.modeFlags)) {
      _lastFocused = _focus.hasFocus;
      return;
    }
    if (_focus.hasFocus == _lastFocused) return;
    _lastFocused = _focus.hasFocus;
    _writeToEngine(Uint8List.fromList(
        _focus.hasFocus ? [0x1b, 0x5b, 0x49] : [0x1b, 0x5b, 0x4f]));
  }

  void _handleImeFocusChange() {
    if (_focus.hasFocus) {
      // Route hardware keys through TextInput on macOS/Windows IME (xterm parity).
      _focus.consumeKeyboardToken();
      _ime.attach();
    } else {
      _ime.detach();
      _lastReportedCaretRect = null;
    }
  }

  void _onPreeditChanged(String? p) {
    if (!mounted) return;
    if (p == _preedit) return;
    setState(() => _preedit = p);
  }

  void _writeCommittedText(String t) {
    if (t.isEmpty) return;
    _onTerminalInputStart();
    _writeToEngine(Uint8List.fromList(utf8.encode(t)));
  }

  void _onImeBackspace() {
    final hw = HardwareKeyboard.instance;
    final bytes = encodeKey(
      LogicalKeyboardKey.backspace,
      null,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
      meta: hw.isMetaPressed,
      modeFlags: _grid.modeFlags,
    );
    if (bytes == null) return;
    _onTerminalInputStart();
    _writeToEngine(bytes);
  }

  void _reportCaretRectToIme() {
    if (!_ime.isAttached) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final localRect = Rect.fromLTWH(
      (_viewport?.paddingX ?? 0) + _grid.cursorCol * _metrics.width,
      // Match the painter's sub-cell shift so the OS IME/preedit popup tracks
      // the visually-shifted cursor during fractional scroll.
      (_viewport?.paddingY ?? 0) +
          (_grid.cursorRow + _grid.scrollFraction) * _metrics.height,
      _metrics.width,
      _metrics.height,
    );
    final globalRect =
        renderBox.localToGlobal(localRect.topLeft) & localRect.size;
    if (globalRect == _lastReportedCaretRect) return;
    _lastReportedCaretRect = globalRect;
    _ime.setImeGeometry(
      editableSize: _viewport?.cellRect.size ?? renderBox.size,
      editableTransform: renderBox.getTransformTo(null),
      globalCaret: globalRect,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cell grid must match the padded paint area — otherwise PTY/cols are
        // sized to the outer box while CustomPaint is inset and right columns
        // (e.g. box-drawing borders) are clipped.
        final pad = widget.padding ?? EdgeInsets.zero;
        final availW =
            (constraints.maxWidth - pad.horizontal).clamp(0.0, double.infinity);
        final availH =
            (constraints.maxHeight - pad.vertical).clamp(0.0, double.infinity);

        final query = ViewportQuery(
          available: Size(availW, availH),
          cell: _metrics,
        );
        final viewport = _viewportController.apply(
          query,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        _viewport = viewport;
        // Paint area tracks the mirror grid when it lags viewport (e.g. during
        // a PTY drain) so the painter never clears more than it draws.
        final gridPaintW =
            _grid.columns > 0 ? _grid.columns * _metrics.width : 0.0;
        final gridPaintH =
            _grid.rows > 0 ? _grid.rows * _metrics.height : 0.0;
        final paintSize = Size(
          gridPaintW > 0
              ? gridPaintW.clamp(0.0, viewport.cellAreaWidth)
              : viewport.cellAreaWidth,
          gridPaintH > 0
              ? gridPaintH.clamp(0.0, viewport.cellAreaHeight)
              : viewport.cellAreaHeight,
        );
        _ensureAtlas(MediaQuery.devicePixelRatioOf(context));
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _reportCaretRectToIme());
        Widget tree = Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            onPointerPanZoomStart: (_) {
              _scrollController.onGestureStart();
              _panSamples.clear();
            },
            onPointerPanZoomUpdate: (e) {
              _recordPanSample(e.timeStamp, e.localPanDelta.dy);
              _scrollController.onPanDelta(
                dyPx: e.localPanDelta.dy,
                shiftHeld: HardwareKeyboard.instance.isShiftPressed,
              );
            },
            onPointerPanZoomEnd: (_) {
              _scrollController.startFling(
                velocityPxPerSec: _panReleaseVelocity(),
                deceleration: _kFlingDecelerationTouchpad,
                shiftHeld: HardwareKeyboard.instance.isShiftPressed,
                createTicker: createTicker,
              );
              _panSamples.clear();
            },
            child: SizedBox.expand(
              child: MouseRegion(
                cursor: _hoverCursor,
                onEnter: _onGridMouseEnter,
                onExit: _onGridMouseExit,
                onHover: (e) => _updateHoverCursor(e.localPosition),
                child: Stack(
              children: [
                Positioned(
                  left: viewport.paddingX,
                  top: viewport.paddingY,
                  width: paintSize.width,
                  height: paintSize.height,
                  child: GestureDetector(
              supportedDevices: const {PointerDeviceKind.touch},
              behavior: HitTestBehavior.translucent,
              onTapDown: (_) => _scrollController.stopFling(),
              onTap: _onTouchTap,
              onVerticalDragStart: (_) => _scrollController.onGestureStart(),
              onVerticalDragUpdate: (e) => _scrollController.onPanDelta(
                dyPx: e.delta.dy,
                shiftHeld: HardwareKeyboard.instance.isShiftPressed,
              ),
              onVerticalDragEnd: _onVerticalDragEnd,
              onLongPressStart: _onLongPressStart,
              onLongPressMoveUpdate: _onLongPressMoveUpdate,
              onLongPressEnd: _onLongPressEnd,
              child: Stack(
                children: [
                  // Grid layer: repaints only on grid mutation. Its own
                  // RepaintBoundary keeps its raster isolated so the cursor /
                  // bell / preedit layers above don't dirty it, and vice versa.
                  RepaintBoundary(
                    child: CustomPaint(
                      size: paintSize,
                      isComplex: true,
                      willChange: true,
                      painter: TerminalPainter(
                        grid: _grid,
                        glyphs: _glyphs,
                        cellWidth: _metrics.width,
                        cellHeight: _metrics.height,
                        selectionColor:
                            0x55000000 | (widget.theme.selection & 0xFFFFFF),
                        searchColors: SearchColors(
                          matchBg: widget.theme.searchMatch.bg,
                          matchFg: widget.theme.searchMatch.fg,
                          focusedBg: widget.theme.searchFocused.bg,
                          focusedFg: widget.theme.searchFocused.fg,
                        ),
                        hintColors: HintColors(
                          bg: widget.theme.hintStart.bg,
                          fg: widget.theme.hintStart.fg,
                        ),
                        linkOverlay: _linkOverlay,
                        atlas: _atlas,
                        backgroundOpacity: widget.backgroundOpacity,
                      ),
                    ),
                  ),
                  // Cursor layer: a single cell, on its own RepaintBoundary, so
                  // the blink timer re-rasters only the cursor — not the grid.
                  IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: paintSize,
                        willChange: true,
                        painter: CursorPainter(
                          grid: _grid,
                          glyphs: _glyphs,
                          cellWidth: _metrics.width,
                          cellHeight: _metrics.height,
                          blinkOn: _blinkOn,
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: FadeTransition(
                      opacity: _bellCtrl,
                      child: ColoredBox(
                          color: Color(0xFF000000 | widget.theme.bellOverlay)),
                    ),
                  ),
                  if (_preedit != null && _preedit!.isNotEmpty)
                    PreeditOverlay(
                      text: _preedit!,
                      cursorRect: Rect.fromLTWH(
                        _grid.cursorCol * _metrics.width,
                        _grid.cursorRow * _metrics.height,
                        _metrics.width,
                        _metrics.height,
                      ),
                      bg: widget.preeditBg,
                      fg: widget.preeditFg,
                      underline: widget.preeditUnderline,
                      textStyle: _style,
                    ),
                ],
              ),
            ),
          ),
        ],
            ),
            ),
            ),
        );
        if (widget.padding != null) {
          tree = Padding(padding: widget.padding!, child: tree);
        }
        // Build the merged actions map: view-internal defaults (which
        // wire zoom into `_setZoom` and supply self-contained Copy + Paste)
        // overlayed by any host-supplied `widget.actions` so the host can
        // override Copy/Paste/ToggleSearch while leaving zoom to the view.
        // Per-type override; no per-Intent fallthrough.
        final mergedActions = <Type, Action<Intent>>{
          ...defaultTerminalActions(
            controller: _controller,
            engine: _engine,
            onSetZoom: _setZoom,
            baselineFontSize: widget.textStyle.size,
            currentFontSize: () => _fontSize,
          ),
          ...?widget.actions,
        };
        // Wrap order:  Shortcuts ▸ Actions ▸ Focus ▸ tree.
        // The inner Focus is the actual focused widget; key events propagate
        // BOTTOM-UP, so we have to match the activator list ourselves in
        // `_onKeyFallback` and dispatch via `Actions.maybeInvoke` (which
        // walks UP to the ancestor `Actions` widget) before falling through
        // to the encodeKey path. If we let the encodeKey run unconditionally,
        // chords like Ctrl+Shift+F would also produce the 0x06 control byte.
        return Shortcuts(
          shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
          child: Actions(
            actions: mergedActions,
            child: Focus(
              focusNode: _focus,
              autofocus: widget.autofocus,
              onKeyEvent: _onKeyFallback,
              child: tree,
            ),
          ),
        );
      },
    );
  }

  /// Returns keyboard focus to this terminal (e.g. after a context menu closes).
  void requestTerminalFocus() {
    if (!_focus.hasFocus) {
      _focus.requestFocus();
    }
  }

  // Forwarders: extension methods in [terminal_view_pointer.dart] are not
  // resolved as instance members for private-name references in this class.
  void _onPointerDown(PointerDownEvent e) => __pointerOnDown(e);
  void _onPointerMove(PointerMoveEvent e) => __pointerOnMove(e);
  void _onPointerUp(PointerUpEvent e) => __pointerOnUp(e);
  void _onPointerSignal(PointerSignalEvent e) => __pointerOnSignal(e);
  void _onTouchTap() => __pointerOnTouchTap();
  void _onVerticalDragEnd(DragEndDetails e) => __pointerOnVerticalDragEnd(e);
  void _onLongPressStart(LongPressStartDetails e) => __pointerOnLongPressStart(e);
  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails e) =>
      __pointerOnLongPressMoveUpdate(e);
  void _onLongPressEnd(LongPressEndDetails e) => __pointerOnLongPressEnd(e);
}
