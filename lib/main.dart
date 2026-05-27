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
    // `child` keeps [TerminalScreen] stable across title updates. Rebuilding home
    // on every title change — after pumpEvents in the same drain as grid.apply —
    // would reset paint state and drop pending repaints until lifecycle.
    return ValueListenableBuilder<String>(
      valueListenable: _title,
      builder: (context, title, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: title,
        home: child,
      ),
      child: TerminalScreen(title: _title),
    );
  }
}
