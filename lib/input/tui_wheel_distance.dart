import 'dart:math' as math;

import 'package:flutter_alacritty/input/tui_wheel_event.dart';

// Orca-parity constants from pane-terminal-tui-wheel-reports.ts
const double _kDiscretePixelWheelDeltaMin = 50;
const double _kLegacyMouseWheelDeltaMin = 100;
const double _kLegacyMouseWheelDeltaUnit = 120;
const double _kDefaultTerminalCellHeight = 16;
const double tuiWheelAcceleratedDistanceGain = 1.6;
const double tuiWheelBurstFullIntervalMs = 16;
const double tuiWheelBurstMaxIntervalMs = 45;
const double tuiWheelBurstMaxBonusRows = 3;
const int tuiWheelBurstRampEvents = 4;
const double tuiWheelMomentumTailDecayRatio = 0.85;
const double tuiWheelCompressedMaxDistanceRowsPerEvent = 6;
const double tuiWheelBurstMaxDistanceRowsPerEvent = 9;

const int tuiScrollSensitivityDefault = 1;
const int tuiScrollSensitivityMin = 1;
const int tuiScrollSensitivityMax = 10;

/// Mutable carry / burst state across successive TUI wheel events.
class TuiWheelDistanceState {
  int fastStreak = 0;
  double? lastDistanceRows;
  double? lastInputAt;
  int pendingDirection = 0; // -1 | 0 | 1
  double pendingRows = 0;
}

/// Clamp scroll sensitivity to the supported 1..10 report multiplier range.
int normalizeTuiScrollSensitivity(num? value) {
  if (value == null || !value.isFinite) {
    return tuiScrollSensitivityDefault;
  }
  final clamped = value
      .clamp(tuiScrollSensitivityMin, tuiScrollSensitivityMax)
      .toDouble();
  return clamped.round();
}

int _resolveWheelDirection(TuiWheelEvent event) => event.deltaY < 0 ? -1 : 1;

double? _legacyVerticalWheelDelta(TuiWheelEvent event) {
  final legacy = event.legacyWheelDeltaY;
  if (legacy != null && legacy.isFinite) return legacy;
  return null;
}

bool _hasDiscreteLegacyWheelDelta(TuiWheelEvent event) {
  final legacyDelta = _legacyVerticalWheelDelta(event);
  return legacyDelta != null && legacyDelta.abs() >= _kLegacyMouseWheelDeltaMin;
}

bool _isDiscreteTuiWheelEvent(TuiWheelEvent event) {
  if (event.deltaMode != TuiWheelDeltaMode.pixel) return true;
  if (event.deltaY.abs() >= _kDiscretePixelWheelDeltaMin) return true;
  return _hasDiscreteLegacyWheelDelta(event);
}

bool _canBurstBoostWheelEvent(TuiWheelEvent event) {
  if (event.deltaMode != TuiWheelDeltaMode.pixel) return true;
  return _hasDiscreteLegacyWheelDelta(event);
}

bool _isTrackpadLikePixelWheelEvent(TuiWheelEvent event) {
  return event.deltaMode == TuiWheelDeltaMode.pixel &&
      !_hasDiscreteLegacyWheelDelta(event);
}

double _normalizeCellHeight(double? cellHeight) {
  if (cellHeight != null && cellHeight.isFinite && cellHeight > 0) {
    return cellHeight;
  }
  return _kDefaultTerminalCellHeight;
}

double _resolveWheelDistanceRows(
  TuiWheelEvent event, {
  double? cellHeight,
  int? rows,
}) {
  final deltaY = event.deltaY.abs();
  final double rowsFromDelta;
  switch (event.deltaMode) {
    case TuiWheelDeltaMode.line:
      rowsFromDelta = deltaY;
    case TuiWheelDeltaMode.page:
      rowsFromDelta = deltaY * math.max(1, rows ?? 1);
    case TuiWheelDeltaMode.pixel:
      rowsFromDelta = deltaY / _normalizeCellHeight(cellHeight);
  }

  final legacyDelta = _legacyVerticalWheelDelta(event);
  final rowsFromLegacy =
      legacyDelta == null ? 0.0 : legacyDelta.abs() / _kLegacyMouseWheelDeltaUnit;
  final distance = math.max(rowsFromDelta, rowsFromLegacy);

  return _isDiscreteTuiWheelEvent(event) ? math.max(1.0, distance) : distance;
}

double _compressWheelDistanceRows(double rows) {
  if (rows <= 1) return rows;
  return math.min(
    tuiWheelCompressedMaxDistanceRowsPerEvent,
    1 + math.log(rows) / math.ln2 * tuiWheelAcceleratedDistanceGain,
  );
}

double _resolveBurstWheelDistanceRows(
  TuiWheelEvent event,
  TuiWheelDistanceState state,
  double distanceRows,
) {
  if (!_canBurstBoostWheelEvent(event)) {
    state.fastStreak = 0;
    state.lastDistanceRows = null;
    state.lastInputAt = null;
    return 0;
  }

  final currentInputAt = event.timeStampMs;
  if (currentInputAt == null || !currentInputAt.isFinite) {
    state.fastStreak = 0;
    state.lastDistanceRows = null;
    state.lastInputAt = null;
    return 0;
  }

  final elapsedMs =
      state.lastInputAt == null ? null : currentInputAt - state.lastInputAt!;
  final isMomentumTail = state.lastDistanceRows != null &&
      distanceRows < state.lastDistanceRows! * tuiWheelMomentumTailDecayRatio;
  state.lastDistanceRows = distanceRows;
  state.lastInputAt = currentInputAt;

  if (isMomentumTail ||
      elapsedMs == null ||
      elapsedMs < 0 ||
      elapsedMs > tuiWheelBurstMaxIntervalMs) {
    state.fastStreak = 0;
    return 0;
  }

  final cadence = elapsedMs <= tuiWheelBurstFullIntervalMs
      ? 1.0
      : (tuiWheelBurstMaxIntervalMs - elapsedMs) /
          (tuiWheelBurstMaxIntervalMs - tuiWheelBurstFullIntervalMs);
  state.fastStreak = math.min(tuiWheelBurstRampEvents, state.fastStreak + 1);

  return tuiWheelBurstMaxBonusRows *
      cadence *
      (state.fastStreak / tuiWheelBurstRampEvents);
}

int? _resolveTrackpadPixelWheelReportCount(
  TuiWheelEvent event,
  TuiWheelDistanceState state,
  double distanceRows,
) {
  if (!_isTrackpadLikePixelWheelEvent(event)) return null;

  // Why: trackpad pixel streams map 1:1 to physical distance — one report per
  // terminal row scrolled, fractional remainder carried. No per-event cap.
  final totalRows = state.pendingRows + distanceRows;
  final reports = totalRows.truncate();
  state.pendingRows = totalRows - reports;
  return reports;
}

/// Resolve how many TUI mouse-wheel reports to emit for [event].
///
/// Port of Orca `resolveTerminalTuiMouseWheelReportCount`.
int resolveTuiWheelReportCount(
  TuiWheelEvent event, {
  required num multiplier,
  required TuiWheelDistanceState state,
  double? cellHeight,
  int? rows,
}) {
  final direction = _resolveWheelDirection(event);
  if (state.pendingDirection != 0 && state.pendingDirection != direction) {
    state.fastStreak = 0;
    state.lastDistanceRows = null;
    state.lastInputAt = null;
    state.pendingRows = 0;
  }
  state.pendingDirection = direction;

  final distanceRows = _resolveWheelDistanceRows(
    event,
    cellHeight: cellHeight,
    rows: rows,
  );
  final trackpadReportCount =
      _resolveTrackpadPixelWheelReportCount(event, state, distanceRows);
  if (trackpadReportCount != null) {
    return trackpadReportCount;
  }

  final scaledRows = math.min(
        tuiWheelBurstMaxDistanceRowsPerEvent,
        _compressWheelDistanceRows(distanceRows) +
            _resolveBurstWheelDistanceRows(event, state, distanceRows),
      ) *
      normalizeTuiScrollSensitivity(multiplier);
  final totalRows = state.pendingRows + scaledRows;
  final reports = totalRows.truncate();
  state.pendingRows = totalRows - reports;
  return reports;
}
