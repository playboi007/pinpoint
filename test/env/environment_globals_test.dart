import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 9, build step 2 (last part): the two globals, platform and
/// slow motion, set through HookRegistry.
///
/// Watch out for: `flutter test` fails any test that leaves
/// `debugDefaultTargetPlatformOverride` set or `timeDilation` changed. Every
/// test here ends by disposing the wrapper or resetting the environment in
/// its own body, then checks both globals are back.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> set(
    WidgetTester tester,
    Environment Function(Environment e) change,
  ) async {
    controller.environment.update(change);
    // A platform change reassembles the app after a one-shot timer; a
    // duration lets fake time fire it.
    await tester.pump(Duration.zero);
    await tester.pump();
  }

  Future<void> disposeWrapper(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Releasing the platform reassembles once more, after a one-shot timer.
    await tester.pump(Duration.zero);
    expect(debugDefaultTargetPlatformOverride, isNull);
    expect(timeDilation, 1.0);
  }

  testWidgets('acceptance: disposing the wrapper restores timeDilation to '
      '1.0 and the platform override to null', (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    await set(
      tester,
      (e) =>
          e.copyWith(platform: () => TargetPlatform.iOS, timeDilation: () => 5),
    );
    expect(debugDefaultTargetPlatformOverride, TargetPlatform.iOS);
    expect(timeDilation, 5);

    await disposeWrapper(tester);
  });

  testWidgets('the platform reaches the app after a reassemble, and the '
      "app's ThemeData follows it", (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    expect(_Probe.platform, TargetPlatform.android);

    await set(tester, (e) => e.copyWith(platform: () => TargetPlatform.iOS));
    expect(_Probe.platform, TargetPlatform.iOS);
    expect(_Probe.themePlatform, TargetPlatform.iOS);

    await set(tester, (e) => e.copyWith(platform: () => null));
    expect(debugDefaultTargetPlatformOverride, isNull);
    expect(_Probe.platform, TargetPlatform.android);
    await disposeWrapper(tester);
  });

  testWidgets('only a platform change reassembles the app', (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    final before = _Probe.reassembles;

    await set(tester, (e) => e.copyWith(timeDilation: () => 2));
    await set(tester, (e) => e.copyWith(textScale: () => 1.3));
    expect(_Probe.reassembles, before);

    await set(tester, (e) => e.copyWith(platform: () => TargetPlatform.macOS));
    expect(_Probe.reassembles, before + 1);
    // The same platform again: nothing to do.
    await set(tester, (e) => e.copyWith(textScale: () => 1.5));
    expect(_Probe.reassembles, before + 1);

    controller.environment.reset();
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(_Probe.reassembles, before + 2);
    expect(debugDefaultTargetPlatformOverride, isNull);
    expect(timeDilation, 1.0);
  });

  testWidgets('slow motion: reset puts timeDilation back to 1', (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    for (final step in [2.0, 5.0, 10.0]) {
      await set(tester, (e) => e.copyWith(timeDilation: () => step));
      expect(timeDilation, step);
    }
    controller.environment.reset();
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(timeDilation, 1.0);
  });

  testWidgets('watch out for: a platform change reassembles like hot reload; '
      'the selection is cleared', (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('probe')));
    await tester.pump();
    expect(controller.selection.value, isNotNull);

    await set(tester, (e) => e.copyWith(platform: () => TargetPlatform.iOS));
    expect(controller.selection.value, isNull);
    expect(controller.mode, PinPointMode.picking);
    await disposeWrapper(tester);
  });

  testWidgets('an environment set before the wrapper is built is applied '
      'once it is', (tester) async {
    controller.environment.value = const Environment(
      platform: TargetPlatform.iOS,
      timeDilation: 2,
    );
    await tester.pumpWidget(_App(controller: controller));
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(timeDilation, 2);
    expect(_Probe.platform, TargetPlatform.iOS);
    await disposeWrapper(tester);
  });

  testWidgets('outside web, Android to iOS mounts the wrapper again '
      '(WidgetsApp adds a Shortcuts layer on Apple platforms): the routes '
      'keep their state, the platform stays, one reassemble is enough', (
    tester,
  ) async {
    await tester.pumpWidget(_App(controller: controller));
    final route = tester.state(find.byType(_Probe));
    final wrapper = tester.state(find.byType(PinPointWrapper));
    final before = _Probe.reassembles;

    await set(tester, (e) => e.copyWith(platform: () => TargetPlatform.iOS));
    await tester.pump();
    expect(
      tester.state(find.byType(PinPointWrapper)),
      kIsWeb ? same(wrapper) : isNot(same(wrapper)),
    );
    // The Navigator has a GlobalKey: it moves into the new subtree.
    expect(tester.state(find.byType(_Probe)), same(route));
    // The new wrapper State takes the slot over; the old one's dispose
    // does not put Android back, and nothing reassembles again.
    expect(debugDefaultTargetPlatformOverride, TargetPlatform.iOS);
    expect(_Probe.platform, TargetPlatform.iOS);
    expect(_Probe.reassembles, before + 1);

    await disposeWrapper(tester);
  });

  testWidgets('a disabled wrapper sets no global', (tester) async {
    controller.environment.value = const Environment(
      platform: TargetPlatform.iOS,
      timeDilation: 2,
    );
    await tester.pumpWidget(
      _App(
        controller: controller,
        config: const PinPointConfig(enabled: false),
      ),
    );
    await tester.pump();
    expect(debugDefaultTargetPlatformOverride, isNull);
    expect(timeDilation, 1.0);
  });

  testWidgets('enabled switched off restores the globals', (tester) async {
    await tester.pumpWidget(_App(controller: controller));
    await set(tester, (e) => e.copyWith(timeDilation: () => 5));
    await tester.pumpWidget(
      _App(
        controller: controller,
        config: const PinPointConfig(enabled: false),
      ),
    );
    expect(timeDilation, 1.0);
  });
}

/// Builds its MaterialApp in `build`, as a real app does, so a reassemble
/// makes a new ThemeData with the overridden platform.
class _App extends StatelessWidget {
  const _App({required this.controller, this.config = const PinPointConfig()});

  final PinPointController controller;
  final PinPointConfig config;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(),
    builder: (context, child) =>
        PinPointWrapper(controller: controller, config: config, child: child),
    home: const Scaffold(body: Center(child: _Probe())),
  );
}

class _Probe extends StatefulWidget {
  const _Probe();

  static TargetPlatform? platform;
  static TargetPlatform? themePlatform;
  static int reassembles = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void reassemble() {
    super.reassemble();
    _Probe.reassembles++;
  }

  @override
  Widget build(BuildContext context) {
    _Probe.platform = defaultTargetPlatform;
    _Probe.themePlatform = Theme.of(context).platform;
    return const Text('probe');
  }
}
