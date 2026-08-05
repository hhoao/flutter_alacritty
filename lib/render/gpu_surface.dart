import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Capability probe and attach lifecycle for the GPU / Rust-raster present path.
///
/// [preferGpuSurface]:
/// - `null` — auto: probe once and use GPU/raster when available
/// - `true` — force attempt (still runs [probe])
/// - `false` — force [CustomPainter] path; never probes
///
/// On probe/attach failure, latches [usePainterFallback] until [retry].
///
/// ## Embedder spike (Task 10)
///
/// True Flutter external [Texture] registration:
/// - **Linux:** `FlPixelBufferTexture` / `FlTextureGL` via `FlTextureRegistrar`
///   (GTK embedder).
/// - **macOS:** `FlutterTextureRegistry` + pixel-buffer or IOSurface texture.
/// - **Windows:** `FlutterDesktopTextureRegistrarRegisterExternalTexture`.
///
/// This package's `rust_lib_flutter_alacritty` is an `ffiPlugin` (cargokit-only
/// CMake/pod glue) with no texture-registrar hooks, and FRB does not expose
/// `TextureRegistry`. MVP therefore uses **Rust-raster present**: Rust fills a
/// retained RGBA pixmap; Dart uploads to `ui.Image` and draws it in a thin
/// [CustomPaint] (skips the MirrorGrid cell paint loop). Set [textureId] only
/// when a real external texture exists (`>= 0`); raster path keeps
/// [textureId] at `-1` and sets [gpuReady] so [shouldUseGpuSurface] is true.
class GpuSurfaceController {
  GpuSurfaceController({
    this.preferGpuSurface,
    Future<bool> Function()? probe,
  }) : probe = probe ?? defaultProbe;

  /// Host preference: null=auto, true=force attempt, false=force painter.
  final bool? preferGpuSurface;

  /// Returns true when Rust-raster present (or a future Texture) can attach.
  final Future<bool> Function() probe;

  /// Latched after a failed probe/attach; cleared only by [retry].
  bool usePainterFallback = false;

  /// True after a successful [ensureAttached] (probe passed).
  bool gpuReady = false;

  /// External Flutter texture id when registered; `-1` means Rust-raster
  /// `ui.Image` path (not a real [Texture] widget).
  int textureId = -1;

  bool _loggedLatch = false;

  /// Sync env check for auto mode — avoids `await` mis-attributing later sync
  /// work (layout / IME) to [ensureAttached] wall-clock.
  static bool envGpuEnabled() {
    if (kIsWeb) return false;
    try {
      return Platform.environment['FLUTTER_ALACRITTY_GPU'] == '1';
    } on Object {
      return false;
    }
  }

  /// Probe: `FLUTTER_ALACRITTY_GPU=1`. Default auto without the env var stays
  /// false so widget tests keep the painter.
  static Future<bool> defaultProbe() async => envGpuEnabled();

  /// Whether the view should prefer the GPU/raster path (not cell painter).
  ///
  /// True when preference allows GPU, latch is clear, and attach succeeded.
  /// Real [Texture] requires [textureId] `>= 0`; raster path uses `-1` with
  /// [gpuReady] and draws via [RasterPresentPainter].
  bool get shouldUseGpuSurface =>
      preferGpuSurface != false && !usePainterFallback && gpuReady;

  /// True when using Rust-raster → `ui.Image` (not an external Texture id).
  bool get useRasterPresent => shouldUseGpuSurface && textureId < 0;

  /// Attempts attach via [probe]. Returns whether GPU/raster path is ready.
  ///
  /// Thrown probe errors latch [usePainterFallback] until [retry]. A soft
  /// `false` from the probe (env unset / not available) does **not** latch —
  /// auto mode stays on the painter without a scary "attach failed" log.
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
      _latchFallback('probe threw: $e');
      return false;
    }
    if (!ok) {
      // Forced prefer must latch; auto soft-decline stays retryable.
      if (preferGpuSurface == true) {
        _latchFallback('forced probe returned false');
      }
      return false;
    }
    gpuReady = true;
    // MVP: no TextureRegistrar — raster present uses textureId == -1.
    textureId = -1;
    return true;
  }

  /// Clears the fallback latch so the next [ensureAttached] re-probes.
  void retry() {
    usePainterFallback = false;
    gpuReady = false;
    textureId = -1;
    _loggedLatch = false;
  }

  void _latchFallback([String? reason]) {
    usePainterFallback = true;
    gpuReady = false;
    textureId = -1;
    if (!_loggedLatch) {
      _loggedLatch = true;
      final detail = reason == null ? '' : ' ($reason)';
      debugPrint(
        'flutter_alacritty: GPU surface unavailable$detail; '
        'latched CustomPainter fallback until retry()',
      );
    }
  }
}
