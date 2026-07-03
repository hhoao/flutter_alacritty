import 'package:flutter_alacritty/testing/rust_lib_loader.dart';

export 'package:flutter_alacritty/testing/rust_lib_loader.dart';

String rustLibFileName() => precompiledRustLibFileName();

Future<String> findOrBuildRustLib({bool release = false}) =>
    resolveRustLibPath(release: release);
