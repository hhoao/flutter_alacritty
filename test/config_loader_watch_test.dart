import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/config_loader.dart';

void main() {
  test('watch emits a reparsed config on file change', () async {
    final dir = await Directory.systemTemp.createTemp('fa_cfg');
    final f = File('${dir.path}/c.toml')..writeAsStringSync('[font]\nsize = 14\n');
    final got = <double>[];
    final sub = ConfigLoader.watch(f.path).listen((c) => got.add(c.font.size));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    f.writeAsStringSync('[font]\nsize = 20\n');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    await dir.delete(recursive: true);
    expect(got.last, 20.0);
  });

  test('watch keeps last-good config on parse error', () async {
    final dir = await Directory.systemTemp.createTemp('fa_cfg');
    final f = File('${dir.path}/c.toml')..writeAsStringSync('[font]\nsize = 14\n');
    final got = <double>[];
    final sub = ConfigLoader.watch(f.path).listen((c) => got.add(c.font.size));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    f.writeAsStringSync('this is not valid toml = = =');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    await dir.delete(recursive: true);
    expect(got.every((s) => s == 14.0), true);
  });
}
