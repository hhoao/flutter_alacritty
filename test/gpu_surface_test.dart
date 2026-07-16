import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/render/gpu_surface.dart';

void main() {
  test('GpuSurfaceController latches painter fallback after attach failure',
      () async {
    final c = GpuSurfaceController(probe: () async => false);
    expect(await c.ensureAttached(), isFalse);
    expect(c.usePainterFallback, isTrue);
    expect(c.gpuReady, isFalse);
  });

  test('preferGpuSurface false never probes', () async {
    var probes = 0;
    final c = GpuSurfaceController(
      preferGpuSurface: false,
      probe: () async {
        probes++;
        return true;
      },
    );
    expect(await c.ensureAttached(), isFalse);
    expect(probes, 0);
    expect(c.gpuReady, isFalse);
    expect(c.usePainterFallback, isFalse);
  });

  test('retry clears latch and re-probes', () async {
    var probes = 0;
    final results = <bool>[false, true];
    final c = GpuSurfaceController(
      probe: () async {
        final i = probes++;
        return results[i];
      },
    );

    expect(await c.ensureAttached(), isFalse);
    expect(c.usePainterFallback, isTrue);
    expect(probes, 1);

    // Latched: further ensureAttached calls must not re-probe.
    expect(await c.ensureAttached(), isFalse);
    expect(probes, 1);

    c.retry();
    expect(c.usePainterFallback, isFalse);
    expect(c.gpuReady, isFalse);

    expect(await c.ensureAttached(), isTrue);
    expect(c.usePainterFallback, isFalse);
    expect(c.gpuReady, isTrue);
    expect(probes, 2);
  });

  test('successful probe sets gpuReady', () async {
    final c = GpuSurfaceController(probe: () async => true);
    expect(await c.ensureAttached(), isTrue);
    expect(c.gpuReady, isTrue);
    expect(c.usePainterFallback, isFalse);
  });

  test('preferGpuSurface true still probes', () async {
    var probes = 0;
    final c = GpuSurfaceController(
      preferGpuSurface: true,
      probe: () async {
        probes++;
        return false;
      },
    );
    expect(await c.ensureAttached(), isFalse);
    expect(probes, 1);
    expect(c.usePainterFallback, isTrue);
  });
}
