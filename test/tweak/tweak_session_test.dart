import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/padding_extractor.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/tweak_panel.dart';
import 'package:pinpoint/src/tweak/tweak_scope.dart';

import '../support/tweak_host.dart';

/// Milestone 11, build step 3: TweakSession with reapply and reset.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  TweakTarget paddingTarget(WidgetTester tester, Finder finder) {
    final ro = tester.renderObject(finder);
    return TweakTarget(
      renderObject: ro,
      extractor: paddingSection,
      section: paddingSection(ro)!,
      owner: tester.element(finder),
    );
  }

  Finder inApp(Finder finder) =>
      find.descendant(of: find.byType(Scaffold), matching: finder);

  // Acceptance: a tweak survives a setState in the owning widget's parent,
  // with at most one frame at the old value.
  testWidgets('survives a setState in the parent, one frame at most', (
    tester,
  ) async {
    const child = Key('child');
    late StateSetter rebuildParent;
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuildParent = setState;
                // Not const: a const widget is not built again by its
                // parent's setState, so nothing would be reset.
                // ignore: prefer_const_constructors
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: const SizedBox(key: child, width: 40, height: 40),
                );
              },
            ),
          ),
        ),
      ),
    );
    final padding = inApp(find.byType(Padding));
    expect(
      controller.tweaks.apply(
        paddingTarget(tester, padding),
        'padding',
        const EdgeInsets.all(16),
      ),
      isTrue,
    );
    await tester.pump();
    final tweaked = tester.getTopLeft(find.byKey(child));
    expect(tweaked, const Offset(16, 16));

    rebuildParent(() {});
    await tester.pump();
    // The rebuild wrote 8 back and this frame was laid out with it. After
    // the frame the session put 16 back, which asks for one more frame.
    expect(tester.getTopLeft(find.byKey(child)), const Offset(8, 8));
    expect(SchedulerBinding.instance.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(child)), tweaked);

    // Stable again: no frame is asked for (engineering rule 2).
    await tester.pump();
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    expect(controller.tweaks.tweaks.single.animating, isFalse);
  });

  // Acceptance: reset all returns every value to the widget's own,
  // verified against a fresh WidgetInfo.
  testWidgets('reset all: every value is the widget\'s own again', (
    tester,
  ) async {
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(color: Color(0xFFBBDEFB)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('One', style: TextStyle(fontSize: 16)),
                  Text('Two'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final container = inApp(find.byType(Container));
    final row = inApp(find.byType(Row));
    final one = inApp(find.text('One'));

    List<Map<String, Object?>> snapshot() => [
      for (final ro in [
        ...tester.renderObjectList(
          find.descendant(
            of: container,
            matching: find.byWidgetPredicate(
              (w) => w is Padding || w is DecoratedBox,
            ),
          ),
        ),
        tester.renderObject(row),
        tester.renderObject(
          find.descendant(of: one, matching: find.byType(RichText)),
        ),
      ])
        WidgetInfo.fromRenderObject(ro).toJson(),
    ];
    final before = snapshot();

    await selectForTweak(tester, controller, container);
    await typeInto(tester, tweakField('Padding', 'padding', 'left'), '24');
    await typeInto(tester, tweakField('Decoration', 'color'), '#FF0000');
    await selectForTweak(tester, controller, row);
    await choose(tester, 'Flex', 'mainAxisAlignment', 'end');
    await typeInto(tester, tweakField('Flex', 'spacing'), '12');
    await selectForTweak(tester, controller, one);
    await typeInto(tester, tweakField('Text', 'fontSize'), '30');
    expect(controller.tweaks.length, 5);
    expect(snapshot(), isNot(before));

    controller.tweaks.resetAll();
    await tester.pump();
    expect(controller.tweaks.isEmpty, isTrue);
    expect(snapshot(), before);
  });

  testWidgets('reset one puts back that value only', (tester) async {
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text('Pad', style: TextStyle(fontSize: 16)),
            ),
          ),
        ),
      ),
    );
    await selectForTweak(tester, controller, inApp(find.text('Pad')));
    await typeInto(tester, tweakField('Text', 'fontSize'), '20');
    await selectForTweak(tester, controller, inApp(find.byType(Padding)));
    await typeInto(tester, tweakField('Padding', 'padding', 'left'), '12');
    expect(controller.tweaks.length, 2);

    await tester.tap(find.byKey(TweakTab.resetKey('Padding', 'padding')));
    await tester.pump();
    expect(
      tester.renderObject<RenderPadding>(inApp(find.byType(Padding))).padding,
      const EdgeInsets.all(8),
    );
    expect(controller.tweaks.tweaks.single.property, 'fontSize');
  });

  // Watch out: a widget that rebuilds every frame (anything animated)
  // resets the tweak every frame. More than five resets a second: the tab
  // says the tweak cannot hold.
  testWidgets('an animating widget: the tweak cannot hold, and says so', (
    tester,
  ) async {
    final animation = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(seconds: 1),
    )..repeat();
    addTearDown(animation.dispose);
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) => Padding(
                padding: EdgeInsets.all(8 + animation.value),
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
    final padding = inApp(find.byType(Padding));
    await selectForTweak(tester, controller, padding);
    await typeInto(tester, tweakField('Padding', 'padding', 'left'), '30');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final tweak = controller.tweaks.tweaks.single;
    expect(tweak.animating, isTrue);
    expect(find.textContaining('animating; tweak cannot hold'), findsOneWidget);
    // It no longer fights the animation.
    expect(
      tester.renderObject<RenderPadding>(padding).padding,
      isNot(const EdgeInsets.all(30)),
    );
    animation.stop();
  });

  // Watch out: assigning to a render object during layout or paint
  // asserts. Apply only from input handlers and post-frame callbacks.
  testWidgets('applying during build or layout is refused by an assert', (
    tester,
  ) async {
    TweakTarget? target;
    Object? error;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (target != null) {
                try {
                  controller.tweaks.apply(
                    target,
                    'padding',
                    const EdgeInsets.all(2),
                  );
                } catch (e) {
                  error = e;
                }
              }
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    target = paddingTarget(tester, find.byType(Padding));
    // The builder runs again in the next layout.
    tester.element(find.byType(LayoutBuilder)).markNeedsBuild();
    await tester.pump();
    expect(error, isA<AssertionError>());
    expect(controller.tweaks.isEmpty, isTrue);
  });

  testWidgets('a tweak whose widget is gone is dropped', (tester) async {
    var show = true;
    late StateSetter set;
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return show
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 40, height: 40),
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    controller.tweaks.apply(
      paddingTarget(tester, inApp(find.byType(Padding))),
      'padding',
      const EdgeInsets.all(20),
    );
    await tester.pump();
    set(() => show = false);
    await tester.pump();
    await tester.pump();
    expect(controller.tweaks.isEmpty, isTrue);
  });

  group('chip and outline', () {
    testWidgets('"N tweaks active" shows in every mode; reset all on it', (
      tester,
    ) async {
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(
            body: Center(
              child: Padding(padding: EdgeInsets.all(8), child: Text('Pad')),
            ),
          ),
        ),
      );
      expect(find.byKey(TweakChip.chipKey), findsNothing);
      await selectForTweak(tester, controller, inApp(find.byType(Padding)));
      await typeInto(tester, tweakField('Padding', 'padding', 'left'), '12');
      expect(find.text('1 tweak active'), findsOneWidget);

      controller.stop();
      await tester.pump();
      expect(find.text('1 tweak active'), findsOneWidget);

      await tester.tap(find.byKey(TweakChip.resetKey));
      await tester.pump();
      expect(find.byKey(TweakChip.chipKey), findsNothing);
      expect(
        tester.renderObject<RenderPadding>(inApp(find.byType(Padding))).padding,
        const EdgeInsets.all(8),
      );
    });

    testWidgets('tweaked widgets get a dotted outline, in idle too', (
      tester,
    ) async {
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(
            body: Center(
              child: Padding(padding: EdgeInsets.all(8), child: Text('Pad')),
            ),
          ),
        ),
      );
      final padding = inApp(find.byType(Padding));
      controller.tweaks.apply(
        paddingTarget(tester, padding),
        'padding',
        const EdgeInsets.all(12),
      );
      await tester.pump();
      await tester.pump();
      expect(controller.tweaks.outlines.value, [tester.getRect(padding)]);
      expect(
        find.byKey(InspectorOverlay.tweakOutlineKey),
        paints..path(color: TweakOutlinePainter.color),
      );
      controller.tweaks.resetAll();
      await tester.pump();
      await tester.pump();
      expect(controller.tweaks.outlines.value, isEmpty);
    });
  });
}
