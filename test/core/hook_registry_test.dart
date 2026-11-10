import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';

/// Engineering rule 1: every global slot Pinpoint touches is restored on
/// dispose. Each milestone that adds a slot adds it to this file.
///
/// `SchedulerBinding.addPersistentFrameCallback` has no remove method, so it
/// cannot be restored and is not listed here (docs/api-notes.md, item 7).
void main() {
  testWidgets('key handlers are removed on dispose', (tester) async {
    final seen = <LogicalKeyboardKey>[];
    final registry = HookRegistry()
      ..addKeyHandler((event) {
        if (event is KeyDownEvent) seen.add(event.logicalKey);
        return false;
      });

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(seen, [LogicalKeyboardKey.keyA]);

    registry.dispose();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(seen, [LogicalKeyboardKey.keyA]);
  });

  group('replace', () {
    late int slot;
    int read() => slot;
    void write(int value) => slot = value;

    setUp(() => slot = 1);

    test('sets the value and restores the previous one', () {
      final registry = HookRegistry()
        ..replace(read: read, write: write, value: 2);
      expect(slot, 2);
      registry.dispose();
      expect(slot, 1);
    });

    test('restores in reverse order when one slot is replaced twice', () {
      final registry = HookRegistry()
        ..replace(read: read, write: write, value: 2)
        ..replace(read: read, write: write, value: 3);
      expect(slot, 3);
      registry.dispose();
      expect(slot, 1);
    });

    test('does not restore over a value someone else set later', () {
      // DevTools, for example, takes over debugOnRebuildDirtyWidget.
      final registry = HookRegistry()
        ..replace(read: read, write: write, value: 2);
      slot = 7;
      registry.dispose();
      expect(slot, 7);
    });
  });

  test('dispose twice is safe', () {
    var slot = 1;
    HookRegistry()
      ..replace(read: () => slot, write: (v) => slot = v, value: 2)
      ..dispose()
      ..dispose();
    expect(slot, 1);
  });
}
