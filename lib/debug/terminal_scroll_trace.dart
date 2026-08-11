import 'package:flutter/foundation.dart';

import 'scroll_trace_env_io.dart'
    if (dart.library.html) 'scroll_trace_env_stub.dart';

/// Scroll pipeline tracing. Enable any of:
/// - `FLUTTER_ALACRITTY_SCROLL_TRACE=true` (runtime env var, desktop)
/// - `flutter run --dart-define=TERMINAL_SCROLL_TRACE=true`
/// - `TerminalScrollTrace.enabled = true` in host `main()`
///
/// Note: `bool.fromEnvironment` only accepts the literal strings `"true"` /
/// `"false"` — `--dart-define=TERMINAL_SCROLL_TRACE=1` silently stays off.
class TerminalScrollTrace {
  TerminalScrollTrace._();

  static bool enabled = bool.fromEnvironment(
    'TERMINAL_SCROLL_TRACE',
    defaultValue: false,
  );

  static bool _runtimeEnabled() {
    if (kIsWeb) return false;
    try {
      return scrollTraceEnvValue() == 'true';
    } catch (_) {
      return false;
    }
  }

  static bool get active => enabled || _runtimeEnabled();

  static int _seq = 0;

  static void log(String component, String message) {
    if (!active) return;
    final n = ++_seq;
    debugPrint('[scroll#$n $component] $message');
  }

  static String pos({
    required int displayOffset,
    required double scrollFraction,
    required int historySize,
  }) =>
      'off=$displayOffset frac=${scrollFraction.toStringAsFixed(3)} '
      'pos=${(displayOffset + scrollFraction).toStringAsFixed(3)} hist=$historySize';
}
