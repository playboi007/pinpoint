import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/keymap.dart';
import 'package:pinpoint/src/core/pinpoint_controller.dart';

void main() {
  const none = (alt: false, shift: false, control: false, meta: false);
  const altShift = (alt: true, shift: true, control: false, meta: false);

  KeyEvent down(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
      KeyDownEvent(
        logicalKey: logical,
        physicalKey: physical,
        timeStamp: Duration.zero,
      );

  final keyC = down(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC);
  final escape = down(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
  final keyP = down(LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP);

  KeyAction? action(
    KeyEvent event,
    PinPointMode mode, {
    KeyModifiers modifiers = none,
    PinPointShortcut shortcut = PinPointShortcut.altShiftC,
  }) =>
      keyActionFor(event, mode: mode, shortcut: shortcut, modifiers: modifiers);

  group('shortcut', () {
    test('Alt+Shift+C toggles in every mode', () {
      for (final mode in PinPointMode.values) {
        expect(action(keyC, mode, modifiers: altShift), KeyAction.toggle);
      }
    });

    test('needs the exact modifiers', () {
      expect(action(keyC, PinPointMode.idle), isNull);
      expect(
        action(
          keyC,
          PinPointMode.idle,
          modifiers: (alt: true, shift: false, control: false, meta: false),
        ),
        isNull,
      );
      expect(
        action(
          keyC,
          PinPointMode.idle,
          modifiers: (alt: true, shift: true, control: true, meta: false),
        ),
        isNull,
        reason: 'extra modifiers do not match',
      );
    });

    test('matches the physical key when Alt changes the logical key', () {
      // On macOS, Option+Shift+C types "Ç"; on web the logical key can follow
      // the produced character.
      final cedilla = down(
        const LogicalKeyboardKey(0x000000c7),
        PhysicalKeyboardKey.keyC,
      );
      expect(
        action(cedilla, PinPointMode.idle, modifiers: altShift),
        KeyAction.toggle,
      );
    });

    test('repeat events still match, key up does not', () {
      final repeat = KeyRepeatEvent(
        logicalKey: LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        timeStamp: Duration.zero,
      );
      final up = KeyUpEvent(
        logicalKey: LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        timeStamp: Duration.zero,
      );
      expect(
        action(repeat, PinPointMode.idle, modifiers: altShift),
        KeyAction.toggle,
      );
      expect(action(up, PinPointMode.idle, modifiers: altShift), isNull);
    });

    test('is configurable', () {
      const ctrlK = PinPointShortcut(
        LogicalKeyboardKey.keyK,
        physicalKey: PhysicalKeyboardKey.keyK,
        control: true,
      );
      final keyK = down(LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK);
      expect(
        action(
          keyK,
          PinPointMode.idle,
          shortcut: ctrlK,
          modifiers: (alt: false, shift: false, control: true, meta: false),
        ),
        KeyAction.toggle,
      );
      expect(
        action(keyC, PinPointMode.idle, shortcut: ctrlK, modifiers: altShift),
        isNull,
      );
    });

    test('has a readable label', () {
      expect(PinPointShortcut.altShiftC.label, 'Alt+Shift+C');
    });
  });

  group('Esc', () {
    test('goes back in every active mode', () {
      for (final mode in PinPointMode.values.skip(1)) {
        expect(action(escape, mode), KeyAction.back, reason: mode.name);
      }
    });

    test('is left to the app in idle', () {
      expect(action(escape, PinPointMode.idle), isNull);
    });
  });

  group('P', () {
    test('freezes only while picking', () {
      expect(action(keyP, PinPointMode.picking), KeyAction.freeze);
      expect(action(keyP, PinPointMode.idle), isNull);
      // The comment field (Milestone 5) needs a plain P.
      expect(action(keyP, PinPointMode.commenting), isNull);
    });

    test('ignores P with modifiers', () {
      expect(
        action(
          keyP,
          PinPointMode.picking,
          modifiers: (alt: false, shift: false, control: true, meta: false),
        ),
        isNull,
      );
    });
  });

  group('chain navigation (Milestone 3)', () {
    const alt = (alt: true, shift: false, control: false, meta: false);
    final up = down(LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp);
    final arrowDown = down(
      LogicalKeyboardKey.arrowDown,
      PhysicalKeyboardKey.arrowDown,
    );
    final open = down(
      LogicalKeyboardKey.bracketLeft,
      PhysicalKeyboardKey.bracketLeft,
    );
    final close = down(
      LogicalKeyboardKey.bracketRight,
      PhysicalKeyboardKey.bracketRight,
    );
    const selecting = [PinPointMode.picking, PinPointMode.commenting];

    test('Arrow Up and [ go to the next local ancestor', () {
      for (final mode in selecting) {
        expect(action(up, mode), KeyAction.chainUp);
        expect(action(open, mode), KeyAction.chainUp);
      }
    });

    test('Arrow Down and ] go back toward the picked widget', () {
      for (final mode in selecting) {
        expect(action(arrowDown, mode), KeyAction.chainDown);
        expect(action(close, mode), KeyAction.chainDown);
      }
    });

    test('Alt plus an arrow steps through the full chain', () {
      for (final mode in selecting) {
        expect(action(up, mode, modifiers: alt), KeyAction.chainUpAll);
        expect(action(arrowDown, mode, modifiers: alt), KeyAction.chainDownAll);
      }
    });

    test('brackets match the physical key on other layouts', () {
      // On a German layout the key right of P types "ü".
      final umlaut = down(
        const LogicalKeyboardKey(0x000000fc),
        PhysicalKeyboardKey.bracketLeft,
      );
      expect(action(umlaut, PinPointMode.picking), KeyAction.chainUp);
    });

    test('left to the app in idle and while sending', () {
      for (final mode in [PinPointMode.idle, PinPointMode.sending]) {
        expect(action(up, mode), isNull);
        expect(action(open, mode), isNull);
        expect(action(up, mode, modifiers: alt), isNull);
      }
    });

    test('other modifiers do not match', () {
      expect(
        action(
          up,
          PinPointMode.picking,
          modifiers: (alt: false, shift: true, control: false, meta: false),
        ),
        isNull,
      );
      expect(action(open, PinPointMode.picking, modifiers: alt), isNull);
    });

    test('repeats match, so holding a key keeps moving', () {
      final repeat = KeyRepeatEvent(
        logicalKey: LogicalKeyboardKey.arrowUp,
        physicalKey: PhysicalKeyboardKey.arrowUp,
        timeStamp: Duration.zero,
      );
      expect(action(repeat, PinPointMode.picking), KeyAction.chainUp);
      expect(KeyAction.chainUp.repeats, isTrue);
      expect(KeyAction.toggle.repeats, isFalse);
    });
  });

  test('other keys are never claimed', () {
    final keyA = down(LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA);
    for (final mode in PinPointMode.values) {
      expect(action(keyA, mode), isNull);
    }
  });
}
