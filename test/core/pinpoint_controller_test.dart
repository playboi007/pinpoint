import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/pinpoint_controller.dart';

void main() {
  late PinPointController controller;
  late int notifications;

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
    controller.select(const Offset(10, 20));
    if (target == PinPointMode.commenting) return;
    controller.submit();
  }

  test('starts idle, not frozen, with nothing hovered or selected', () {
    expect(controller.mode, PinPointMode.idle);
    expect(controller.isActive, isFalse);
    expect(controller.frozen, isFalse);
    expect(controller.hovered.value, isNull);
    expect(controller.selectedPosition, isNull);
  });

  group('allowed transitions', () {
    test('idle -> picking', () {
      expect(controller.startPicking(), isTrue);
      expect(controller.mode, PinPointMode.picking);
      expect(controller.isActive, isTrue);
      expect(notifications, 1);
    });

    test('picking -> commenting on select, keeping the position', () {
      driveTo(PinPointMode.picking);
      expect(controller.select(const Offset(3, 4)), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selectedPosition, const Offset(3, 4));
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
      expect(controller.selectedPosition, isNull);
    });

    test('sending -> commenting on failure, keeping the selection', () {
      driveTo(PinPointMode.sending);
      expect(controller.sendFailed(), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selectedPosition, const Offset(10, 20));
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
      expect(controller.selectedPosition, const Offset(10, 20));
    });
  });

  group('refused transitions change nothing and do not notify', () {
    final refused = <String, (PinPointMode, bool Function(PinPointController))>{
      'startPicking from picking': (PinPointMode.picking, (c) => c.startPicking()),
      'startPicking from commenting': (PinPointMode.commenting, (c) => c.startPicking()),
      'select from idle': (PinPointMode.idle, (c) => c.select(Offset.zero)),
      'select from commenting': (PinPointMode.commenting, (c) => c.select(Offset.zero)),
      'submit from picking': (PinPointMode.picking, (c) => c.submit()),
      'sendSucceeded from commenting': (PinPointMode.commenting, (c) => c.sendSucceeded()),
      'sendFailed from idle': (PinPointMode.idle, (c) => c.sendFailed()),
    };
    for (final MapEntry(key: name, value: (from, action)) in refused.entries) {
      test(name, () {
        driveTo(from);
        final before = notifications;
        final position = controller.selectedPosition;
        expect(action(controller), isFalse);
        expect(controller.mode, from);
        expect(controller.selectedPosition, position);
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
        expect(controller.selectedPosition, isNull);
        expect(controller.hovered.value, isNull);
      });
    }

    test('stop in idle does not notify', () {
      controller.stop();
      expect(notifications, 0);
    });
  });

  group('hover', () {
    test('is recorded only while picking', () {
      controller.hover(const Offset(1, 1));
      expect(controller.hovered.value, isNull);

      controller.startPicking();
      controller.hover(const Offset(5, 6));
      expect(controller.hovered.value, const Offset(5, 6));
    });

    test('does not notify mode listeners', () {
      controller.startPicking();
      final before = notifications;
      controller.hover(const Offset(5, 6));
      controller.hover(const Offset(7, 8));
      expect(notifications, before);
    });

    test('is cleared when picking ends', () {
      controller.startPicking();
      controller.hover(const Offset(5, 6));
      controller.select(const Offset(5, 6));
      expect(controller.hovered.value, isNull);
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
    test('drops the selection and returns commenting to picking', () {
      driveTo(PinPointMode.commenting);
      controller.clearSelection();
      expect(controller.selectedPosition, isNull);
      expect(controller.mode, PinPointMode.picking);
    });

    test('is a no-op with nothing selected', () {
      controller.clearSelection();
      expect(notifications, 0);
    });
  });
}
