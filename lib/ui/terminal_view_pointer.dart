part of 'terminal_view.dart';

/// Pointer, scroll, fling, and selection hit-testing for [TerminalViewState].
extension _TerminalViewPointer on TerminalViewState {
  (int, int, bool) _cellAt(Offset local, {bool inCellLayer = false}) {
    final vp = _viewport;
    final cellLocal = (!inCellLayer && vp != null)
        ? Offset(local.dx - vp.paddingX, local.dy - vp.paddingY)
        : local;
    final maxCol = _grid.columns > 0 ? _grid.columns - 1 : 0;
    final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
    final col = (cellLocal.dx / _metrics.width).floor().clamp(0, maxCol);
    final yRows = cellLocal.dy / _metrics.height - _grid.scrollFraction;
    final row = yRows.floor().clamp(0, maxRow);
    final rightHalf = (cellLocal.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  /// Whether [local] (listener or cell-layer coords) lies over painted cells.
  bool _pointerOverCells(Offset local, {bool inCellLayer = false}) {
    final vp = _viewport;
    if (vp == null) return true;
    if (inCellLayer) {
      return local.dx >= 0 &&
          local.dy >= 0 &&
          local.dx < vp.cellAreaWidth &&
          local.dy < vp.cellAreaHeight;
    }
    return vp.cellRect.contains(local);
  }

  void _updateHoverCursor(Offset local, {bool inCellLayer = false}) {
    final (r, c, _) = _cellAt(local, inCellLayer: inCellLayer);
    final inBounds = _grid.rows > r && _grid.columns > c;
    if (inBounds) {
      _onHoverRowChanged(r);
    }
    final isLink = inBounds &&
        (isHyperlink(_grid.flagsAt(r, c)) ||
            (widget.linkProviders.isNotEmpty && _linkOverlay.isLinkCell(r, c)));
    final next = hoverCursorFor(
      hyperlink: isLink,
      modeFlags: _grid.modeFlags,
      base: widget.mouseCursor,
    );
    if (next != _hoverCursor) {
      // ignore: invalid_use_of_protected_member
      setState(() => _hoverCursor = next);
    }
  }

  void _refreshSelection() => _engine.refreshView();

  void _reportMouse(Offset local, int button, MouseAction action) {
    if (!_pointerOverCells(local)) return;
    final vp = _viewport;
    final cellLocal = vp != null
        ? Offset(local.dx - vp.paddingX, local.dy - vp.paddingY)
        : local;
    final maxCol = _grid.columns > 0 ? _grid.columns - 1 : 0;
    final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
    final col = (cellLocal.dx / _metrics.width).floor().clamp(0, maxCol) + 1;
    final row = (cellLocal.dy / _metrics.height).floor().clamp(0, maxRow) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _writeToEngine(bytes);
  }

  int _btn(int buttons) => (buttons & kSecondaryButton) != 0
      ? 2
      : (buttons & kMiddleMouseButton) != 0
          ? 1
          : 0;

  /// Record a trackpad pan sample and trim to the trailing velocity window.
  void _recordPanSample(Duration t, double dy) {
    _panSamples.add((t, dy));
    final cutoff = t - const Duration(milliseconds: _kVelocityWindowMs);
    while (_panSamples.length > 1 && _panSamples.first.$1 < cutoff) {
      _panSamples.removeAt(0);
    }
  }

  /// Release velocity (px/s) over the trailing window, matching swipeTracker's
  /// `calculateVelocity`: total delta after the first sample / elapsed period.
  double _panReleaseVelocity() {
    if (_panSamples.length < 2) return 0;
    final periodMs =
        (_panSamples.last.$1 - _panSamples.first.$1).inMicroseconds / 1000.0;
    if (periodMs <= 0) return 0;
    var total = 0.0;
    for (var i = 1; i < _panSamples.length; i++) {
      total += _panSamples[i].$2;
    }
    return total / periodMs * 1000.0;
  }

  void __pointerOnDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _focus.requestFocus();
    _linkActivatedOnDown = false;
    final hw = HardwareKeyboard.instance;
    // Left-click on a link cell → host launches URI. Always on Ctrl/Cmd-click;
    // also on a plain click when [primaryTapActivatesLink] is set (Shift still
    // forces selection). Non-link cells fall through to normal handling, so
    // they keep selecting / reporting to the program.
    final wantLinkActivate = e.buttons & kPrimaryButton != 0 &&
        (hw.isControlPressed ||
            hw.isMetaPressed ||
            (widget.primaryTapActivatesLink && !hw.isShiftPressed));
    if (wantLinkActivate) {
      final (r, c, _) = _cellAt(e.localPosition);
      final uri = _engine.hyperlinkAt(r, c);
      if (uri != null) {
        _linkActivatedOnDown = true;
        widget.onLinkActivate?.call(uri);
        return;
      }
      final payload = _payloadAt(r, c);
      if (payload != null) {
        _linkActivatedOnDown = true;
        widget.onLinkActivate?.call(payload);
        return;
      }
    }
    final localSelect = !anyMouse(_grid.modeFlags) || hw.isShiftPressed;
    if (localSelect && e.buttons & kPrimaryButton != 0) {
      _stopSelectionAutoScroll();
      final now = DateTime.now();
      _clickCount = (now.difference(_lastClick) < widget.doubleClickThreshold)
          ? (_clickCount % 3) + 1
          : 1;
      _lastClick = now;
      final (r, c, rh) = _cellAt(e.localPosition);
      if (widget.onTapDown != null) {
        widget.onTapDown!(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          CellOffset(r, c),
        );
      }
      _controller.selectionStart(r, c, rh, _clickCount - 1);
      _selecting = true;
      _refreshSelection();
      return;
    }
    if (!anyMouse(_grid.modeFlags) &&
        e.buttons & kMiddleMouseButton != 0 &&
        _controller.primary.isNotEmpty) {
      _onTerminalInputStart();
      _writeToEngine(
          pasteBytes(_controller.primary, modeFlags: _grid.modeFlags));
      return;
    }
    if (e.buttons & kSecondaryButton != 0 && !hw.isShiftPressed) {
      // Track this as a pending secondary tap so [_onPointerUp] can fire
      // `onSecondaryTapUp` on real release — fixes the press-time double-fire
      // caught in review. `onSecondaryTapDown` still fires immediately on
      // press; `onSecondaryTapUp` waits for the release event.
      final (r, c, _) = _cellAt(e.localPosition);
      _secondaryDownCell = CellOffset(r, c);
      _secondaryDownLocal = e.localPosition;
      _secondaryDownGlobal = e.position;
      if (widget.onSecondaryTapDown != null) {
        widget.onSecondaryTapDown!(
          TapDownDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          _secondaryDownCell!,
        );
      }
      return;
    }
    _pressedButton = _btn(e.buttons);
    _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
  }

  void __pointerOnMove(PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    // A link-activating press is in flight; don't report drag to the program.
    if (_linkActivatedOnDown) return;
    if (_selecting) {
      _updateSelectionDrag(e.localPosition);
      return;
    }
    if (e.buttons == 0) {
      if ((_grid.modeFlags & kModeMouseMotion) == 0) return;
      _reportMouse(e.localPosition, 3, MouseAction.move);
    } else {
      _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.move);
    }
  }

  void __pointerOnUp(PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    // The press activated a link and was not reported to the program; swallow
    // the release too so the program doesn't see a phantom click.
    if (_linkActivatedOnDown) {
      _linkActivatedOnDown = false;
      return;
    }
    // Drain a pending secondary press. Use the down-time cell so the
    // callback reports where the right click started, matching the
    // GestureDetector.onSecondaryTapUp convention.
    if (_secondaryDownCell != null) {
      final downCell = _secondaryDownCell!;
      final downLocal = _secondaryDownLocal ?? e.localPosition;
      final downGlobal = _secondaryDownGlobal ?? e.position;
      _secondaryDownCell = null;
      _secondaryDownLocal = null;
      _secondaryDownGlobal = null;
      if (widget.onSecondaryTapUp != null) {
        widget.onSecondaryTapUp!(
          TapUpDetails(
            globalPosition: downGlobal,
            localPosition: downLocal,
            kind: e.kind,
          ),
          downCell,
        );
      }
      return;
    }
    if (_selecting) {
      _selecting = false;
      _stopSelectionAutoScroll();
      _controller.capturePrimary();
      if (widget.onTapUp != null) {
        final (r, c, _) = _cellAt(e.localPosition);
        widget.onTapUp!(
          TapUpDetails(
            globalPosition: e.position,
            localPosition: e.localPosition,
            kind: e.kind,
          ),
          CellOffset(r, c),
        );
      }
      return;
    }
    _reportMouse(e.localPosition, _pressedButton, MouseAction.up);
  }

  void __pointerOnSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    TerminalScrollTrace.log(
      'view',
      'PointerScrollEvent pos=${e.localPosition} delta=${e.scrollDelta}',
    );
    _scrollController.stopFling();
    final hw = HardwareKeyboard.instance;
    final (r, c, _) = _cellAt(e.localPosition);
    _scrollController.setWheelCell(col: c + 1, row: r + 1);
    _scrollController.onWheelSignal(
      dyPx: e.scrollDelta.dy,
      shiftHeld: hw.isShiftPressed,
      altHeld: hw.isAltPressed,
    );
  }

  void __pointerOnTouchTap() {
    _focus.requestFocus();
    _ime.ensureVisible();
    if (_controller.selectionActive) {
      _controller.clearSelection();
      _refreshSelection();
    }
  }

  void __pointerOnVerticalDragEnd(DragEndDetails e) {
    _scrollController.startFling(
      velocityPxPerSec: e.primaryVelocity ?? 0,
      deceleration: _kFlingDecelerationTouch,
      shiftHeld: false,
      createTicker: createTicker,
    );
  }

  void __pointerOnLongPressStart(LongPressStartDetails e) {
    _scrollController.stopFling();
    _focus.requestFocus();
    final (r, c, rh) = _cellAt(e.localPosition, inCellLayer: true);
    _controller.selectionStart(r, c, rh, 0);
    _selecting = true;
    _refreshSelection();
  }

  void __pointerOnLongPressMoveUpdate(LongPressMoveUpdateDetails e) {
    final (r, c, rh) = _cellAt(e.localPosition, inCellLayer: true);
    _controller.selectionUpdate(r, c, rh);
    _refreshSelection();
  }

  void __pointerOnLongPressEnd(LongPressEndDetails e) {
    _selecting = false;
    _controller.capturePrimary();
  }

  /// Move the drag-selection endpoint to [local] (listener coords), and when
  /// the pointer leaves the cell area vertically, keep scrolling the viewport
  /// in that direction so the selection can grow past the window edge
  /// (alacritty desktop drag-selection parity). The mirror grid is repainted
  /// on every move so the highlight follows without waiting for engine damage.
  void _updateSelectionDrag(Offset local) {
    final vp = _viewport;
    final cellLocal = vp == null
        ? local
        : Offset(local.dx - vp.paddingX, local.dy - vp.paddingY);
    final maxCol = _grid.columns > 0 ? _grid.columns - 1 : 0;
    final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
    final col = (cellLocal.dx / _metrics.width).floor().clamp(0, maxCol);
    final yRows = cellLocal.dy / _metrics.height - _grid.scrollFraction;
    final rawRow = yRows.floor();
    // Outside the cell area vertically → hold that direction to auto-scroll.
    final direction = rawRow < 0
        ? -1
        : rawRow > maxRow
            ? 1
            : 0;
    final row = rawRow.clamp(0, maxRow);
    final rightHalf = (cellLocal.dx / _metrics.width) - col > 0.5;
    _selectionScrollCol = col;
    _selectionScrollRightHalf = rightHalf;
    _syncSelectionAutoScroll(direction);
    _controller.selectionUpdate(row, col, rightHalf);
    _refreshSelection();
  }

  void _syncSelectionAutoScroll(int direction) {
    if (direction == _selectionScrollDirection) return;
    _stopSelectionAutoScroll();
    if (direction != 0) _startSelectionAutoScroll(direction);
  }

  void _startSelectionAutoScroll(int direction) {
    _selectionScrollDirection = direction;
    _selectionScrollTimer = Timer.periodic(
      const Duration(milliseconds: 30),
      (_) => unawaited(_selectionAutoScrollTick()),
    );
  }

  void _stopSelectionAutoScroll() {
    _selectionScrollTimer?.cancel();
    _selectionScrollTimer = null;
    _selectionScrollDirection = 0;
    _selectionScrollInFlight = false;
  }

  Future<void> _selectionAutoScrollTick() async {
    if (_selectionScrollInFlight) return;
    if (!_selecting) {
      _stopSelectionAutoScroll();
      return;
    }
    _selectionScrollInFlight = true;
    try {
      final grid = _grid;
      // Scrolling up into history is a positive display delta; down toward
      // live bottom is negative. No-op at the buffer edges.
      final delta = _selectionScrollDirection < 0
          ? (grid.displayOffset >= grid.historySize ? 0 : 1)
          : (grid.displayOffset <= 0 ? 0 : -1);
      if (delta == 0) return;
      await _engine.scrollLines(delta);
      if (!_selecting || _selectionScrollDirection == 0) return;
      // Re-anchor the endpoint to the held edge row at the new viewport so the
      // drag keeps extending through the lines scrolled into view.
      final maxRow = _grid.rows > 0 ? _grid.rows - 1 : 0;
      final row = _selectionScrollDirection < 0 ? 0 : maxRow;
      _controller.selectionUpdate(
        row,
        _selectionScrollCol,
        _selectionScrollRightHalf,
      );
      _refreshSelection();
    } finally {
      _selectionScrollInFlight = false;
    }
  }
}
