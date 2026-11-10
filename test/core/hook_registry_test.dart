import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/env/environment_controller.dart';
import 'package:pinpoint/src/env/environment_host.dart';

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

  group('slot', () {
    late int slot;
    int read() => slot;
    void write(int value) => slot = value;

    setUp(() => slot = 1);

    test('keeps the value from before the first write', () {
      final registry = HookRegistry();
      final handle = registry.slot(key: #test, read: read, write: write);
      handle
        ..set(2)
        ..set(3);
      expect(slot, 3);
      registry.dispose();
      expect(slot, 1);
    });

    test('release restores now, and a later set holds again', () {
      final registry = HookRegistry();
      final handle = registry.slot(key: #test, read: read, write: write)
        ..set(2);
      handle.release();
      expect(slot, 1);
      expect(handle.isHeld, isFalse);
      handle.set(4);
      registry.dispose();
      expect(slot, 1);
    });

    test('a second holder takes over and keeps the original value: the '
        "first one's dispose changes nothing", () {
      // A wrapper State mounted again: the new one writes before the old
      // one is disposed.
      final first = HookRegistry();
      final second = HookRegistry();
      first.slot(key: #test, read: read, write: write).set(2);
      second.slot(key: #test, read: read, write: write).set(2);
      first.dispose();
      expect(slot, 2);
      second.dispose();
      expect(slot, 1);
    });

    test('does not restore over a value someone else set later', () {
      final registry = HookRegistry();
      registry.slot(key: #test, read: read, write: write).set(2);
      slot = 7;
      registry.dispose();
      expect(slot, 7);
    });
  });

  // Every slot of the environment (Milestone 9). The test restores them in
  // its own body: `flutter test` fails a test that leaves
  // debugDefaultTargetPlatformOverride set or timeDilation changed.
  testWidgets('the environment globals are restored on dispose', (
    tester,
  ) async {
    final registry = HookRegistry();
    EnvironmentGlobals(
      registry,
    ).apply(const Environment(platform: TargetPlatform.iOS, timeDilation: 5));
    expect(debugDefaultTargetPlatformOverride, TargetPlatform.iOS);
    expect(timeDilation, 5);
    // The platform change reassembles the app; let that frame finish.
    await tester.pump();

    registry.dispose();
    expect(debugDefaultTargetPlatformOverride, isNull);
    expect(timeDilation, 1.0);
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
