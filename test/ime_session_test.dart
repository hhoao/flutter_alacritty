import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/ime_session.dart';

class _FakeTextInputConnection with IDebugImeConnection implements TextInputConnection {
  int showCount = 0;
  int hideCount = 0;
  int closeCount = 0;
  bool _attached = true;

  @override
  bool get attached => _attached;

  @override
  void show() => showCount++;

  @override
  void hide() => hideCount++;

  @override
  void close() {
    closeCount++;
    _attached = false;
  }

  @override
  void setEditingState(TextEditingValue value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  void noopBackspace() {}

  // ImeSession works without the platform binding for its parsing logic.
  group('updateEditingValue', () {
    test('preedit-only value fires onPreeditChanged with composing substring', () {
      String? preedit = '__unset__';
      var commits = 0;
      final s = ImeSession(
        onCommit: (_) => commits++,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(preedit, 'ni');
      expect(commits, 0);
    });

    test('committed value fires onCommit once and clears preedit', () {
      final commits = <String>[];
      String? preedit = '__unset__';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(const TextEditingValue(text: '你好'));
      expect(commits, ['你好']);
      expect(preedit, isNull);
    });

    test('empty value (no text, no composing) clears preedit without commit', () {
      final commits = <String>[];
      var backspaces = 0;
      String? preedit = 'stale';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(TextEditingValue.empty);
      expect(commits, isEmpty);
      expect(backspaces, 0);
      expect(preedit, isNull);
    });

    test('shrinking sentinel fires onBackspace (TextInput delete path)', () {
      var backspaces = 0;
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: () => backspaces++,
      );
      s.updateEditingValue(
        const TextEditingValue(
          text: ' ',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      expect(backspaces, 1);
    });

    test('preedit then commit produces one onCommit and clears preedit', () {
      final preedits = <String?>[];
      final commits = <String>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: preedits.add,
        onBackspace: noopBackspace,
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'n', composing: TextRange(start: 0, end: 1)),
      );
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(preedits, ['n', 'ni', null]);
      expect(commits, ['你']);
    });

    test('isComposing true only during active composing range', () {
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      expect(s.isComposing, isFalse);
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(s.isComposing, isTrue);
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(s.isComposing, isFalse);
    });
  });

  test('performPrivateCommand deleteBackward fires onBackspace', () {
    var backspaces = 0;
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (_) {},
      onBackspace: () => backspaces++,
    );
    s.performPrivateCommand('deleteBackward', const {});
    expect(backspaces, 1);
  });

  test('connectionClosed triggers detach (preedit cleared, no double-fire)', () {
    String? preedit = 'stale';
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (p) => preedit = p,
      onBackspace: noopBackspace,
    );
    s.connectionClosed();
    expect(preedit, isNull);
    expect(s.isAttached, isFalse);
  });

  test('platform-side connectionClosed mid-composition resets isComposing + clears preedit', () {
    final preedits = <String?>[];
    final commits = <String>[];
    final s = ImeSession(
      onCommit: commits.add,
      onPreeditChanged: preedits.add,
      onBackspace: noopBackspace,
    );
    s.updateEditingValue(
      const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
    );
    expect(s.isComposing, isTrue);
    s.connectionClosed();
    expect(s.isComposing, isFalse);
    expect(s.isAttached, isFalse);
    expect(preedits.last, isNull);
    expect(commits, isEmpty);
  });

  test('detach when never attached is a safe no-op', () {
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (_) {},
      onBackspace: noopBackspace,
    );
    expect(() => s.detach(), returnsNormally);
    expect(s.isAttached, isFalse);
  });

  group('ensureVisible', () {
    test('calls show when already attached (can call show twice)', () {
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      final conn = _FakeTextInputConnection();
      s.debugBindConnection(conn);

      expect(s.isAttached, isTrue);

      s.ensureVisible();
      s.ensureVisible();

      expect(conn.showCount, 2);
      expect(s.isAttached, isTrue);
    });
  });

  group('hide', () {
    test('calls connection hide without detach (still isAttached)', () {
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: (_) {},
        onBackspace: noopBackspace,
      );
      final conn = _FakeTextInputConnection();
      s.debugBindConnection(conn);

      expect(s.isAttached, isTrue);

      s.hide();

      expect(conn.hideCount, 1);
      expect(conn.closeCount, 0);
      expect(s.isAttached, isTrue);
    });
  });

  group('resetComposing', () {
    test('abandons in-flight preedit without committing it', () {
      final commits = <String>[];
      final preedits = <String?>[];
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: preedits.add,
        onBackspace: noopBackspace,
      );

      // Drive a composing value so isComposing is true.
      s.updateEditingValue(
        const TextEditingValue(
            text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(s.isComposing, isTrue);
      expect(preedits.last, 'ni');

      // Reset — must abandon the composition, not commit it.
      s.resetComposing();

      expect(s.isComposing, isFalse,
          reason: 'resetComposing must clear the composing flag');
      expect(preedits.last, isNull,
          reason: 'resetComposing must notify onPreeditChanged(null)');
      expect(commits, isEmpty,
          reason: 'resetComposing must NOT commit the preedit text');
    });

    test('resetComposing with notify:false skips onPreeditChanged', () {
      final preedits = <String?>[];
      final s = ImeSession(
        onCommit: (_) {},
        onPreeditChanged: preedits.add,
        onBackspace: noopBackspace,
      );

      s.updateEditingValue(
        const TextEditingValue(
            text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(s.isComposing, isTrue);
      final preeditCountBefore = preedits.length;

      s.resetComposing(notify: false);

      expect(s.isComposing, isFalse);
      expect(preedits.length, preeditCountBefore,
          reason: 'notify:false must not fire onPreeditChanged');
    });
  });
}
