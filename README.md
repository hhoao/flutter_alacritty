# flutter_alacritty

[![CI](https://github.com/hhoao/flutter_alacritty/actions/workflows/ci.yml/badge.svg)](https://github.com/hhoao/flutter_alacritty/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_alacritty.svg)](https://pub.dev/packages/flutter_alacritty)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Flutter terminal widget powered by an [Alacritty](https://github.com/alacritty/alacritty)-based Rust engine, with PTY support via [`flutter_pty_new`](https://pub.dev/packages/flutter_pty_new).

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Screenshots

![Flutter Alacritty terminal](assets/imgs/image.png)

## Features

- Alacritty-grade terminal emulation via [`rust_lib_flutter_alacritty`](https://pub.dev/packages/rust_lib_flutter_alacritty) (Rust FFI)
- GPU glyph atlas rendering with incremental scroll damage
- Unified viewport resize: `TerminalView` owns cell layout and fires `onPtyResize` after the engine grid commits
- Scrollback with proportional history scrollbar and GNOME-style smooth scrolling
- Selection, search, OSC 52 clipboard, visual bell, and CJK IME preedit overlay
- Hyperlinks: OSC 8 native support; optional `UrlLinkProvider` for `http(s)://` regex detection
- TOML configuration (demo app) and theming via `TerminalTheme` / `TerminalConfig`
- Desktop targets: Linux, macOS, Windows

## Requirements

- Flutter 3.3+
- Dart 3.11+
- Linux, macOS, or Windows desktop
- **Rust toolchain** — optional for app builds; required only when hacking the
  engine or when precompiled binaries are unavailable for your platform/hash.
  See [packages/rust_lib_flutter_alacritty/docs/PRECOMPILED_BINARIES.md](packages/rust_lib_flutter_alacritty/docs/PRECOMPILED_BINARIES.md).

## Use as a dependency

```yaml
dependencies:
  flutter_alacritty: ^2.2.1
```

Requires [`rust_lib_flutter_alacritty`](https://pub.dev/packages/rust_lib_flutter_alacritty) **0.2.2** or newer (pulled in automatically).

## Use as a library

The public barrel (`package:flutter_alacritty/flutter_alacritty.dart`) exports
`TerminalEngine`, `TerminalController`, `TerminalView`, PTY backends,
viewport/resize helpers, link providers, theming, and `RustLib` for bootstrap.

Wire any `PtyBackend` to the engine with two `Stream` subscriptions. Let
`TerminalView` measure the cell grid and resize the PTY via `onPtyResize` — do
not compute columns/rows yourself:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_alacritty/flutter_alacritty.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MaterialApp(home: TerminalScaffold()));
}

class TerminalScaffold extends StatefulWidget {
  const TerminalScaffold({super.key});
  @override
  State<TerminalScaffold> createState() => _TerminalScaffoldState();
}

class _TerminalScaffoldState extends State<TerminalScaffold> {
  late final _engine = TerminalEngine(config: TerminalConfig.defaults());
  late final _controller = TerminalController()..attach(_engine);
  PtyBackend? _pty;

  StreamSubscription<Uint8List>? _ptyIn;
  StreamSubscription<Uint8List>? _ptyOut;

  void _onPtyResize(int cols, int rows) {
    if (_pty == null) {
      _pty = FlutterPtyBackend(rows: rows, columns: cols);
      _ptyIn = _pty!.output.listen(_engine.feed);
      _ptyOut = _engine.output.listen(_pty!.write);
    } else {
      _pty!.resize(rows, cols);
    }
  }

  @override
  void dispose() {
    _ptyIn?.cancel();
    _ptyOut?.cancel();
    _pty?.kill();
    _controller.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: _engine.title,
        builder: (_, title, __) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: TerminalView(
            _engine,
            controller: _controller,
            onPtyResize: _onPtyResize,
          ),
        ),
      );
}
```

See [`docs/library-api.md`](docs/library-api.md) for the full API walkthrough:
every `TerminalEngine` / `TerminalController` / `TerminalView` member,
shortcut customization, link providers, theming, viewport hold during chrome
animation, and SSH / remote-PTY wiring.

The reference consumer with drag-and-drop, right-click menu, restart overlay,
search bar, and `url_launcher` integration lives at
[`lib/example/example_app.dart`](lib/example/example_app.dart) (`ExampleTerminalApp`).

**Link detection (2.1+):** `TerminalView.linkProviders` defaults to `const []`
(no automatic URL regex scan). Pass `[UrlLinkProvider()]` to restore clickable
`http(s)://` detection; OSC 8 hyperlinks work without a provider.

## Configuration (demo app)

The bundled demo (`lib/main.dart`) loads TOML from
`$XDG_CONFIG_HOME/flutter_alacritty/flutter_alacritty.toml` (or
`~/.config/flutter_alacritty/flutter_alacritty.toml`). Copy
[`flutter_alacritty.toml.example`](flutter_alacritty.toml.example) as a
starting point. Missing keys use built-in defaults.

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
git submodule update --init --recursive
flutter pub get
flutter run -d linux   # or macos / windows
```

## Development

```bash
flutter analyze lib test
flutter test test/ --exclude-tags benchmark --exclude-tags visual
```

Optional suites (skipped by default via [`dart_test.yaml`](dart_test.yaml)):

```bash
flutter test --tags benchmark   # rendering + engine throughput
flutter test --tags visual      # golden image tests
```

## Publishing to pub.dev

This repo ships **two** packages, both on [pub.dev](https://pub.dev):

| Package | Directory | Notes |
|---------|-----------|-------|
| `rust_lib_flutter_alacritty` | [`packages/rust_lib_flutter_alacritty/`](https://github.com/hhoao/rust_lib_flutter_alacritty) (submodule) | Publish **first** when bumping engine FFI |
| `flutter_alacritty` | repo root | Depends on the published `rust_lib` version |

See [PUBLISHING.md](PUBLISHING.md) for the OIDC / GitHub Actions checklist.

## Projects using this library

| Project | Description |
|---------|-------------|
| [**TeamPilot**](https://github.com/hhoao/teampilot) | Desktop client for terminal AI agent teams: per-member embedded terminals (local PTY or SSH), team/model configuration, and a multi-tab chat workbench. Built on `flutter_alacritty` for rendering. |

## License

MIT — see [LICENSE](LICENSE).
