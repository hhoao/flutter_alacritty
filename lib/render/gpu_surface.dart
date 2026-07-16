import 'package:flutter/foundation.dart';

/// Capability probe and attach lifecycle for the GPU texture present path.
///
/// [preferGpuSurface]:
/// - `null` — auto: probe once and use GPU when available
/// - `true` — force attempt (still runs [probe])
/// - `false` — force [CustomPainter] path; never probes
///
/// On probe/attach failure, latches [usePainterFallback] until [retry].
/// Task 10 wires the real Texture id; until then [gpuReady] marks a successful
/// probe so the view can keep the painter without inventing a fake textureId.
class GpuSurfaceController {
  GpuSurfaceController({
    this.preferGpuSurface,
    Future<bool> Function()? probe,
  }) : probe = probe ?? defaultProbe;

  /// Host preference: null=auto, true=force attempt, false=force painter.
  final bool? preferGpuSurface;

  /// Returns true when the embedder can register an external texture.
  final Future<bool> Function() probe;

  /// Latched after a failed probe/attach; cleared only by [retry].
  bool usePainterFallback = false;

  /// True after a successful [ensureAttached] (probe passed). Task 10 uses this
  /// to swap in [Texture]; until then the view keeps the painter.
  bool gpuReady = false;

  bool _loggedLatch = false;

  /// Default probe until Rust compositor registration exists (Task 10).
  static Future<bool> defaultProbe() async => false;

  /// Whether the view should prefer the GPU texture path (not painter).
  ///
  /// True only when preference allows GPU, latch is clear, and attach succeeded.
  bool get shouldUseGpuSurface =>
      preferGpuSurface != false && !usePainterFallback && gpuReady;

  /// Attempts attach via [probe]. Returns whether GPU path is ready.
  ///
  /// Failures latch [usePainterFallback] (logged once) until [retry].
  Future<bool> ensureAttached() async {
    if (preferGpuSurface == false) {
      return false;
    }
    if (usePainterFallback) {
      return false;
    }
    if (gpuReady) {
      return true;
    }

    bool ok;
    try {
      ok = await probe();
    } catch (e) {
      _latchFallback();
      return false;
    }
    if (!ok) {
      _latchFallback();
      return false;
    }
    gpuReady = true;
    return true;
  }

  /// Clears the fallback latch so the next [ensureAttached] re-probes.
  void retry() {
    usePainterFallback = false;
    gpuReady = false;
    _loggedLatch = false;
  }

  void _latchFallback() {
    usePainterFallback = true;
    gpuReady = false;
    if (!_loggedLatch) {
      _loggedLatch = true;
      debugPrint(
        'flutter_alacritty: GPU surface attach failed; '
        'latched CustomPainter fallback until retry()',
      );
    }
  }
}
