import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/ime_session.dart';

void main() {
  // ImeSession works without the platform binding for its parsing logic.
  group('updateEditingValue', () {
    test('preedit-only value fires onPreeditChanged with composing substring', () {
      String? preedit = '__unset__';
      var commits = 0;
      final s = ImeSession(
        onCommit: (_) => commits++,
        onPreeditChanged: (p) => preedit = p,
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
      );
      s.updateEditingValue(const TextEditingValue(text: '你好'));
      expect(commits, ['你好']);
      expect(preedit, isNull);
    });

    test('empty value (no text, no composing) clears preedit without commit', () {
      final commits = <String>[];
      String? preedit = 'stale';
      final s = ImeSession(
        onCommit: commits.add,
        onPreeditChanged: (p) => preedit = p,
      );
      s.updateEditingValue(TextEditingValue.empty);
      expect(commits, isEmpty);
      expect(preedit, isNull);
    });

    test('preedit then commit produces one onCommit and clears preedit', () {
      final preedits = <String?>[];
      final commits = <String>[];
      final s = ImeSession(onCommit: commits.add, onPreeditChanged: preedits.add);
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
      final s = ImeSession(onCommit: (_) {}, onPreeditChanged: (_) {});
      expect(s.isComposing, isFalse);
      s.updateEditingValue(
        const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
      );
      expect(s.isComposing, isTrue);
      s.updateEditingValue(const TextEditingValue(text: '你'));
      expect(s.isComposing, isFalse);
    });
  });

  test('connectionClosed triggers detach (preedit cleared, no double-fire)', () {
    String? preedit = 'stale';
    final s = ImeSession(
      onCommit: (_) {},
      onPreeditChanged: (p) => preedit = p,
    );
    s.connectionClosed();
    expect(preedit, isNull);
    expect(s.isAttached, isFalse);
  });

  test('platform-side connectionClosed mid-composition resets isComposing + clears preedit', () {
    final preedits = <String?>[];
    final commits = <String>[];
    final s = ImeSession(onCommit: commits.add, onPreeditChanged: preedits.add);
    // Mimic the production sequence: enter composing state, then the platform
    // tears the connection down (e.g. window blur, IM crash). The gate in
    // TerminalView._onKey reads `isAttached && isComposing` — both must
    // flip back to false so ASCII falls back to encodeKey.
    s.updateEditingValue(
      const TextEditingValue(text: 'ni', composing: TextRange(start: 0, end: 2)),
    );
    expect(s.isComposing, isTrue);
    s.connectionClosed();
    expect(s.isComposing, isFalse);
    expect(s.isAttached, isFalse);
    expect(preedits.last, isNull);
    expect(commits, isEmpty); // composing was dropped, not committed
  });

  test('detach when never attached is a safe no-op', () {
    final s = ImeSession(onCommit: (_) {}, onPreeditChanged: (_) {});
    expect(() => s.detach(), returnsNormally);
    expect(s.isAttached, isFalse);
  });
}
