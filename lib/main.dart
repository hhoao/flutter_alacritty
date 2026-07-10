import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_alacritty/config/config_loader.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:flutter_alacritty/pty/shell_defaults.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  if (Platform.isAndroid) {
    final dir = await getApplicationSupportDirectory();
    ShellDefaults.install(mobileHome: dir.path);
  }
  final path = ConfigLoader.resolveConfigPath();
  final initial = ConfigLoader.loadFile(path);
  final updates = path != null ? ConfigLoader.watch(path) : null;
  runApp(ExampleTerminalApp(config: initial, configUpdates: updates));
}
