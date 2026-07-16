import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../debug/terminal_scroll_latency.dart';
import '../src/rust/terminal_raster_present.dart';

/// Holds the retained [ui.Image] uploaded from Rust RGBA frames.
///
/// This is the MVP "Rust raster present" path — not a Flutter external
/// [Texture]. Cursor stays on [CursorPainter] above this image.
class RasterPresentSurface extends ChangeNotifier {
  ui.Image? _image;
  int _generation = 0;

  ui.Image? get image => _image;
  int get generation => _generation;

  /// Decode [frame.rgba] into a retained image (replaces the previous one).
  Future<void> present(RasterPresentFrame frame) async {
    if (frame.width <= 0 || frame.height <= 0 || frame.rgba.isEmpty) {
      return;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final next = await completer.future;
    _image?.dispose();
    _image = next;
    _generation++;
    TerminalScrollLatency.markGridOrTextureUpdated(_generation);
    notifyListeners();
  }

  /// Synchronous present for tests that inject a pre-decoded image.
  @visibleForTesting
  void presentImageForTest(ui.Image image) {
    _image?.dispose();
    _image = image;
    _generation++;
    TerminalScrollLatency.markGridOrTextureUpdated(_generation);
    notifyListeners();
  }

  @override
  void dispose() {
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
