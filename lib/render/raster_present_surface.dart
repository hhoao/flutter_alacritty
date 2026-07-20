import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../debug/terminal_scroll_latency.dart';
import '../src/rust/terminal_raster_present.dart';

/// Holds the retained [ui.Image] uploaded from Rust RGBA frames.
///
/// This is the MVP "Rust raster present" path — not a Flutter external
/// [Texture]. Cursor stays on [CursorPainter] above this image.
class RasterPresentSurface extends ChangeNotifier {
  ui.Image? _image;
  int _generation = 0;
  int _presentSeq = 0;
  int? _inflightSeq;
  RasterPresentFrame? _pending;
  bool _notifyScheduled = false;
  bool _disposed = false;

  ui.Image? get image => _image;
  int get generation => _generation;

  /// Decode [frame.rgba] into a retained image (replaces the previous one).
  ///
  /// Latest-wins: if a decode is already in flight, keep only the newest
  /// pending frame so TUI scroll floods do not queue N RGBA uploads.
  Future<void> present(RasterPresentFrame frame) async {
    if (_disposed) return;
    if (frame.width <= 0 || frame.height <= 0 || frame.rgba.isEmpty) {
      return;
    }
    final seq = ++_presentSeq;
    if (_inflightSeq != null) {
      _pending = frame;
      return;
    }
    await _decodeAndCommit(frame, seq);
  }

  Future<void> _decodeAndCommit(RasterPresentFrame frame, int seq) async {
    _inflightSeq = seq;
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final next = await completer.future;
      if (_disposed) {
        next.dispose();
        return;
      }
      // Drop superseded decodes (a newer present started after we queued).
      if (seq != _presentSeq && _pending == null) {
        next.dispose();
        return;
      }
      _image?.dispose();
      _image = next;
      _generation++;
      TerminalScrollLatency.markGridOrTextureUpdated(_generation);
      _scheduleNotify();
    } finally {
      _inflightSeq = null;
      final pending = _pending;
      _pending = null;
      if (!_disposed && pending != null) {
        final nextSeq = ++_presentSeq;
        await _decodeAndCommit(pending, nextSeq);
      }
    }
  }

  void _scheduleNotify() {
    if (_disposed) return;
    try {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      final binding = SchedulerBinding.instance;
      binding.scheduleFrameCallback((_) {
        _notifyScheduled = false;
        if (_disposed) return;
        notifyListeners();
      });
      binding.scheduleFrame();
    } on Object {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Synchronous present for tests that inject a pre-decoded image.
  @visibleForTesting
  void presentImageForTest(ui.Image image) {
    _image?.dispose();
    _image = image;
    _generation++;
    TerminalScrollLatency.markGridOrTextureUpdated(_generation);
    _scheduleNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}

/// Paints the retained raster image (no per-cell MirrorGrid loop).
class RasterPresentPainter extends CustomPainter {
  RasterPresentPainter({
    required this.surface,
    required this.logicalSize,
  }) : super(repaint: surface);

  final RasterPresentSurface surface;
  final Size logicalSize;

  @override
  void paint(Canvas canvas, Size size) {
    final image = surface.image;
    if (image == null) return;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Offset.zero & (logicalSize == Size.zero ? size : logicalSize);
    canvas.drawImageRect(image, src, dst, Paint());
    // Why: latency stop = first raster present after scroll-echo texture update.
    TerminalScrollLatency.markPaintOrPresentComplete(surface.generation);
  }

  @override
  bool shouldRepaint(covariant RasterPresentPainter oldDelegate) =>
      oldDelegate.surface != surface ||
      oldDelegate.logicalSize != logicalSize ||
      oldDelegate.surface.generation != surface.generation;
}
