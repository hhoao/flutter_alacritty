import 'package:flutter/foundation.dart';

bool isTouchShell({TargetPlatform? platform}) {
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.android || p == TargetPlatform.iOS;
}
