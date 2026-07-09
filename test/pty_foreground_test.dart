import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';

/// Fake that overrides [isForegroundProcessRunning] for interface coverage.
class _ForegroundFakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  final foreground = ValueNotifier(false);

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int rows, int columns) {}

  @override
  void kill() {
    foreground.dispose();
  }

  @override
  ValueListenable<bool>? get isForegroundProcessRunning => foreground;
}

/// Default fake — unknown foreground state.
class _DefaultFakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int rows, int columns) {}

  @override
  void kill() {}

  // Explicit null: `implements` does not inherit abstract-class defaults.
  @override
  ValueListenable<bool>? get isForegroundProcessRunning => null;
}

void main() {
  test('PtyBackend default isForegroundProcessRunning is null', () {
    final pty = _DefaultFakePty();
    expect(pty.isForegroundProcessRunning, isNull);
  });

  test('host can listen when backend exposes a ValueListenable', () {
    final pty = _ForegroundFakePty();
    addTearDown(pty.kill);

    final listenable = pty.isForegroundProcessRunning;
    expect(listenable, isNotNull);
    expect(listenable!.value, isFalse);

    var notified = false;
    listenable.addListener(() => notified = true);
    pty.foreground.value = true;

    expect(notified, isTrue);
    expect(listenable.value, isTrue);
  });
}
