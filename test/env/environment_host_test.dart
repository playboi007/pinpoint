import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/env/device_presets.dart';
import 'package:pinpoint/src/env/environment_host.dart';

/// Milestone 9, build step 2: what the environment host provides. Each test
/// reads a probe inside the app.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  final light = ThemeData(colorSchemeSeed: Colors.indigo);
  final dark = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.dark,
  );

  Widget host(
    Widget home, {
    ThemeData? theme,
    ThemeData? darkTheme,
    PinPointConfig config = const PinPointConfig(),
  }) => MaterialApp(
    theme: theme,
    darkTheme: darkTheme,
    builder: (context, child) =>
        PinPointWrapper(controller: controller, config: config, child: child),
    home: home,
  );

  Future<void> set(
    WidgetTester tester,
    Environment Function(Environment e) change,
  ) async {
    controller.environment.update(change);
    await tester.pump();
  }

  BuildContext probe(WidgetTester tester) =>
      tester.element(find.byKey(_probeKey).first);

  group('acceptance', () {
    testWidgets('text scale 2.0 enlarges text on every route, including an '
        'open dialog', (tester) async {
      await tester.pumpWidget(host(const _DialogPage()));
      final page = find.text('page text');
      final pageHeight = tester.getSize(page).height;

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final dialog = find.text('dialog text');
      final dialogHeight = tester.getSize(dialog).height;

      await set(tester, (e) => e.copyWith(textScale: () => 2.0));
      expect(tester.getSize(dialog).height, closeTo(dialogHeight * 2, 0.5));
      expect(tester.getSize(page).height, closeTo(pageHeight * 2, 0.5));

      // A pushed route too.
      Navigator.of(tester.element(dialog)).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(page)).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('second route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.text('second route')).height,
        closeTo(pageHeight * 2, 0.5),
      );
    });

    testWidgets('RTL flips a Row with MainAxisAlignment.start', (tester) async {
      await tester.pumpWidget(
        host(
          const Scaffold(
            body: Row(
              children: [SizedBox(key: _probeKey, width: 50, height: 50)],
            ),
          ),
        ),
      );
      expect(tester.getRect(find.byKey(_probeKey)).left, 0);

      await set(
        tester,
        (e) => e.copyWith(textDirection: () => TextDirection.rtl),
      );
      expect(tester.getRect(find.byKey(_probeKey)).right, 800);
      expect(Directionality.of(probe(tester)), TextDirection.rtl);
    });

    testWidgets('the fake keyboard makes a Scaffold with '
        'resizeToAvoidBottomInset shrink its body', (tester) async {
      await tester.pumpWidget(
        host(const Scaffold(body: SizedBox.expand(key: _probeKey))),
      );
      final before = tester.getSize(find.byKey(_probeKey)).height;

      await set(
        tester,
        (e) => e.copyWith(keyboardHeight: () => fakeKeyboardHeight),
      );
      expect(
        tester.getSize(find.byKey(_probeKey)).height,
        before - fakeKeyboardHeight,
      );
      // The Scaffold removes the insets for its body, so read them above it.
      expect(
        MediaQuery.viewInsetsOf(tester.element(find.byType(Scaffold))).bottom,
        fakeKeyboardHeight,
      );
    });

    testWidgets("dark mode uses the app's own darkTheme", (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(key: _probeKey),
          theme: light,
          darkTheme: dark,
        ),
      );
      expect(Theme.of(probe(tester)).brightness, Brightness.light);

      await set(tester, (e) => e.copyWith(brightness: () => Brightness.dark));
      final theme = Theme.of(probe(tester));
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme, dark.colorScheme);
      // Apps that read the platform brightness agree with the theme.
      expect(MediaQuery.platformBrightnessOf(probe(tester)), Brightness.dark);

      await set(tester, (e) => e.copyWith(brightness: () => null));
      expect(Theme.of(probe(tester)).colorScheme, light.colorScheme);
    });
  });

  group('switches', () {
    testWidgets('bold text', (tester) async {
      await tester.pumpWidget(host(const SizedBox(key: _probeKey)));
      expect(MediaQuery.boldTextOf(probe(tester)), isFalse);
      await set(tester, (e) => e.copyWith(boldText: () => true));
      expect(MediaQuery.boldTextOf(probe(tester)), isTrue);
    });

    testWidgets('safe areas: notch, then none', (tester) async {
      await tester.pumpWidget(
        host(
          const Scaffold(
            body: SafeArea(child: SizedBox.expand(key: _probeKey)),
          ),
        ),
      );
      await set(tester, (e) => e.copyWith(safeArea: () => notchSafeArea));
      // The app's SafeArea, not the one of Pinpoint's what-if bar.
      final media = MediaQuery.of(
        tester.element(
          find.descendant(
            of: find.byType(Scaffold),
            matching: find.byType(SafeArea),
          ),
        ),
      );
      expect(media.padding, notchSafeArea);
      expect(media.viewPadding, notchSafeArea);
      expect(tester.getRect(find.byKey(_probeKey)).top, 59);
      expect(tester.getRect(find.byKey(_probeKey)).bottom, 600 - 34);

      await set(tester, (e) => e.copyWith(safeArea: () => EdgeInsets.zero));
      expect(
        tester.getRect(find.byKey(_probeKey)),
        Offset.zero & const Size(800, 600),
      );
    });

    testWidgets('the fake keyboard removes the bottom padding, as the '
        'engine does, and keeps viewPadding', (tester) async {
      await tester.pumpWidget(host(const SizedBox(key: _probeKey)));
      await set(
        tester,
        (e) => e.copyWith(
          safeArea: () => notchSafeArea,
          keyboardHeight: () => fakeKeyboardHeight,
        ),
      );
      final media = MediaQuery.of(probe(tester));
      expect(media.padding.bottom, 0);
      expect(media.padding.top, 59);
      expect(media.viewPadding.bottom, 34);
      expect(media.viewInsets.bottom, fakeKeyboardHeight);
    });

    testWidgets('the fake keyboard is a grey block that takes the taps on '
        'it', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await set(
        tester,
        (e) => e.copyWith(keyboardHeight: () => fakeKeyboardHeight),
      );
      final frame = tester.renderObject<RenderViewportFrame>(
        find.byType(ViewportFrame),
      );
      expect(
        frame,
        paints..something(
          // Paint keeps colors as 32-bit floats: compare the ARGB values.
          (method, args) =>
              method == #drawRect &&
              (args[1] as Paint).color.toARGB32() ==
                  RenderViewportFrame.keyboard.toARGB32(),
        ),
      );
      expect(frame.keyboardRect, const Rect.fromLTWH(0, 300, 800, 300));

      await tester.tapAt(const Offset(400, 500));
      expect(taps, 0);
      await tester.tapAt(const Offset(400, 100));
      expect(taps, 1);
    });

    testWidgets('light mode uses the app theme, and a theme variant wins '
        'over both', (tester) async {
      final brand = ThemeData(colorSchemeSeed: Colors.teal);
      await tester.pumpWidget(
        MaterialApp(
          theme: light,
          darkTheme: dark,
          themeMode: ThemeMode.dark,
          builder: (context, child) => PinPointWrapper(
            controller: controller,
            config: PinPointConfig(themeVariants: {'Brand': brand}),
            child: child,
          ),
          home: const SizedBox(key: _probeKey),
        ),
      );
      await tester.pumpAndSettle();
      expect(Theme.of(probe(tester)).brightness, Brightness.dark);

      await set(tester, (e) => e.copyWith(brightness: () => Brightness.light));
      expect(Theme.of(probe(tester)).colorScheme, light.colorScheme);

      await set(tester, (e) => e.copyWith(themeVariant: () => 'Brand'));
      expect(Theme.of(probe(tester)).colorScheme, brand.colorScheme);
    });

    testWidgets('an app without a darkTheme gets a dark default', (
      tester,
    ) async {
      await tester.pumpWidget(host(const SizedBox(key: _probeKey)));
      await set(tester, (e) => e.copyWith(brightness: () => Brightness.dark));
      expect(Theme.of(probe(tester)).brightness, Brightness.dark);
    });

    testWidgets('a seed color makes the color scheme of a Material 3 app', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SizedBox(key: _probeKey), theme: light),
      );
      const seed = Color(0xFFE65100);
      await set(tester, (e) => e.copyWith(seedColor: () => seed));
      expect(
        Theme.of(probe(tester)).colorScheme,
        ColorScheme.fromSeed(seedColor: seed),
      );
    });

    testWidgets('watch out for: a Material 2 app ignores the seed color, '
        'since copyWith(colorScheme:) does not re-derive its component '
        'themes', (tester) async {
      final m2 = ThemeData(useMaterial3: false, primarySwatch: Colors.green);
      await tester.pumpWidget(host(const SizedBox(key: _probeKey), theme: m2));
      final before = Theme.of(probe(tester)).colorScheme;
      await set(
        tester,
        (e) => e.copyWith(seedColor: () => const Color(0xFFE65100)),
      );
      expect(Theme.of(probe(tester)).colorScheme, before);
    });

    testWidgets('watch out for: the device pixel ratio is never changed', (
      tester,
    ) async {
      await tester.pumpWidget(host(const SizedBox(key: _probeKey)));
      final real = MediaQuery.devicePixelRatioOf(probe(tester));
      await set(
        tester,
        (e) => e.copyWith(
          viewport: () => const Size(390, 844),
          textScale: () => 1.5,
        ),
      );
      expect(MediaQuery.devicePixelRatioOf(probe(tester)), real);
    });
  });

  group('engineering rules', () {
    testWidgets('rule 5: every host switch keeps the app State', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const _Stateful(), theme: light, darkTheme: dark),
      );
      final state = tester.state(find.byType(_Stateful));
      final changes = <Environment Function(Environment)>[
        (e) => e.copyWith(textScale: () => 1.5),
        (e) => e.copyWith(boldText: () => true),
        (e) => e.copyWith(safeArea: () => notchSafeArea),
        (e) => e.copyWith(keyboardHeight: () => fakeKeyboardHeight),
        (e) => e.copyWith(textDirection: () => TextDirection.rtl),
        (e) => e.copyWith(brightness: () => Brightness.dark),
        (e) => e.copyWith(seedColor: () => seedColors.first),
        (e) => Environment.none,
      ];
      for (final change in changes) {
        await set(tester, change);
        expect(tester.state(find.byType(_Stateful)), same(state));
      }
    });

    testWidgets('rule 3: an app widget that reads nothing inherited is not '
        'rebuilt by a switch', (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        host(Scaffold(body: _BuildCounter(onBuild: () => builds++))),
      );
      final before = builds;
      await set(tester, (e) => e.copyWith(textScale: () => 2.0));
      await set(tester, (e) => e.copyWith(brightness: () => Brightness.dark));
      await set(tester, (e) => e.copyWith(boldText: () => true));
      expect(builds, before);
    });

    testWidgets('with nothing overridden the app gets the real values', (
      tester,
    ) async {
      MediaQueryData? outside;
      await tester.pumpWidget(
        MaterialApp(
          theme: light,
          builder: (context, child) {
            outside = MediaQuery.of(context);
            return PinPointWrapper(controller: controller, child: child);
          },
          home: const SizedBox(key: _probeKey),
        ),
      );
      expect(MediaQuery.of(probe(tester)), outside);
      expect(Theme.of(probe(tester)).colorScheme, light.colorScheme);
      expect(Directionality.of(probe(tester)), TextDirection.ltr);
    });
  });

  test('mediaFor only changes what is overridden', () {
    const real = MediaQueryData(
      size: Size(800, 600),
      padding: EdgeInsets.only(top: 20),
      viewPadding: EdgeInsets.only(top: 20, bottom: 10),
      devicePixelRatio: 2,
    );
    expect(EnvironmentHost.mediaFor(real, Environment.none), real);
    final data = EnvironmentHost.mediaFor(
      real,
      const Environment(textScale: 1.3),
    );
    expect(data.textScaler, const TextScaler.linear(1.3));
    expect(data.padding, real.padding);
    expect(data.size, real.size);
  });
}

const Key _probeKey = ValueKey<String>('probe');

class _DialogPage extends StatelessWidget {
  const _DialogPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text('page text'),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const Dialog(child: Text('dialog text')),
          ),
          child: const Text('open'),
        ),
      ],
    ),
  );
}

class _Stateful extends StatefulWidget {
  const _Stateful();

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('state'));
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 10, height: 10);
  }
}
