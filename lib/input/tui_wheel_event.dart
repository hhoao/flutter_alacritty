/// Wheel delta units for TUI mouse-report scrolling (DOM WheelEvent parity).
enum TuiWheelDeltaMode { pixel, line, page }

/// Minimal wheel input for [resolveTuiWheelReportCount].
class TuiWheelEvent {
  const TuiWheelEvent({
    required this.deltaY,
    this.deltaMode = TuiWheelDeltaMode.pixel,
    this.timeStampMs,
    this.legacyWheelDeltaY,
  });

  final double deltaY;
  final TuiWheelDeltaMode deltaMode;
  final double? timeStampMs;

  /// Legacy `wheelDeltaY` / `wheelDelta` (IE/Chrome), when available.
  final double? legacyWheelDeltaY;
}
