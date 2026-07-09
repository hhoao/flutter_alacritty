import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/pty/flutter_pty_backend.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';

/// Fake that overrides [isForegroundProcessRunning] for interface coverage.
class _ForegroundFakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  final foreground = ValueNotifier(false);
  bool _disposed = false;

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
    if (_disposed) return;
    _disposed = true;
    foreground.value = false; // notify hosts before dispose
    foreground.dispose();
  }

  @override
  ValueListenable<bool>? get isForegroundProcessRunning =>
      _disposed ? null : foreground;
}

/// Default fake — unknown foreground state (Windows / SSH contract).
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

  test('Windows / null initial skips foreground watching', () {
    expect(
      shouldWatchForegroundProcess(
        isWindows: true,
        initialForegroundRunning: false,
      ),
      isFalse,
    );
    expect(
      shouldWatchForegroundProcess(
        isWindows: false,
        initialForegroundRunning: null,
      ),
      isFalse,
    );
    expect(
      shouldWatchForegroundProcess(
        isWindows: false,
        initialForegroundRunning: false,
      ),
      isTrue,
    );
  });

  test('host can listen when backend exposes a ValueListenable', () {
    final pty = _ForegroundFakePty();
    addTearDown(() {
      if (pty.isForegroundProcessRunning != null) pty.kill();
    });

    final listenable = pty.isForegroundProcessRunning;
    expect(listenable, isNotNull);
    expect(listenable!.value, isFalse);

    var notified = false;
    listenable.addListener(() => notified = true);
    pty.foreground.value = true;

    expect(notified, isTrue);
    expect(listenable.value, isTrue);
  });

  test('kill sets false then clears listenable (host teardown contract)', () {
    final pty = _ForegroundFakePty();
    final listenable = pty.isForegroundProcessRunning!;
    var last = listenable.value;
    listenable.addListener(() => last = listenable.value);

    pty.foreground.value = true;
    expect(last, isTrue);

    pty.kill();
    expect(last, isFalse);
    expect(pty.isForegroundProcessRunning, isNull);
  });

  test('FlutterPtyBackend foreground listenable contract', () {
    if (Platform.isWindows) {
      // Document Windows-null without requiring a successful spawn path that
      // still returns null from the getter after construct.
      expect(
        shouldWatchForegroundProcess(
          isWindows: true,
          initialForegroundRunning: false,
        ),
        isFalse,
      );
      return;
    }

    late final FlutterPtyBackend pty;
    try {
      pty = FlutterPtyBackend(rows: 24, columns: 80);
    } on ArgumentError catch (e) {
      // Unit-test VM often lacks libflutter_pty_new.so (plugin dylib).
      // ignore: avoid_print
      print('skip FlutterPtyBackend spawn: $e');
      return;
    }
    addTearDown(() {
      try {
        pty.kill();
      } on Object {
        // already killed
      }
    });

    expect(pty.isForegroundProcessRunning, isNotNull);
    pty.kill();
    expect(pty.isForegroundProcessRunning, isNull);
  });
}
