import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/ui/terminal_bell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('onBell spy is called when bell fires', () {
    var bells = 0;
    Duration? flashed;

    handleTerminalBell(
      onBell: () => bells++,
      bellDuration: const Duration(milliseconds: 50),
      flashVisual: (d) => flashed = d,
    );

    expect(bells, 1);
    expect(flashed, const Duration(milliseconds: 50));
  });

  test('duration zero does not flash visual', () {
    var bells = 0;
    var flashCalls = 0;

    handleTerminalBell(
      onBell: () => bells++,
      bellDuration: Duration.zero,
      flashVisual: (_) => flashCalls++,
    );

    expect(bells, 1);
    expect(flashCalls, 0);
  });

  test('null onBell plays SystemSound alert', () async {
    final played = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemSound.play') {
        played.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    handleTerminalBell(
      onBell: null,
      bellDuration: Duration.zero,
      flashVisual: (_) {},
    );

    expect(played, ['SystemSoundType.alert']);
  });
}
