import 'package:flutter/foundation.dart';

import '../engine/terminal_engine.dart';

/// View-model layer between the [TerminalEngine] and the widget tree.
///
/// Hosts state that was previously inline on the screen widget's state
/// (selection presence, primary-selection text, current search pattern and its
/// validity) and notifies listeners on every transition so the view can rebuild
/// the relevant slice without owning the state directly.
///
/// Lifecycle: the widget constructs a controller, calls [attach] once with its
/// [TerminalEngine], and calls [dispose] when tearing down. The controller
/// does NOT own the engine — disposal drops only its own ChangeNotifier
/// machinery and the engine reference; the widget remains responsible for
/// `engine.dispose()`.
///
/// UI-only state (e.g. search-bar visibility) stays on the widget; only
/// engine-coupled state lives here.
class TerminalController extends ChangeNotifier {
  TerminalEngine? _engine;
  TerminalEngine? get engine => _engine;

  /// Wire the controller to an engine. One-shot: re-attach without an
  /// intervening dispose is a programmer error.
  void attach(TerminalEngine engine) {
    assert(_engine == null, 'attach called twice');
    _engine = engine;
    // No notify — attach is the binding step, not a state change.
  }

  // ---- selection ----------------------------------------------------------

  /// Mirrors engine-side selection presence on the Dart side so the
  /// per-keystroke `selectionClear + full snapshot` only runs when there is
  /// something to clear (alacritty event.rs:on_terminal_input_start does the
  /// same — dirty bit is OR'd only when the taken selection was non-empty).
  bool _selectionActive = false;
  bool get selectionActive => _selectionActive;

  /// Middle-click paste buffer (the "primary selection"). Captured from the
  /// engine on selection end; consumed on middle-button paste.
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

  /// Gated to match alacritty event.rs:clear_selection — the FFI hop + full
  /// snapshot are skipped when there's nothing to clear.
  void clearSelection() {
    if (!_selectionActive) return;
    _engine?.selectionClear();
    _selectionActive = false;
    notifyListeners();
  }

  String? readSelectionText() => _engine?.selectionText();

  /// Snapshot the current engine selection into [primary]. Notifies only on
  /// change so a redundant capture (e.g. tap after a tap) doesn't churn the
  /// listener chain.
  void capturePrimary() {
    final t = _engine?.selectionText() ?? '';
    if (t != _primary) {
      _primary = t;
      notifyListeners();
    }
  }

  // ---- search ------------------------------------------------------------

  String _searchPattern = '';
  bool _searchValid = true;
  String get searchPattern => _searchPattern;
  bool get searchValid => _searchValid;

  /// Push a new pattern into the engine. Returns the engine's compile result;
  /// an empty pattern is always reported as valid (matches the UI's behavior
  /// for "no pattern → no error indicator").
  bool searchSet(String pattern) {
    _searchPattern = pattern;
    final ok = _engine?.searchSet(pattern) ?? false;
    _searchValid = ok || pattern.isEmpty;
    notifyListeners();
    return ok;
  }

  void searchNext() {
    _engine?.searchNext();
    notifyListeners();
  }

  void searchPrev() {
    _engine?.searchPrev();
    notifyListeners();
  }

  /// Gated: no-op when nothing is set. Prevents redundant engine work when
  /// the search bar is closed without ever having been used.
  void searchClear() {
    if (_searchPattern.isEmpty && _searchValid) return;
    _engine?.searchClear();
    _searchPattern = '';
    _searchValid = true;
    notifyListeners();
  }

  /// Mirror of alacritty `event.rs:on_terminal_input_start`. Call this from
  /// every "user just typed / pasted / dropped" entry point — the gates
  /// ensure no FFI snapshot fires when there's nothing to clear and the
  /// viewport is already at the bottom (this is the Plan 2L perf fix).
  ///
  /// Lives on the controller so all input drivers (view's keystroke path,
  /// `defaultPasteAction`, host-side paste / drop) share a single
  /// implementation and stay in lock-step.
  void onTerminalInputStart() {
    final engine = _engine;
    if (engine == null) return;
    final scrolledBack = engine.grid.displayOffset != 0;
    if (scrolledBack) {
      // fire-and-forget; engine.scrollToBottom internally calls refreshView
      // so we skip the separate refresh path below.
      engine.scrollToBottom();
    }
    if (_selectionActive) {
      engine.selectionClear();
      _selectionActive = false;
      if (!scrolledBack) engine.refreshView();
      notifyListeners();
    }
  }

  // ---- scroll ------------------------------------------------------------

  Future<void> scrollLines(int delta) async {
    await _engine?.scrollLines(delta);
    notifyListeners();
  }

  Future<void> scrollToBottom() async {
    await _engine?.scrollToBottom();
    notifyListeners();
  }

  @override
  void dispose() {
    // The controller does NOT own the engine — drop the reference so a
    // post-dispose access throws via the null check rather than touching a
    // disposed engine, but leave the engine alive for its real owner (the
    // widget) to tear down.
    _engine = null;
    super.dispose();
  }
}
