import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;
import 'package:rust_lib_flutter_alacritty/rust_lib_flutter_alacritty.dart';

import 'package:flutter_alacritty/src/rust/frb_generated.dart';

export 'package:rust_lib_flutter_alacritty/rust_lib_flutter_alacritty.dart'
    show precompiledRustLibFileName;

/// Relative path from a `flutter_alacritty` git checkout to the Rust crate.
///
/// When consumed from pub.dev, [rustManifestDir] resolves via the plugin package.
const checkoutRustDir = 'packages/rust_lib_flutter_alacritty/rust';

/// Locations a built Rust cdylib may live, fastest/most-likely first.
List<String> rustLibCandidates({String? checkoutRelativeRustDir}) {
  final name = precompiledRustLibFileName();
  final rustDir = checkoutRelativeRustDir ?? checkoutRustDir;
  final cargoDebug = '$rustDir/target/debug/$name';
  final cargoRelease = '$rustDir/target/release/$name';

  if (Platform.isLinux) {
    return [
      cargoRelease,
      cargoDebug,
      'build/linux/x64/release/bundle/lib/$name',
      'build/linux/x64/debug/bundle/lib/$name',
    ];
  }
  if (Platform.isMacOS) {
    return [
      cargoRelease,
      cargoDebug,
      'build/macos/Build/Products/Release/$name',
      'build/macos/Build/Products/Debug/$name',
    ];
  }
  if (Platform.isWindows) {
    return [
      cargoRelease,
      cargoDebug,
      'build/windows/x64/runner/Release/$name',
      'build/windows/x64/runner/Debug/$name',
    ];
  }
  return [cargoRelease, cargoDebug];
}

Future<String?> _findExistingCandidate({String? checkoutRelativeRustDir}) async {
  for (final candidate in rustLibCandidates(
    checkoutRelativeRustDir: checkoutRelativeRustDir,
  )) {
    if (File(candidate).existsSync()) {
      return p.normalize(File(candidate).absolute.path);
    }
  }
  return null;
}

Future<bool> _cargoAvailable() async {
  if (Platform.environment.containsKey('CARGO')) return true;
  final result = await Process.run('cargo', ['--version']);
  return result.exitCode == 0;
}

Future<String> _cargoBuild({
  required String rustDir,
  required bool release,
}) async {
  final args = release ? ['build', '--release'] : ['build'];
  final result = await Process.run('cargo', args, workingDirectory: rustDir);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to build the Rust lib (`cargo ${args.join(' ')}` in $rustDir/ '
      'exited ${result.exitCode}):\n${result.stderr}',
    );
  }
  final profile = release ? 'release' : 'debug';
  final built = p.join(rustDir, 'target', profile, precompiledRustLibFileName());
  if (!File(built).existsSync()) {
    throw StateError('cargo build succeeded but $built was not produced.');
  }
  return p.normalize(File(built).absolute.path);
}

/// Resolves a Rust cdylib path: local build output → `cargo build` → precompiled
/// download (Cargokit GitHub releases).
Future<String> resolveRustLibPath({
  bool release = true,
  String? checkoutRelativeRustDir,
}) async {
  final existing = await _findExistingCandidate(
    checkoutRelativeRustDir: checkoutRelativeRustDir,
  );
  if (existing != null) return existing;

  final rustDir = checkoutRelativeRustDir ?? checkoutRustDir;
  if (await _cargoAvailable() && Directory(rustDir).existsSync()) {
    return _cargoBuild(rustDir: rustDir, release: release);
  }

  final downloaded = await downloadPrecompiledRustLib(
    manifestDir: Directory(rustDir).existsSync() ? rustDir : rustManifestDir(),
  );
  if (downloaded != null) {
    return p.normalize(File(downloaded).absolute.path);
  }

  throw StateError(
    'No Rust library found. Install Rust and run `cargo build` in $rustDir, '
    'or ensure precompiled binaries are published for this plugin version '
    '(see rust_lib_flutter_alacritty docs/PRECOMPILED_BINARIES.md).',
  );
}

/// Initializes FRB against a real cdylib. Safe to call from multiple test files'
/// `setUpAll` — [RustLib.init] is idempotent once loaded.
Future<void> initRustLibForTests({
  bool preferRelease = true,
  String? checkoutRelativeRustDir,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final lib = await resolveRustLibPath(
    release: preferRelease,
    checkoutRelativeRustDir: checkoutRelativeRustDir,
  );
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(lib),
  );
}
