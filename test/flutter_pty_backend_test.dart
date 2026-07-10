import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/pty/flutter_pty_backend.dart';
import 'package:flutter_alacritty/pty/shell_defaults.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  test('resolves program/args/env/cwd from ShellConfig', () {
    final spec = resolveShellSpec(
      const ShellConfig(
        program: '/bin/zsh',
        args: ['-l'],
        workingDirectory: '~/wd',
        env: {'FOO': 'bar'},
      ),
      env: {'HOME': '/home/u', 'SHELL': '/bin/bash'},
    );
    expect(spec.executable, '/bin/zsh');
    expect(spec.arguments, ['-l']);
    expect(spec.workingDirectory, '/home/u/wd'); // ~ expanded
    expect(spec.environment['FOO'], 'bar');
    expect(spec.environment['TERM'], 'xterm-256color');
  });

  test('falls back to \$SHELL when program null', () {
    final spec = resolveShellSpec(const ShellConfig(),
        env: {'HOME': '/home/u', 'SHELL': '/bin/fish'});
    expect(spec.executable, '/bin/fish');
    expect(spec.workingDirectory, isNull);
  });

  test('android without SHELL prefers /system/bin/sh over /bin/bash', () {
    final spec = resolveShellSpec(
      const ShellConfig(),
      env: {'HOME': '/'},
    );
    if (Platform.isAndroid) {
      expect(spec.executable, anyOf('/system/bin/sh', '/bin/sh'));
    } else {
      expect(spec.executable, '/bin/bash');
    }
  });

  test('android shell spec patches HOME and cwd when env HOME is root', () {
    if (!Platform.isAndroid) return;
    ShellDefaults.install(
      mobileHome: '/data/user/0/io.github.hhoao.flutter_alacritty',
    );
    addTearDown(() => ShellDefaults.mobileHome = null);
    final spec = resolveShellSpec(const ShellConfig(), env: {'HOME': '/'});
    expect(spec.workingDirectory,
        '/data/user/0/io.github.hhoao.flutter_alacritty');
    expect(spec.environment['HOME'], spec.workingDirectory);
  });

  test('android PTY pwd is not root when ShellDefaults installed', () async {
    if (!Platform.isAndroid) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    final home = (await getApplicationSupportDirectory()).path;
    ShellDefaults.install(mobileHome: home);
    addTearDown(() => ShellDefaults.mobileHome = null);

    final pty = FlutterPtyBackend(rows: 24, columns: 80);
    addTearDown(pty.kill);

    final output = StringBuffer();
    final sub = pty.output.listen((chunk) => output.write(utf8.decode(chunk)));
    addTearDown(sub.cancel);

    pty.write(utf8.encode('pwd\n'));
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final text = output.toString();
    expect(text, isNot(contains('\n/\n')));
    expect(text, contains(home));
  });
}
