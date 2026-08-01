import 'package:flutter/foundation.dart';
import 'package:flutter_alacritty/input/touch_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('android and iOS are touch shells', () {
    expect(isTouchShell(platform: TargetPlatform.android), isTrue);
    expect(isTouchShell(platform: TargetPlatform.iOS), isTrue);
    expect(isTouchShell(platform: TargetPlatform.linux), isFalse);
    expect(isTouchShell(platform: TargetPlatform.macOS), isFalse);
    expect(isTouchShell(platform: TargetPlatform.windows), isFalse);
  });
}
