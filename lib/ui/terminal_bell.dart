import 'package:flutter/services.dart';

/// Audible + optional visual reaction to an engine bell event.
///
/// Keeps [SystemSound] when [onBell] is null; visual flash only when
/// [bellDuration] is greater than zero.
void handleTerminalBell({
  required void Function()? onBell,
  required Duration bellDuration,
  required void Function(Duration duration) flashVisual,
}) {
  if (onBell != null) {
    onBell();
  } else {
    SystemSound.play(SystemSoundType.alert);
  }
  if (bellDuration > Duration.zero) {
    flashVisual(bellDuration);
  }
}
