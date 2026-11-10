import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/env/device_presets.dart';
import 'package:pinpoint/src/overlay/environment_panel.dart';

/// Milestone 9, build step 3: the what-if panel and the override chip.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  final light = ThemeData(colorSchemeSeed: Colors.indigo);
  final dark = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.dark,
  );

  /// A window large enough for the whole panel: the test font is wide.
  Future<void> pumpHost(
    WidgetTester tester, {
    ThemeData? theme,
    PinPointConfig config = const PinPointConfig(),
  }) async {
    tester.view.physicalSize = const Size(1400, 1400) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? light,
        darkTheme: dark,
        builder: (context, child) => PinPointWrapper(
          controller: controller,
          config: config,
          child: child,
        ),
        home: const Scaffold(body: Center(child: Text('app'))),
      ),
    );
  }

  Future<void> openPanel(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
    await tester.tap(find.byKey(EnvironmentBar.toggleKey));
    await tester.pump();
    expect(find.byKey(EnvironmentPanel.panelKey), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String section, String value) async {
    final option = find.byKey(EnvironmentPanel.option(section, value));
    await tester.ensureVisible(option);
    await tester.pump();
    await tester.tap(option);
    // A platform change reassembles after a one-shot timer.
    await tester.pump(Duration.zero);
    await tester.pump();
  }

  Environment env() => controller.environment.value;

  group('the bar', () {
    testWidgets('is hidden while idle with nothing overridden', (tester) async {
      await pumpHost(tester);
      expect(find.byKey(EnvironmentBar.barKey), findsNothing);
      controller.startPicking();
      await tester.pump();
      expect(find.byKey(EnvironmentBar.barKey), findsOneWidget);
    });

    testWidgets('stays while idle with an override, names it, and resets in '
        'one click', (tester) async {
      await pumpHost(tester);
      controller.environment.value = const Environment(
        viewport: Size(360, 800),
        textScale: 1.5,
      );
      await tester.pump();
      expect(controller.isActive, isFalse);
      expect(find.byKey(EnvironmentBar.barKey), findsOneWidget);
      expect(find.textContaining('360 × 800 · text 1.5×'), findsOneWidget);

      await tester.tap(find.byKey(EnvironmentBar.resetKey));
      await tester.pump();
      expect(env(), Environment.none);
      expect(find.byKey(EnvironmentBar.barKey), findsNothing);
    });

    testWidgets('in idle, a click on it starts picking and opens the panel', (
      tester,
    ) async {
      await pumpHost(tester);
      controller.environment.value = const Environment(textScale: 2);
      await tester.pump();
      await tester.tap(find.byKey(EnvironmentBar.toggleKey));
      await tester.pump();
      expect(controller.mode, PinPointMode.picking);
      expect(find.byKey(EnvironmentPanel.panelKey), findsOneWidget);
    });

    testWidgets('an idle app with the bar shown schedules no frames', (
      tester,
    ) async {
      await pumpHost(tester);
      controller.environment.value = const Environment(textScale: 2);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('the panel', () {
    testWidgets('closes when picking stops, and a click on it never picks', (
      tester,
    ) async {
      await pumpHost(tester);
      await openPanel(tester);
      await tester.tap(
        find.byKey(EnvironmentPanel.panelKey),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(controller.selection.value, isNull);
      controller.stop();
      await tester.pump();
      expect(find.byKey(EnvironmentPanel.panelKey), findsNothing);
    });

    testWidgets('viewport presets, rotate, and free width and height', (
      tester,
    ) async {
      await pumpHost(tester);
      await openPanel(tester);
      await choose(tester, 'viewport', '360x800');
      expect(env().viewport, const Size(360, 800));
      expect(find.byKey(EnvironmentPanel.widthKey), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(EnvironmentPanel.widthKey))
            .controller!
            .text,
        '360',
      );

      await tester.tap(find.byKey(EnvironmentPanel.rotateKey));
      await tester.pump();
      expect(env().viewport, const Size(800, 360));

      await tester.enterText(find.byKey(EnvironmentPanel.widthKey), '500');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(env().viewport, const Size(500, 360));

      await choose(tester, 'viewport', 'window');
      expect(env().viewport, isNull);
    });

    testWidgets('every preset is offered', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      for (final preset in devicePresets) {
        final w = preset.size.width.toInt();
        final h = preset.size.height.toInt();
        expect(
          find.byKey(EnvironmentPanel.option('viewport', '${w}x$h')),
          findsOneWidget,
        );
      }
    });

    testWidgets('text scale, bold, safe area, keyboard, direction, theme and '
        'slow motion', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      await choose(tester, 'textScale', '2');
      expect(env().textScale, 2);
      await choose(tester, 'bold', 'switch');
      expect(env().boldText, isTrue);
      await choose(tester, 'safeArea', 'notch');
      expect(env().safeArea, notchSafeArea);
      await choose(tester, 'keyboard', 'switch');
      expect(env().keyboardHeight, fakeKeyboardHeight);
      await choose(tester, 'direction', 'rtl');
      expect(env().textDirection, TextDirection.rtl);
      await choose(tester, 'theme', 'dark');
      expect(env().brightness, Brightness.dark);
      await choose(tester, 'slow', '5');
      expect(env().timeDilation, 5);
      expect(timeDilation, 5);

      await choose(tester, 'textScale', 'system');
      expect(env().textScale, isNull);
      await choose(tester, 'slow', '1');
      expect(env().timeDilation, isNull);

      final reset = find.byKey(EnvironmentPanel.resetAllKey);
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pump();
      expect(env(), Environment.none);
      expect(timeDilation, 1.0);
    });

    testWidgets('a custom safe area from the top and bottom fields', (
      tester,
    ) async {
      await pumpHost(tester);
      await openPanel(tester);
      final top = find.byKey(EnvironmentPanel.safeTopKey);
      await tester.ensureVisible(top);
      await tester.enterText(top, '24');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(env().safeArea, const EdgeInsets.only(top: 24));
    });

    testWidgets('platform: iOS, then back to the system', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      await choose(tester, 'platform', 'iOS');
      expect(env().platform, TargetPlatform.iOS);
      await tester.pump();
      expect(debugDefaultTargetPlatformOverride, TargetPlatform.iOS);
      // Outside web, Android to iOS mounts the wrapper again (see
      // EnvironmentGlobals.reassemble): the panel's open state is new.
      if (!kIsWeb) {
        await tester.tap(find.byKey(EnvironmentBar.toggleKey));
        await tester.pump();
      }
      // `flutter test` fails a test that leaves the override set: put it
      // back in this test's own body.
      await choose(tester, 'platform', 'system');
      await tester.pump();
      expect(debugDefaultTargetPlatformOverride, isNull);
    });

    testWidgets('lists config.themeVariants instead of light and dark', (
      tester,
    ) async {
      final brand = ThemeData(colorSchemeSeed: Colors.teal);
      await pumpHost(
        tester,
        config: PinPointConfig(themeVariants: {'Brand': brand}),
      );
      await openPanel(tester);
      expect(
        find.byKey(EnvironmentPanel.option('theme', 'dark')),
        findsNothing,
      );
      await choose(tester, 'theme', 'Brand');
      expect(env().themeVariant, 'Brand');
    });

    testWidgets('a seed color in a Material 3 app', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      final hex = formatSeed(seedColors[2]);
      await choose(tester, 'seed', hex);
      expect(env().seedColor, seedColors[2]);
    });

    testWidgets('watch out for: the color scheme switch is Material 3 only', (
      tester,
    ) async {
      await pumpHost(
        tester,
        theme: ThemeData(useMaterial3: false, primarySwatch: Colors.green),
      );
      await openPanel(tester);
      final chip = tester.widget<ChoiceChip>(
        find.byKey(EnvironmentPanel.option('seed', formatSeed(seedColors[0]))),
      );
      expect(chip.onSelected, isNull, reason: 'disabled in Material 2');
      expect(find.textContaining('Material 3 only'), findsOneWidget);
    });

    testWidgets('Esc in a panel field goes back, as everywhere in Pinpoint, '
        'without an error', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      await tester.tap(find.byKey(EnvironmentPanel.widthKey));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
