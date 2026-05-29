# flutter_alacritty

Flutter terminal widget powered by an [Alacritty](https://github.com/alacritty/alacritty)-based Rust engine, with PTY support via [`flutter_pty`](https://pub.dev/packages/flutter_pty).

## Screenshots

![Flutter Alacritty terminal](assets/imgs/image.png)

## Requirements

- Flutter 3.3+
- Dart 3.11+
- Rust toolchain (for building the native engine)
- Linux, macOS, or Windows desktop (primary targets)

## Use as a dependency

```yaml
dependencies:
  flutter_alacritty: ^1.0.0
```

## Use as a library

`flutter_alacritty` ships three public types: a `TerminalEngine` (the
alacritty handle), a `TerminalController` (selection / search / scroll
state), and a `TerminalView` widget. Wire any `PtyBackend` to the engine
with two `Stream` subscriptions:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MaterialApp(home: _TerminalScaffold()));
}

class _TerminalScaffold extends StatefulWidget {
  const _TerminalScaffold();
  @override
  State<_TerminalScaffold> createState() => _TerminalScaffoldState();
}

class _TerminalScaffoldState extends State<_TerminalScaffold> {
  late final _engine = TerminalEngine(config: TerminalConfig.defaults());
  late final _controller = TerminalController()..attach(_engine);
  late final PtyBackend _pty = FlutterPtyBackend(rows: 24, columns: 80);
  late final StreamSubscription _ptyIn = _pty.output.listen(_engine.feed);
  late final StreamSubscription _ptyOut = _engine.output.listen(_pty.write);

  @override
  void dispose() {
    _ptyIn.cancel();
    _ptyOut.cancel();
    _pty.kill();
    _controller.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: _engine.title,
        builder: (_, title, __) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: TerminalView(_engine, controller: _controller),
        ),
      );
}
```

See [`docs/library-api.md`](docs/library-api.md) for the full API
walkthrough: every `TerminalEngine` / `TerminalController` / `TerminalView`
member, shortcut customization patterns, callbacks, theming, and SSH /
remote-PTY wiring. The reference consumer with drag-and-drop, right-click
menu, restart overlay, and `url_launcher` integration lives at
[`lib/example/example_app.dart`](lib/example/example_app.dart).

## Clone (with Rust FFI submodule)

```bash
git clone --recurse-submodules https://github.com/hhoao/flutter_alacritty.git
# existing clone:
git submodule update --init --recursive
```

The [`rust_lib_flutter_alacritty`](https://github.com/hhoao/rust_lib_flutter_alacritty) plugin lives in `packages/rust_lib_flutter_alacritty/` as a git submodule.

## Package Linux (deb + AppImage)

See [linux/packaging/README.md](linux/packaging/README.md) for detailed steps. Briefly:

```bash
dart pub global activate fastforge
git submodule update --init --recursive
flutter pub get
fastforge release --name dev
# Output: dist/{version}/flutter_alacritty-{version}-linux.deb, etc.
```

## Run the demo app (from git checkout)

```bash
flutter pub get
flutter run -d linux   # or macos / windows
```

## Publishing to pub.dev

This repo ships **two** packages:

| Package | Directory | Publish first? |
|---------|-----------|----------------|
| `rust_lib_flutter_alacritty` | [`packages/rust_lib_flutter_alacritty/`](https://github.com/hhoao/rust_lib_flutter_alacritty) (submodule) | **Yes** |
| `flutter_alacritty` | repo root | After the plugin is on pub.dev |

See [PUBLISHING.md](PUBLISHING.md) for the full checklist.

## License

MIT — see [LICENSE](LICENSE).
