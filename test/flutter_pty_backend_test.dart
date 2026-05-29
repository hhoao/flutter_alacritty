import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/pty/flutter_pty_backend.dart';

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
}
