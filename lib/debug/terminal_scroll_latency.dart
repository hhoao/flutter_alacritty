import 'package:flutter/foundation.dart';

import 'terminal_scroll_trace.dart';

/// One completed scheduleWrite → paint/present sample (microseconds).
@immutable
class TerminalScrollLatencySample {
  const TerminalScrollLatencySample({
    required this.startUs,
    required this.stopUs,
  });

  final int startUs;
  final int stopUs;

  int get elapsedUs => stopUs - startUs;
}

/// Program-scroll latency: enqueue → first paint after echo grid/texture update.
///
/// Enable with `--dart-define=TERMINAL_SCROLL_TRACE=1` or [harnessEnabled] in tests.
///
/// | Marker | When |
/// |--------|------|
/// | Start | [markScheduleWrite] — first program-scroll byte enqueue for a batch |
/// | Echo | [markGridOrTextureUpdated] — MirrorGrid/Texture generation after PTY echo |
/// | Stop | [markPaintOrPresentComplete] — paint/raster present for that generation |
class TerminalScrollLatency {
  TerminalScrollLatency._();

  /// Force measurement in tests without dart-define.
  static bool harnessEnabled = false;

  static bool get active => harnessEnabled || TerminalScrollTrace.enabled;

  static final List<TerminalScrollLatencySample> samples = [];

  static int? pendingStartUs;
  static int? pendingEchoGeneration;

  static void reset() {
    samples.clear();
    pendingStartUs = null;
    pendingEchoGeneration = null;
  }

  static int _nowUs() => DateTime.now().microsecondsSinceEpoch;

  /// Start: first program-scroll byte enqueue for a gesture batch.
  static void markScheduleWrite() {
    if (!active) return;
    // Coalesce: only the first enqueue of an in-flight measurement counts.
    if (pendingStartUs != null) return;
    pendingStartUs = _nowUs();
    pendingEchoGeneration = null;
    TerminalScrollTrace.log('latency', 'start us=$pendingStartUs');
  }

  /// PTY echo applied: pair the next MirrorGrid / texture generation bump.
  static void markGridOrTextureUpdated(int generation) {
    if (!active || pendingStartUs == null) return;
    if (pendingEchoGeneration != null) return;
    pendingEchoGeneration = generation;
    TerminalScrollTrace.log(
      'latency',
      'echo gen=$generation us=${_nowUs()}',
    );
  }

  /// Stop: paint or raster present completed for the paired echo generation.
  static void markPaintOrPresentComplete(int generation) {
    if (!active) return;
    final start = pendingStartUs;
    final echoGen = pendingEchoGeneration;
    if (start == null || echoGen == null) return;
    if (generation < echoGen) return;
    final stop = _nowUs();
    final sample = TerminalScrollLatencySample(startUs: start, stopUs: stop);
    samples.add(sample);
    TerminalScrollTrace.log(
      'latency',
      'stop gen=$generation elapsedUs=${sample.elapsedUs}',
    );
    pendingStartUs = null;
    pendingEchoGeneration = null;
  }
}
