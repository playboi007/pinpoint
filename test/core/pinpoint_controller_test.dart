import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/pinpoint_controller.dart';

import '../support/fake_pick.dart';

void main() {
  late PinPointController controller;
  late int notifications;
  final a = fakePick(const Offset(10, 20));
  final b = fakePick(const Offset(3, 4));

  setUp(() {
    controller = PinPointController();
    notifications = 0;
    controller.addListener(() => notifications++);
  });

  tearDown(() => controller.dispose());

  /// Drives [controller] from idle to [target] through allowed steps only.
  void driveTo(PinPointMode target) {
    if (target == PinPointMode.idle) return;
    controller.startPicking();
    if (target == PinPointMode.picking) return;
    controller.select(a);
    if (target == PinPointMode.commenting) return;
    controller.submit();
  }

  test('starts idle, not frozen, with nothing hovered or selected', () {
    expect(controller.mode, PinPointMode.idle);
    expect(controller.isActive, isFalse);
    expect(controller.frozen, isFalse);
    expect(controller.hovered.value, isNull);
    expect(controller.selection.value, isNull);
  });

  group('allowed transitions', () {
    test('idle -> picking', () {
      expect(controller.startPicking(), isTrue);
      expect(controller.mode, PinPointMode.picking);
      expect(controller.isActive, isTrue);
      expect(notifications, 1);
    });

    test('picking -> commenting on select, keeping the pick', () {
      driveTo(PinPointMode.picking);
      expect(controller.select(b), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selection.value, same(b));
    });

    test('commenting -> commenting on select: a new selection', () {
      driveTo(PinPointMode.commenting);
      final before = notifications;
      expect(controller.select(b), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selection.value, same(b));
      expect(notifications, before, reason: 'the mode did not change');
    });

    test('commenting -> sending on submit', () {
      driveTo(PinPointMode.commenting);
      expect(controller.submit(), isTrue);
      expect(controller.mode, PinPointMode.sending);
    });

    test('sending -> idle on success, clearing the selection', () {
      driveTo(PinPointMode.sending);
      expect(controller.sendSucceeded(), isTrue);
      expect(controller.mode, PinPointMode.idle);
      expect(controller.selection.value, isNull);
    });

    test('sending -> commenting on failure, keeping the selection', () {
      driveTo(PinPointMode.sending);
      expect(controller.sendFailed(), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selection.value, same(a));
    });
  });

  group('back (Esc) goes one step back', () {
    final cases = <PinPointMode, PinPointMode>{
      PinPointMode.picking: PinPointMode.idle,
      PinPointMode.commenting: PinPointMode.picking,
      PinPointMode.sending: PinPointMode.commenting,
    };
    for (final MapEntry(key: from, value: to) in cases.entries) {
      test('${from.name} -> ${to.name}', () {
        driveTo(from);
        expect(controller.back(), isTrue);
        expect(controller.mode, to);
      });
    }

    test('is a no-op in idle', () {
      expect(controller.back(), isFalse);
      expect(controller.mode, PinPointMode.idle);
      expect(notifications, 0);
    });

    test('commenting -> picking keeps the selection', () {
      driveTo(PinPointMode.commenting);
      controller.back();
      expect(controller.selection.value, same(a));
    });
  });

  group('refused transitions change nothing and do not notify', () {
    final refused = <String, (PinPointMode, bool Function(PinPointController))>{
      'startPicking from picking': (
        PinPointMode.picking,
        (c) => c.startPicking(),
      ),
      'startPicking from commenting': (
        PinPointMode.commenting,
        (c) => c.startPicking(),
      ),
      'select from idle': (PinPointMode.idle, (c) => c.select(b)),
      'select from sending': (PinPointMode.sending, (c) => c.select(b)),
      'submit from picking': (PinPointMode.picking, (c) => c.submit()),
      'sendSucceeded from commenting': (
        PinPointMode.commenting,
        (c) => c.sendSucceeded(),
      ),
      'sendFailed from idle': (PinPointMode.idle, (c) => c.sendFailed()),
    };
    for (final MapEntry(key: name, value: (from, action)) in refused.entries) {
      test(name, () {
        driveTo(from);
        final before = notifications;
        final selection = controller.selection.value;
        expect(action(controller), isFalse);
        expect(controller.mode, from);
        expect(controller.selection.value, same(selection));
        expect(notifications, before);
      });
    }
  });

  group('toggle and stop', () {
    test('toggle starts picking from idle', () {
      controller.toggle();
      expect(controller.mode, PinPointMode.picking);
    });

    for (final from in [
      PinPointMode.picking,
      PinPointMode.commenting,
      PinPointMode.sending,
    ]) {
      test('toggle from ${from.name} stops', () {
        driveTo(from);
        controller.toggle();
        expect(controller.mode, PinPointMode.idle);
        expect(controller.selection.value, isNull);
        expect(controller.hovered.value, isNull);
      });
    }

    test('stop in idle does not notify', () {
      controller.stop();
      expect(notifications, 0);
    });
  });

  group('hover', () {
    test('is recorded only while picking or commenting', () {
      controller.hover(a);
      expect(controller.hovered.value, isNull);

      controller.startPicking();
      controller.hover(a);
      expect(controller.hovered.value, same(a));

      controller.select(b);
      controller.hover(b);
      expect(controller.hovered.value, same(b), reason: 'commenting');

      controller.submit();
      expect(controller.hovered.value, isNull, reason: 'cleared on sending');
      controller.hover(a);
      expect(controller.hovered.value, isNull);
    });

    test('does not notify mode listeners', () {
      controller.startPicking();
      final before = notifications;
      controller.hover(a);
      controller.hover(b);
      expect(notifications, before);
    });

    test('is cleared when picking stops', () {
      controller.startPicking();
      controller.hover(a);
      controller.stop();
      expect(controller.hovered.value, isNull);
    });
  });

  group('updateSelection (the outline follows its widget)', () {
    test('replaces the selection without a mode notification', () {
      driveTo(PinPointMode.commenting);
      final before = notifications;
      controller.updateSelection(b);
      expect(controller.selection.value, same(b));
      expect(notifications, before);
    });

    test('null (widget unmounted) clears it and returns to picking', () {
      driveTo(PinPointMode.commenting);
      controller.updateSelection(null);
      expect(controller.selection.value, isNull);
      expect(controller.mode, PinPointMode.picking);
    });

    test('does nothing without a selection', () {
      driveTo(PinPointMode.picking);
      controller.updateSelection(b);
      expect(controller.selection.value, isNull);
    });
  });

  group('freeze', () {
    test('toggles and notifies, independent of mode', () {
      controller.toggleFreeze();
      expect(controller.frozen, isTrue);
      expect(notifications, 1);

      controller.startPicking();
      controller.stop();
      expect(controller.frozen, isTrue, reason: 'stop does not unfreeze');

      controller.toggleFreeze();
      expect(controller.frozen, isFalse);
    });
  });

  group('clearSelection (used on reassemble)', () {
    test('drops hover and selection, and returns commenting to picking', () {
      driveTo(PinPointMode.commenting);
      controller.hover(b);
      controller.clearSelection();
      expect(controller.selection.value, isNull);
      expect(controller.hovered.value, isNull);
      expect(controller.mode, PinPointMode.picking);
    });

    test('is a no-op with nothing selected', () {
      controller.clearSelection();
      expect(notifications, 0);
    });
  });
}
