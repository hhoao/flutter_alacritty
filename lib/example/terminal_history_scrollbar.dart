import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../debug/terminal_scroll_trace.dart';
import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/term_mode.dart';
import 'terminal_scrollbar_geometry.dart';

/// Example-only scrollbar mapped like VTE + GtkAdjustment (not library API).
class TerminalHistoryScrollbar extends StatefulWidget {
  const TerminalHistoryScrollbar({
    required this.engine,
    required this.controller,
    super.key,
  });

  final TerminalEngine engine;
  final TerminalController controller;

  @override
  State<TerminalHistoryScrollbar> createState() =>
      _TerminalHistoryScrollbarState();
}

class _TerminalHistoryScrollbarState extends State<TerminalHistoryScrollbar> {
  bool _dragging = false;
  double? _dragPositionFraction;
  double _lastScrollPos = 0;
  int _lastHistorySize = 0;
  int _lastModeFlags = 0;

  /// Coalesce rapid drag events: only the latest target is applied.
  double? _pendingPositionFraction;
  bool _scrollInFlight = false;
  int _scrollGeneration = 0;

  /// Coalesce repaint-driven setState to at most once per frame.
  bool _frameRebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    final grid = widget.engine.grid;
    _lastScrollPos = grid.displayOffset + grid.scrollFraction;
    _lastHistorySize = grid.historySize;
    _lastModeFlags = grid.modeFlags;
    widget.engine.repaint.addListener(_onGridChanged);
  }

  @override
  void didUpdateWidget(covariant TerminalHistoryScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.repaint.removeListener(_onGridChanged);
      widget.engine.repaint.addListener(_onGridChanged);
      final grid = widget.engine.grid;
      _lastScrollPos = grid.displayOffset + grid.scrollFraction;
      _lastHistorySize = grid.historySize;
      _lastModeFlags = grid.modeFlags;
    }
  }

  @override
  void dispose() {
    widget.engine.repaint.removeListener(_onGridChanged);
    super.dispose();
  }

  void _onGridChanged() {
    if (!mounted || _dragging) return;
    final grid = widget.engine.grid;
    final scrollPos = grid.displayOffset + grid.scrollFraction;
    if (scrollPos == _lastScrollPos &&
        grid.modeFlags == _lastModeFlags &&
        grid.historySize == _lastHistorySize) {
      return;
    }
    _lastScrollPos = scrollPos;
    _lastHistorySize = grid.historySize;
    _lastModeFlags = grid.modeFlags;
    // Why: wheel/TUI bursts notify many times per frame; one setState per
    // notification rebuilds the track without moving the thumb more than once.
    if (_frameRebuildScheduled) return;
    _frameRebuildScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameRebuildScheduled = false;
      if (mounted && !_dragging) setState(() {});
    });
  }

  TerminalScrollbarGeometry _geometry(double trackHeight) {
    final grid = widget.engine.grid;
    return TerminalScrollbarGeometry(
      historySize: grid.historySize,
      viewportRows: grid.rows,
      scrollOffsetLines: grid.displayOffset + grid.scrollFraction,
      trackHeight: trackHeight,
    );
  }

  Future<void> _scrollToPositionFraction(double positionFraction) async {
    final grid = widget.engine.grid;
    final historySize = grid.historySize;
    if (historySize <= 0) return;

    final geom = TerminalScrollbarGeometry(
      historySize: historySize,
      viewportRows: grid.rows,
      scrollOffsetLines: 0,
      trackHeight: 1,
    );

    if (geom.isNearLiveBottom(positionFraction)) {
      TerminalScrollTrace.log(
        'scrollbar',
        'snap→bottom fraction=${positionFraction.toStringAsFixed(3)} '
        '${_posSnapshot(grid)}',
      );
      await widget.controller.scrollToBottom();
      return;
    }
    if (geom.isNearHistoryTop(positionFraction)) {
      TerminalScrollTrace.log(
        'scrollbar',
        'snap→top fraction=${positionFraction.toStringAsFixed(3)} '
        '${_posSnapshot(grid)}',
      );
      await widget.controller.scrollToTop();
      return;
    }

    final target = geom.scrollOffsetForPosition(positionFraction);
    TerminalScrollTrace.log(
      'scrollbar',
      'scrollToOffset($target) fraction=${positionFraction.toStringAsFixed(3)} '
      '${_posSnapshot(grid)}',
    );
    await widget.controller.scrollToOffset(target);
  }

  String _posSnapshot(dynamic grid) => TerminalScrollTrace.pos(
        displayOffset: grid.displayOffset,
        scrollFraction: grid.scrollFraction,
        historySize: grid.historySize,
      );

  Future<void> _drainPendingScroll() async {
    if (_scrollInFlight) return;
    _scrollInFlight = true;
    try {
      while (_pendingPositionFraction != null) {
        final fraction = _pendingPositionFraction!;
        _pendingPositionFraction = null;
        final gen = ++_scrollGeneration;
        await _scrollToPositionFraction(fraction);
        if (gen != _scrollGeneration) return;
      }
    } finally {
      _scrollInFlight = false;
      if (_pendingPositionFraction != null) {
        await _drainPendingScroll();
      }
    }
  }

  void _onTrackPointer(double localDy, double trackHeight) {
    if (trackHeight <= 0) return;
    final geom = _geometry(trackHeight);
    if (!geom.visible) return;

    final positionFraction = TerminalScrollbarGeometry.positionFractionFromTrackDy(
      localDy: localDy,
      trackHeight: trackHeight,
      thumbHeight: geom.thumbHeight,
    );
    _pendingPositionFraction = positionFraction;
    if (_dragging) {
      _dragPositionFraction = positionFraction;
      setState(() {});
    }
    _drainPendingScroll();
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.engine.grid;
    if (grid.modeFlags & kModeAltScreen != 0) {
      return const SizedBox(width: 0);
    }
    if (grid.historySize <= 0) {
      return const SizedBox(width: 0);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        if (trackHeight <= 0) return const SizedBox(width: 0);

        final geom = _geometry(trackHeight);
        final thumbFraction = geom.positionFraction;
        final paintFraction = _dragPositionFraction ?? thumbFraction;
        final thumbTop = geom.thumbTopAt(paintFraction);
        final theme = ScrollbarTheme.of(context);
        final thickness = theme.thickness?.resolve({}) ?? 8.0;
        final radius = theme.radius ?? const Radius.circular(4);
        final trackColor =
            theme.trackColor?.resolve({}) ?? const Color(0x33FFFFFF);
        final thumbColor =
            theme.thumbColor?.resolve({}) ?? const Color(0x99FFFFFF);

        return SizedBox(
          width: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) {
              _scrollGeneration++;
              widget.engine.cancelCoalescedScrollInput();
              _dragging = true;
              _dragPositionFraction = null;
            },
            onVerticalDragEnd: (_) {
              _dragging = false;
              _dragPositionFraction = null;
              setState(() {});
            },
            onVerticalDragCancel: () {
              _dragging = false;
              _dragPositionFraction = null;
              setState(() {});
            },
            onVerticalDragUpdate: (d) =>
                _onTrackPointer(d.localPosition.dy, trackHeight),
            onTapDown: (d) {
              _scrollGeneration++;
              widget.engine.cancelCoalescedScrollInput();
              _onTrackPointer(d.localPosition.dy, trackHeight);
            },
            child: CustomPaint(
              painter: _ScrollbarPainter(
                thumbTop: thumbTop,
                thumbHeight: geom.thumbHeight,
                trackWidth: thickness,
                radius: radius,
                trackColor: trackColor,
                thumbColor: thumbColor,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

class _ScrollbarPainter extends CustomPainter {
  _ScrollbarPainter({
    required this.thumbTop,
    required this.thumbHeight,
    required this.trackWidth,
    required this.radius,
    required this.trackColor,
    required this.thumbColor,
  });

  final double thumbTop;
  final double thumbHeight;
  final double trackWidth;
  final Radius radius;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    final trackR = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - trackWidth - 2, 0, trackWidth, size.height),
      radius,
    );
    canvas.drawRRect(trackR, Paint()..color = trackColor);

    final thumbR = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width - trackWidth - 2,
        thumbTop,
        trackWidth,
        thumbHeight.clamp(0, size.height),
      ),
      radius,
    );
    canvas.drawRRect(thumbR, Paint()..color = thumbColor);
  }

  @override
  bool shouldRepaint(covariant _ScrollbarPainter old) =>
      old.thumbTop != thumbTop ||
      old.thumbHeight != thumbHeight ||
      old.trackWidth != trackWidth ||
      old.thumbColor != thumbColor ||
      old.trackColor != trackColor;
}
