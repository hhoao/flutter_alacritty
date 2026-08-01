import 'package:flutter/foundation.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accessory keyboard types are exported from package root', () {
    expect(isTouchShell(platform: TargetPlatform.android), isTrue);
    expect(TerminalAccessoryLayout.serverBoxDualRow.rows, isNotEmpty);
    expect(ModifierLatch(), isA<ModifierLatch>());
  });
}
