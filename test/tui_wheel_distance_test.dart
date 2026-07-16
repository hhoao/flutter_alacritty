import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/tui_wheel_distance.dart';
import 'package:flutter_alacritty/input/tui_wheel_event.dart';

void main() {
  test('normalizeTuiScrollSensitivity clamps 1..10', () {
    expect(normalizeTuiScrollSensitivity(null), 1);
    expect(normalizeTuiScrollSensitivity(0), 1);
    expect(normalizeTuiScrollSensitivity(4.4), 4);
    expect(normalizeTuiScrollSensitivity(20), 10);
  });

  test('trackpad pixel stream maps 1:1 with fractional carry', () {
    final state = TuiWheelDistanceState();
    // cellHeight 20 → 30px = 1.5 rows → 1 report, 0.5 remainder
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 30, deltaMode: TuiWheelDeltaMode.pixel),
        multiplier: 1,
        state: state,
        cellHeight: 20,
      ),
      1,
    );
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 10, deltaMode: TuiWheelDeltaMode.pixel),
        multiplier: 1,
        state: state,
        cellHeight: 20,
      ),
      1,
    ); // 0.5 + 0.5
  });

  test('direction change resets pending fractional rows', () {
    final state = TuiWheelDistanceState();
    resolveTuiWheelReportCount(
      TuiWheelEvent(deltaY: 15, deltaMode: TuiWheelDeltaMode.pixel),
      multiplier: 1,
      state: state,
      cellHeight: 20,
    );
    expect(state.pendingRows, greaterThan(0));
    resolveTuiWheelReportCount(
      TuiWheelEvent(deltaY: -1, deltaMode: TuiWheelDeltaMode.pixel),
      multiplier: 1,
      state: state,
      cellHeight: 20,
    );
    // After opposite direction, prior remainder must not leak into new direction
    expect(state.pendingDirection, -1);
  });

  test('discrete line mode emits at least one report', () {
    final state = TuiWheelDistanceState();
    expect(
      resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: 1, deltaMode: TuiWheelDeltaMode.line),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      ),
      greaterThanOrEqualTo(1),
    );
  });

  // --- Additional Orca-parity fixtures (burst / multiplier / trackpad) ---

  test('scales notched TUI wheel ticks by the configured multiplier', () {
    final state = TuiWheelDistanceState();
    final reports = [0, 50, 100, 150].map((_) {
      return resolveTuiWheelReportCount(
        TuiWheelEvent(
          deltaY: 12,
          deltaMode: TuiWheelDeltaMode.pixel,
          legacyWheelDeltaY: -120,
        ),
        multiplier: 5,
        state: state,
        cellHeight: 16,
      );
    }).toList();
    expect(reports, [5, 5, 5, 5]);
  });

  test('adds a burst boost for very fast 1x TUI wheel scrolling', () {
    final state = TuiWheelDistanceState();
    final reports = [0.0, 16.0, 32.0, 48.0, 64.0].map((timeStampMs) {
      return resolveTuiWheelReportCount(
        TuiWheelEvent(
          deltaY: 12,
          deltaMode: TuiWheelDeltaMode.pixel,
          legacyWheelDeltaY: -120,
          timeStampMs: timeStampMs,
        ),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      );
    }).toList();
    expect(reports, [1, 1, 3, 3, 4]);
  });

  test('retains fractional trackpad distance until a full row', () {
    final state = TuiWheelDistanceState();
    final reports = [4.0, 4.0, 4.0, 4.0].map((deltaY) {
      return resolveTuiWheelReportCount(
        TuiWheelEvent(deltaY: deltaY, deltaMode: TuiWheelDeltaMode.pixel),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      );
    }).toList();
    expect(reports, [0, 0, 0, 1]);
  });

  test('does not burst-boost rapid trackpad-like pixel deltas', () {
    final state = TuiWheelDistanceState();
    final reports = [0.0, 16.0, 32.0, 48.0].map((timeStampMs) {
      return resolveTuiWheelReportCount(
        TuiWheelEvent(
          deltaY: 4,
          deltaMode: TuiWheelDeltaMode.pixel,
          timeStampMs: timeStampMs,
        ),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      );
    }).toList();
    expect(reports, [0, 0, 0, 1]);
  });

  test('emits full linear distance for a fast trackpad-like flick', () {
    final state = TuiWheelDistanceState();
    final reports = [16.0 * 12, 16.0 * 12, 16.0 * 12]
        .asMap()
        .entries
        .map((e) {
      return resolveTuiWheelReportCount(
        TuiWheelEvent(
          deltaY: e.value,
          deltaMode: TuiWheelDeltaMode.pixel,
          timeStampMs: e.key * 16.0,
        ),
        multiplier: 1,
        state: state,
        cellHeight: 16,
      );
    }).toList();
    expect(reports, [12, 12, 12]);
  });
}
