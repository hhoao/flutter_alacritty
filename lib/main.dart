import 'package:flutter/material.dart';
import 'package:flutter_alacritty/config/config_loader.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final path = ConfigLoader.resolveConfigPath();
  final initial = ConfigLoader.loadFile(path);
  final updates = path != null ? ConfigLoader.watch(path) : null;
  runApp(MyApp(config: initial, configUpdates: updates));
}

class MyApp extends StatefulWidget {
  const MyApp({required this.config, this.configUpdates, super.key});
  final TerminalConfig config;
  final Stream<TerminalConfig>? configUpdates;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ValueNotifier<String> _title = ValueNotifier('flutter_alacritty');

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `child` keeps [ExampleTerminalApp] stable across title updates. Rebuilding
    // home on every title change — after pumpEvents in the same drain as
    // grid.apply — would reset paint state and drop pending repaints until
    // lifecycle.
    return ValueListenableBuilder<String>(
      valueListenable: _title,
      builder: (context, title, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: title,
        home: child,
      ),
      child: ExampleTerminalApp(
        title: _title,
        config: widget.config,
        configUpdates: widget.configUpdates,
      ),
    );
  }
}
