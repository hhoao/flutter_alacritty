import 'dart:io';

/// Desktop/IO platforms: read the scroll-trace env var at runtime.
String? scrollTraceEnvValue() =>
    Platform.environment['FLUTTER_ALACRITTY_SCROLL_TRACE'];
