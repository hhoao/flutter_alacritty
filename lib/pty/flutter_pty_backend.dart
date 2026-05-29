import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import '../config/terminal_config.dart';
import 'pty_backend.dart';

/// Pure spawn parameters, derived from ShellConfig + environment. Extracted so
/// the mapping is unit-testable without spawning a process.
class ShellSpec {
  const ShellSpec({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
  });
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
}

ShellSpec resolveShellSpec(ShellConfig shell, {Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final home = e['HOME'];
  String? expandTilde(String? p) {
    if (p == null) return null;
    if (p == '~') return home;
    if (p.startsWith('~/') && home != null) return '$home${p.substring(1)}';
    return p;
  }

  final program = shell.program ??
      e['SHELL'] ??
      (Platform.isWindows ? 'cmd.exe' : '/bin/bash');

  return ShellSpec(
    executable: program,
    arguments: shell.args,
    workingDirectory: expandTilde(shell.workingDirectory),
    environment: {...e, 'TERM': 'xterm-256color', ...shell.env},
  );
}

class FlutterPtyBackend implements PtyBackend {
  FlutterPtyBackend({
    int rows = 24,
    int columns = 80,
    ShellConfig shell = const ShellConfig(),
  }) : this._fromSpec(resolveShellSpec(shell), rows, columns);

  FlutterPtyBackend._fromSpec(ShellSpec spec, int rows, int columns)
      : _pty = Pty.start(
          spec.executable,
          arguments: spec.arguments,
          columns: columns,
          rows: rows,
          workingDirectory: spec.workingDirectory,
          environment: spec.environment,
        );

  final Pty _pty;

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
