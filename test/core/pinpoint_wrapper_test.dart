import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/toolbar.dart';

/// Milestone 1 acceptance tests for the wrapper.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  /// The app under test, wrapped the way a host app does it: in
  /// `MaterialApp.builder`, above the Navigator.
  Widget host({
    Widget home = const _CounterPage(),
    PinPointConfig config = const PinPointConfig(),
    bool withHome = true,
  }) {
    return MaterialApp(
      builder: (context, child) =>
          PinPointWrapper(config: config, controller: controller, child: child),
      home: withHome ? home : null,
    );
  }

  Finder appBoundary() => find
      .descendant(
        of: find.byType(PinPointWrapper),
        matching: find.byType(RepaintBoundary),
      )
      .first;

  group('acceptance', () {
    testWidgets('a counter keeps its value and its State across toggling', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('increment'));
      await tester.tap(find.text('increment'));
      await tester.pump();
      expect(find.text('count: 2'), findsOneWidget);
      final stateBefore = tester.state(find.byType(_CounterPage));

      for (var i = 0; i < 3; i++) {
        controller.toggle();
        await tester.pump();
        expect(controller.isActive, isTrue);
        controller.toggle();
        await tester.pump();
        expect(controller.isActive, isFalse);
      }

      expect(find.text('count: 2'), findsOneWidget);
      expect(
        tester.state(find.byType(_CounterPage)),
        same(stateBefore),
        reason: 'the app subtree must never remount',
      );
    });

    testWidgets('with enabled: false the wrapper adds nothing', (tester) async {
      const app = _CounterPage();
      await tester.pumpWidget(
        MaterialApp(
          home: PinPointWrapper(
            config: const PinPointConfig(enabled: false),
            controller: controller,
            child: app,
          ),
        ),
      );

      final wrapper = tester.element(find.byType(PinPointWrapper));
      final children = <Element>[];
      wrapper.visitChildren(children.add);
      expect(children, hasLength(1));
      expect(children.single.widget, same(app));
      expect(find.byType(InspectorOverlay), findsNothing);
    });
  });

  group('watch out for', () {
    testWidgets('builder child is null when the app has no home or routes', (
      tester,
    ) async {
      await tester.pumpWidget(host(withHome: false));
      expect(tester.takeException(), isNull);
      expect(find.byType(InspectorOverlay), findsOneWidget);
    });

    testWidgets('the app sees the same tight constraints as without Pinpoint', (
      tester,
    ) async {
      BoxConstraints? seen;
      Widget probe() => LayoutBuilder(
        builder: (context, constraints) {
          seen = constraints;
          return const SizedBox();
        },
      );

      await tester.pumpWidget(
        MaterialApp(builder: (context, child) => probe()),
      );
      final without = seen;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: probe()),
        ),
      );
      final withWrapper = seen;

      expect(without!.isTight, isTrue);
      expect(withWrapper, without);
    });
  });

  group('idle', () {
    testWidgets('taps reach the app through the Pinpoint layer', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('increment'));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);
    });

    testWidgets('schedules no frames', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the app sits inside the app RepaintBoundary', (tester) async {
      await tester.pumpWidget(host());
      expect(
        find.descendant(of: appBoundary(), matching: find.byType(_CounterPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: appBoundary(),
          matching: find.byType(InspectorOverlay),
        ),
        findsNothing,
      );
    });
  });

  group('pointer trap', () {
    testWidgets('acceptance: in picking mode an app button does not fire', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();

      await tester.tap(find.text('increment'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('count: 0'), findsOneWidget);
    });

    testWidgets('a tap alone selects: touch has no hover', (tester) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();

      final at = tester.getCenter(find.text('count: 0'));
      await tester.tapAt(at, kind: PointerDeviceKind.touch);
      await tester.pump();

      expect(controller.mode, PinPointMode.commenting);
      expect(controller.selection.value?.position, at);
    });

    testWidgets('mouse hover is reported while picking', (tester) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(40, 50));
      await mouse.moveTo(const Offset(60, 70));
      await tester.pump();
      expect(controller.hovered.value?.position, const Offset(60, 70));
    });

    testWidgets('a secondary click does not select', (tester) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();

      await tester.tapAt(
        const Offset(50, 50),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(controller.mode, PinPointMode.picking);
    });

    testWidgets('the trap stays while commenting', (tester) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);

      await tester.tap(find.text('increment'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('count: 0'), findsOneWidget);
    });

    testWidgets(
      'acceptance: dialogs and pushed routes render beneath the trap',
      (tester) async {
        await tester.pumpWidget(host(home: const _DialogPage()));
        await tester.tap(find.text('open dialog'));
        await tester.pumpAndSettle();
        expect(find.text('in dialog'), findsOneWidget);

        controller.startPicking();
        await tester.pump();

        // A hit test at the dialog's button reaches Pinpoint's trap and
        // nothing of the dialog: the Stack stops at its topmost hit child.
        final result = HitTestResult();
        tester.binding.hitTestInView(
          result,
          tester.getCenter(find.text('in dialog')),
          tester.view.viewId,
        );
        final targets = [for (final entry in result.path) entry.target];
        final trap = tester.renderObject(find.byKey(InspectorOverlay.trapKey));
        expect(targets, contains(same(trap)));
        expect(
          targets,
          isNot(contains(same(tester.renderObject(find.text('in dialog'))))),
        );

        // Neither the button nor the barrier react.
        await tester.tap(find.text('in dialog'), warnIfMissed: false);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.text('in dialog'), findsOneWidget);
        expect(find.text('dialog taps: 0'), findsOneWidget);

        // The dialog is part of the app, inside its RepaintBoundary.
        expect(
          find.descendant(of: appBoundary(), matching: find.text('in dialog')),
          findsOneWidget,
        );
      },
    );
  });

  group('keyboard', () {
    late List<LogicalKeyboardKey> appKeys;
    late FocusNode field;
    late ValueNotifier<bool> showField;

    setUp(() {
      appKeys = [];
      field = FocusNode(debugLabel: 'app field');
      showField = ValueNotifier<bool>(true);
    });
    tearDown(() {
      field.dispose();
      showField.dispose();
    });

    Widget keyHost({PinPointConfig config = const PinPointConfig()}) => host(
      config: config,
      home: _KeyPage(field: field, showField: showField, seen: appKeys),
    );

    Future<void> pressShortcut(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
    }

    testWidgets(
      'acceptance: the shortcut works while an app TextField has focus, '
      'and Esc returns to idle',
      (tester) async {
        await tester.pumpWidget(keyHost());
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(field.hasPrimaryFocus, isTrue);

        await pressShortcut(tester);
        expect(controller.mode, PinPointMode.picking);
        expect(field.hasFocus, isFalse, reason: 'the field stops getting keys');

        // Keys typed while picking never reach the app, and Tab does not
        // move focus back into it.
        appKeys.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(appKeys, isEmpty);
        expect(field.hasFocus, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(controller.mode, PinPointMode.idle);
        expect(field.hasPrimaryFocus, isTrue, reason: 'focus is restored');
        expect(appKeys, isEmpty, reason: 'Pinpoint used that Esc');

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        expect(appKeys, [LogicalKeyboardKey.keyA]);
      },
    );

    testWidgets('Esc in idle is left to the app', (tester) async {
      await tester.pumpWidget(keyHost());
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(appKeys, [LogicalKeyboardKey.escape]);
      expect(controller.mode, PinPointMode.idle);
    });

    testWidgets('Esc steps back from commenting to picking', (tester) async {
      await tester.pumpWidget(keyHost());
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.mode, PinPointMode.picking);
    });

    testWidgets('the shortcut toggles back to idle', (tester) async {
      await tester.pumpWidget(keyHost());
      await pressShortcut(tester);
      expect(controller.mode, PinPointMode.picking);
      await pressShortcut(tester);
      expect(controller.mode, PinPointMode.idle);
    });

    testWidgets('the shortcut is configurable', (tester) async {
      await tester.pumpWidget(
        keyHost(
          config: const PinPointConfig(
            shortcut: PinPointShortcut(
              LogicalKeyboardKey.keyK,
              physicalKey: PhysicalKeyboardKey.keyK,
              control: true,
            ),
          ),
        ),
      );

      await pressShortcut(tester);
      expect(controller.mode, PinPointMode.idle);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.mode, PinPointMode.picking);
    });

    testWidgets('focus is not restored to a field that was removed', (
      tester,
    ) async {
      await tester.pumpWidget(keyHost());
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await pressShortcut(tester);

      showField.value = false;
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(controller.mode, PinPointMode.idle);
      expect(field.hasFocus, isFalse);
    });

    testWidgets('disposing the wrapper removes the key handler', (
      tester,
    ) async {
      await tester.pumpWidget(keyHost());
      await tester.pumpWidget(const SizedBox());

      await pressShortcut(tester);
      expect(controller.mode, PinPointMode.idle);
    });

    testWidgets('a disabled wrapper installs no key handler', (tester) async {
      await tester.pumpWidget(
        keyHost(config: const PinPointConfig(enabled: false)),
      );
      await pressShortcut(tester);
      expect(controller.mode, PinPointMode.idle);
    });
  });

  group('launcher', () {
    testWidgets('shows bottom-right, outside the app boundary', (tester) async {
      await tester.pumpWidget(host());
      final rect = tester.getRect(find.byType(PinPointLauncher));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.right, lessThan(screen.width));
      expect(rect.right, greaterThan(screen.width - 40 - rect.width));
      expect(rect.bottom, greaterThan(screen.height - 40 - rect.height));
      expect(
        find.descendant(
          of: appBoundary(),
          matching: find.byType(PinPointLauncher),
        ),
        findsNothing,
      );
    });

    testWidgets('a tap starts picking, a second tap stops', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byType(PinPointLauncher));
      await tester.pump();
      expect(controller.mode, PinPointMode.picking);

      // The launcher sits above the trap, so it still takes the tap.
      await tester.tap(find.byType(PinPointLauncher));
      await tester.pump();
      expect(controller.mode, PinPointMode.idle);
    });

    testWidgets('names the shortcut in its tooltip', (tester) async {
      await tester.pumpWidget(host());
      expect(find.byTooltip('Pinpoint (Alt+Shift+C)'), findsOneWidget);
    });

    testWidgets('drags, and stays inside the viewport', (tester) async {
      await tester.pumpWidget(host());
      final start = tester.getRect(find.byType(PinPointLauncher));

      await tester.drag(
        find.byType(PinPointLauncher),
        const Offset(-200, -100),
      );
      await tester.pump();
      final moved = tester.getRect(find.byType(PinPointLauncher));
      expect(moved.topLeft, start.topLeft + const Offset(-200, -100));
      expect(controller.mode, PinPointMode.idle, reason: 'a drag is no tap');

      await tester.drag(
        find.byType(PinPointLauncher),
        const Offset(-5000, -5000),
      );
      await tester.pump();
      final clamped = tester.getRect(find.byType(PinPointLauncher));
      expect(clamped.left, greaterThanOrEqualTo(0));
      expect(clamped.top, greaterThanOrEqualTo(0));
    });

    testWidgets('is hidden with showLauncher: false', (tester) async {
      await tester.pumpWidget(
        host(config: const PinPointConfig(showLauncher: false)),
      );
      expect(find.byType(PinPointLauncher), findsNothing);
    });
  });

  group('freeze', () {
    double spin(WidgetTester tester) =>
        tester.state<_SpinnerState>(find.byType(_Spinner)).animation.value;

    testWidgets('P while picking pauses the app tickers and resumes them', (
      tester,
    ) async {
      await tester.pumpWidget(host(home: const _Spinner()));
      final stateBefore = tester.state(find.byType(_Spinner));
      controller.startPicking();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(controller.frozen, isTrue);
      final frozenAt = spin(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(spin(tester), frozenAt);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.frozen, isFalse);
      expect(spin(tester), isNot(frozenAt));

      expect(controller.mode, PinPointMode.picking);
      expect(tester.state(find.byType(_Spinner)), same(stateBefore));
    });

    testWidgets('a frozen app schedules no frames', (tester) async {
      await tester.pumpWidget(host(home: const _Spinner()));
      controller.toggleFreeze();
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('only the app is frozen, not Pinpoint UI', (tester) async {
      await tester.pumpWidget(host(home: const _Spinner()));
      controller.toggleFreeze();
      await tester.pump();

      expect(
        TickerMode.valuesOf(tester.element(find.byType(_Spinner))).enabled,
        isFalse,
      );
      expect(
        TickerMode.valuesOf(tester.element(find.byType(PinPointLauncher)))
            .enabled,
        isTrue,
      );
    });

    testWidgets('the launcher shows that the app is frozen', (tester) async {
      await tester.pumpWidget(host());
      expect(find.byIcon(Icons.ac_unit), findsNothing);
      controller.toggleFreeze();
      await tester.pump();
      expect(find.byIcon(Icons.ac_unit), findsOneWidget);
    });

    testWidgets('P in idle is left to the app', (tester) async {
      await tester.pumpWidget(host());
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      expect(controller.frozen, isFalse);
    });
  });

  testWidgets('hot reload clears hover and selection', (tester) async {
    await tester.pumpWidget(host());
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    // Away from the panel, which opens next to the selection.
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(const Offset(720, 520));
    await tester.pump();
    expect(controller.selection.value, isNotNull);
    expect(controller.hovered.value, isNotNull);

    // reassembleApplication() completes at the end of the next frame, so
    // pump that frame before awaiting it, or the test hangs.
    final reassembled = tester.binding.reassembleApplication();
    await tester.pump();
    await reassembled;

    expect(controller.selection.value, isNull);
    expect(controller.hovered.value, isNull);
    expect(controller.mode, PinPointMode.picking);
  });
}

/// An endlessly repeating animation, like a loading spinner.
class _Spinner extends StatefulWidget {
  const _Spinner();

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// An app page that records every key down event that reaches it.
class _KeyPage extends StatelessWidget {
  const _KeyPage({
    required this.field,
    required this.showField,
    required this.seen,
  });

  final FocusNode field;
  final ValueListenable<bool> showField;
  final List<LogicalKeyboardKey> seen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) seen.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: showField,
          builder: (context, show, _) => Column(
            children: [
              if (show) TextField(focusNode: field),
              const Text('below the field'),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogPage extends StatefulWidget {
  const _DialogPage();

  @override
  State<_DialogPage> createState() => _DialogPageState();
}

class _DialogPageState extends State<_DialogPage> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: StatefulBuilder(
                builder: (context, setDialogState) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('dialog taps: $_taps'),
                    TextButton(
                      onPressed: () => setDialogState(() => _taps++),
                      child: const Text('in dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          child: const Text('open dialog'),
        ),
      ),
    );
  }
}

class _CounterPage extends StatefulWidget {
  const _CounterPage();

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('count: $_count'),
            ElevatedButton(
              onPressed: () => setState(() => _count++),
              child: const Text('increment'),
            ),
          ],
        ),
      ),
    );
  }
}
