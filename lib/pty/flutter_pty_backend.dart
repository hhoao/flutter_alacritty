import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../config/terminal_config.dart';
import 'pty_backend.dart';
import 'shell_defaults.dart';

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

/// Maps [ShellConfig] to concrete spawn parameters.
///
/// Platform defaults (Android `HOME`/cwd, shell binary fallbacks) are applied
/// here; hosts override via [ShellConfig] fields. See `docs/library-api.md`.
ShellSpec resolveShellSpec(ShellConfig shell, {Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final shellEnv = _effectiveShellEnvironment(e, shell.env);
  final home = shellEnv['HOME'];
  String? expandTilde(String? p) {
    if (p == null) return null;
    if (p == '~') return home;
    if (p.startsWith('~/') && home != null) return '$home${p.substring(1)}';
    return p;
  }

  final program = shell.program ?? _defaultShellExecutable(e);

  return ShellSpec(
    executable: program,
    arguments: shell.args,
    workingDirectory:
        expandTilde(shell.workingDirectory) ?? _defaultWorkingDirectory(e),
    environment: shellEnv,
  );
}

Map<String, String> _effectiveShellEnvironment(
  Map<String, String> env,
  Map<String, String> shellEnv,
) {
  final merged = <String, String>{...env, 'TERM': 'xterm-256color', ...shellEnv};
  if (Platform.isAndroid) {
    final home = _resolveAndroidHomeDirectory(env);
    if (home != null) merged['HOME'] = home;
  }
  return merged;
}

String? _resolveAndroidHomeDirectory(Map<String, String> env) {
  final installed = ShellDefaults.mobileHome;
  if (installed != null && installed.isNotEmpty && installed != '/') {
    return installed;
  }
  final home = env['HOME'];
  if (home != null && home.isNotEmpty && home != '/') return home;
  final fromProc = _homeFromProcEnviron();
  if (fromProc != null) return fromProc;
  return _processWorkingDirectory();
}

/// Android sets the real `HOME` in the process environ, not always in
/// [Platform.environment] (which may be `/` or absent in the Dart VM).
String? _homeFromProcEnviron() {
  if (!Platform.isAndroid && !Platform.isLinux) return null;
  try {
    final raw = File('/proc/self/environ').readAsBytesSync();
    var i = 0;
    while (i < raw.length) {
      final start = i;
      while (i < raw.length && raw[i] != 0) i++;
      if (i > start) {
        final entry = String.fromCharCodes(raw.sublist(start, i));
        if (entry.startsWith('HOME=')) {
          final home = entry.substring(5);
          if (home.isNotEmpty && home != '/') return home;
        }
      }
      i++;
    }
  } on Object {
    // /proc may be unavailable on some embedders.
  }
  return null;
}

/// Real process cwd. [Directory.current] is often `/` on Android Flutter.
String? _processWorkingDirectory() {
  if (Platform.isAndroid || Platform.isLinux) {
    try {
      final cwd = File('/proc/self/cwd').resolveSymbolicLinksSync();
      if (cwd.isNotEmpty && cwd != '/') return cwd;
    } on Object {
      // fall through
    }
    try {
      final cwd = Link('/proc/self/cwd').targetSync();
      if (cwd.isNotEmpty && cwd != '/') return cwd;
    } on Object {
      // /proc may be unavailable on some embedders.
    }
  }
  try {
    final current = Directory.current.path;
    if (current.isNotEmpty && current != '/') return current;
  } on Object {
    // Directory.current may throw on some embedders.
  }
  return null;
}

String? _defaultWorkingDirectory(Map<String, String> env) {
  if (!Platform.isAndroid) return null;
  return _resolveAndroidHomeDirectory(env);
}

/// Resolves the shell binary when [ShellConfig.program] is unset.
///
/// Android app processes often lack `SHELL` in [Platform.environment] and
/// never ship `/bin/bash`; use the first existing POSIX shell instead.
String _defaultShellExecutable(Map<String, String> env) {
  if (Platform.isWindows) return 'cmd.exe';
  if (Platform.isAndroid) {
    return _firstExistingExecutable([
      if (env['SHELL']?.isNotEmpty ?? false) env['SHELL']!,
      '/system/bin/sh',
      '/bin/sh',
      '/system/xbin/sh',
    ]) ?? '/system/bin/sh';
  }
  return env['SHELL'] ?? '/bin/bash';
}

String? _firstExistingExecutable(Iterable<String> candidates) {
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Whether [FlutterPtyBackend] should expose a foreground listenable.
///
/// Windows and platforms that return `null` from the underlying PTY skip
/// polling so hosts see `null` rather than a stuck `false` notifier.
@visibleForTesting
bool shouldWatchForegroundProcess({
  required bool isWindows,
  required bool? initialForegroundRunning,
}) =>
    !isWindows && initialForegroundRunning != null;

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
        ) {
    final initial = _pty.isForegroundProcessRunning;
    if (shouldWatchForegroundProcess(
      isWindows: Platform.isWindows,
      initialForegroundRunning: initial,
    )) {
      _foregroundRunning = ValueNotifier<bool>(initial!);
      _startWatching();
    } else {
      _foregroundRunning = null;
    }
  }

  final Pty _pty;
  late final ValueNotifier<bool>? _foregroundRunning;
  StreamSubscription<bool>? _foregroundSub;
  bool _disposed = false;

  void _startWatching() {
    final notifier = _foregroundRunning;
    if (notifier == null) return;
    _foregroundSub = _pty.foregroundProcessRunningChanges().listen((running) {
      if (!_disposed) notifier.value = running;
    });
    // Stop polling after the shell exits naturally.
    unawaited(_pty.exitCode.then((_) => _disposeForegroundWatch()));
  }

  void _disposeForegroundWatch() {
    if (_disposed) return;
    _disposed = true;
    final sub = _foregroundSub;
    _foregroundSub = null;
    if (sub != null) unawaited(sub.cancel());
    final n = _foregroundRunning;
    if (n != null) {
      n.value = false; // notify hosts before dispose
      n.dispose();
    }
  }

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  ValueListenable<bool>? get isForegroundProcessRunning =>
      _disposed ? null : _foregroundRunning;

  @override
  void write(Uint8List data) => _pty.write(data);

  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);

  @override
  void kill() {
    _disposeForegroundWatch();
    _pty.kill();
  }
}

