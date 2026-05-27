import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/event_proxy.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

const _libName = 'librust_lib_flutter_alacritty.so';

/// Locations a built Rust cdylib may live, fastest/most-likely first.
const _candidates = [
  'build/linux/x64/release/bundle/lib/$_libName',
  'build/linux/x64/debug/bundle/lib/$_libName',
  'rust/target/release/$_libName',
  'rust/target/debug/$_libName',
];

/// Returns the path to a usable Rust lib, building it if none is present.
/// Never returns null silently — throws/fails so the FFI boundary is always
/// exercised (no false-green skip).
Future<String> _findOrBuildLib() async {
  for (final p in _candidates) {
    if (File(p).existsSync()) return p;
  }
  // No artifact yet: build it so this test actually runs.
  final result = await Process.run('cargo', ['build'], workingDirectory: 'rust');
  if (result.exitCode != 0) {
    fail('Failed to build the Rust lib for the FFI test '
        '(`cargo build` in rust/ exited ${result.exitCode}):\n${result.stderr}');
  }
  const built = 'rust/target/debug/$_libName';
  if (!File(built).existsSync()) {
    fail('cargo build succeeded but $built was not produced.');
  }
  return built;
}

void main() {
  setUpAll(() async {
    final lib = await _findOrBuildLib();
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File(lib).absolute.path),
    );
  });

  test('advance + take_damage round-trips and DSR emits a PtyWrite event', () async {
    final engine = engineNew(columns: 20, rows: 5);

    await engineAdvance(engine: engine, bytes: 'hi'.codeUnits);
    final u = await engineTakeDamage(engine: engine);
    final line0 = u.lines.firstWhere((l) => l.line == 0);
    expect(String.fromCharCode(line0.cells[0].codepoint), 'h');
    expect(String.fromCharCode(line0.cells[1].codepoint), 'i');

    // DSR cursor-position query → a PtyWrite event, drained by polling.
    await engineAdvance(engine: engine, bytes: '\x1b[6n'.codeUnits);
    final events = engineTakeEvents(engine: engine);
    expect(events.whereType<EngineEvent_PtyWrite>(), isNotEmpty);
  });
}
