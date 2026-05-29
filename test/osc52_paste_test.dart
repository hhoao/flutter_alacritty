import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/event_proxy.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

const _rustDir = 'packages/rust_lib_flutter_alacritty/rust';

String _rustLibFileName() {
  if (Platform.isWindows) return 'rust_lib_flutter_alacritty.dll';
  if (Platform.isMacOS) return 'librust_lib_flutter_alacritty.dylib';
  return 'librust_lib_flutter_alacritty.so';
}

Future<String> _findOrBuildLib() async {
  final name = _rustLibFileName();
  final built = '$_rustDir/target/debug/$name';
  if (!File(built).existsSync()) {
    final result =
        await Process.run('cargo', ['build'], workingDirectory: _rustDir);
    if (result.exitCode != 0) {
      fail('cargo build failed in $_rustDir: ${result.stderr}');
    }
  }
  if (!File(built).existsSync()) {
    fail('Rust lib not found at $built');
  }
  return built;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final lib = await _findOrBuildLib();
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File(lib).absolute.path),
    );
  });

  test('respondClipboardLoad sends encoded paste reply on output', () async {
    final config = TerminalConfig.defaults()
        .copyWith(
          terminal: const TerminalBehaviorConfig(osc52: Osc52Mode.copyPaste),
        )
        .engineConfig;
    final engine = engineNew(columns: 10, rows: 2, config: config);
    await engineAdvance(
      engine: engine,
      bytes: Uint8List.fromList(utf8.encode('\x1b]52;c;?\x07')),
    );
    final events = engineTakeEvents(engine: engine);
    expect(events.whereType<EngineEvent_ClipboardLoad>(), isNotEmpty);
    engineRespondClipboardLoad(engine: engine, text: 'hi');
    final reply = engineTakeEvents(engine: engine);
    final joined = reply
        .whereType<EngineEvent_PtyWrite>()
        .map((e) => utf8.decode(e.field0))
        .join();
    expect(joined.contains('52;c;'), isTrue);
    expect(joined.contains(base64.encode(utf8.encode('hi'))), isTrue);
  });
}
