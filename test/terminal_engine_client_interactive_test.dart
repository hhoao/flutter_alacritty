import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_binding.dart';

/// Binding that holds [advanceAndTakeDamage] until [release] completes.
class _HeldAdvanceBinding extends FakeBinding {
  final Completer<void> release = Completer<void>();
  int advanceCalls = 0;

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async {
    advanceCalls++;
    fedBytes.addAll(bytes);
    await release.future;
    return GridUpdate(
      full: false,
      rows: 1,
      columns: 1,
      lines: const [],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('markInteractive drains via microtask without post-frame schedule',
      () async {
    final binding = FakeBinding();
    final grid = MirrorGrid();
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.markInteractive();
    client.feed(Uint8List.fromList([0x41]));

    // Interactive path must not touch the idle post-frame scheduler.
    expect(scheduled, isEmpty);

    // Flush microtasks only — do not invoke recorded post-frame callbacks.
    await Future<void>.value();

    expect(binding.fedBytes, [0x41]);
  });

  test('without markInteractive feed only uses injected schedule', () async {
    final binding = FakeBinding();
    final grid = MirrorGrid();
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.feed(Uint8List.fromList([0x42]));

    expect(scheduled, hasLength(1));
    expect(binding.fedBytes, isEmpty);

    // Microtask flush alone must not drain.
    await Future<void>.value();
    expect(binding.fedBytes, isEmpty);

    scheduled.single();
    await Future<void>.value();
    expect(binding.fedBytes, [0x42]);
  });

  test('single-flight: feed during advance coalesces into one follow-up',
      () async {
    final binding = _HeldAdvanceBinding();
    final grid = MirrorGrid();
    final scheduled = <void Function()>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: scheduled.add,
    );
    addTearDown(client.dispose);

    client.markInteractive();
    client.feed(Uint8List.fromList([1]));
    await Future<void>.value();
    expect(binding.advanceCalls, 1);
    expect(binding.fedBytes, [1]);

    // Second feed while first advance is held — must not start another advance.
    client.feed(Uint8List.fromList([2, 3]));
    await Future<void>.value();
    expect(binding.advanceCalls, 1);
    expect(binding.fedBytes, [1]);

    binding.release.complete();
    await Future<void>.value();
    await Future<void>.value();

    expect(binding.advanceCalls, 2);
    expect(binding.fedBytes, [1, 2, 3]);
  });
}
