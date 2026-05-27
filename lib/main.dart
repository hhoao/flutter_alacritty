import 'package:flutter/material.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

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
    return ValueListenableBuilder<String>(
      valueListenable: _title,
      builder: (context, title, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: title,
        home: TerminalScreen(title: _title),
      ),
    );
  }
}
