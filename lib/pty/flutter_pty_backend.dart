import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import 'pty_backend.dart';

class FlutterPtyBackend implements PtyBackend {
  FlutterPtyBackend({int rows = 24, int columns = 80, String? shell})
      : _pty = Pty.start(
          shell ?? _defaultShell(),
          columns: columns,
          rows: rows,
          environment: {...Platform.environment, 'TERM': 'xterm-256color'},
        );

  final Pty _pty;

  static String _defaultShell() =>
      Platform.environment['SHELL'] ??
      (Platform.isWindows ? 'cmd.exe' : '/bin/bash');

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void write(Uint8List data) => _pty.write(data);

  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);

  @override
  void kill() => _pty.kill();
}
