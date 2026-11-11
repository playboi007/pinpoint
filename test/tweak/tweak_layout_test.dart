import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/ruler_painter.dart';
import 'package:pinpoint/src/overlay/tweak_panel.dart';
import 'package:pinpoint/src/tweak/tweak_scope.dart';

import '../support/tweak_host.dart';

/// Milestone 11, build step 2: padding, constrained box and flex.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Finder inApp(Finder finder) =>
      find.descendant(of: find.byType(Scaffold), matching: finder);

  // Acceptance: changing padding from 8 to 16 moves the child immediately,
  // and the rulers update.
  testWidgets('padding 8 to 16 moves the child; the rulers update', (
    tester,
  ) async {
    const child = Key('child');
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 200,
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(key: child, width: 40, height: 40),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final before = tester.getTopLeft(find.byKey(child));
    await selectForTweak(tester, controller, inApp(find.byType(Padding)));
    double rightRuler() {
      final pick = controller.selection.value!;
      return ancestorRulers(
        pick.globalRect,
        pick.ancestorRect!,
      ).firstWhere((s) => s.side == RulerSide.right).distance;
    }

    expect(rightRuler(), 300 - 56);

    // Linked (all four equal), so one field sets every side.
    await typeInto(tester, tweakField('Padding', 'padding', 'left'), '16');
    expect(tester.getTopLeft(find.byKey(child)), before + const Offset(8, 8));
    final padding = tester.renderObject<RenderPadding>(
      inApp(find.byType(Padding)),
    );
    expect(padding.padding, const EdgeInsets.all(16));

    // The tracker reads the rect after the frame; the rulers repaint.
    await tester.pump();
    expect(rightRuler(), 300 - 72);
    expect(controller.tweaks.tweaks.single.fromLabel, 'EdgeInsets.all(8.0)');
    expect(controller.tweaks.tweaks.single.toLabel, 'EdgeInsets.all(16.0)');
  });

  testWidgets('unlinked insets set one side', (tester) async {
    const child = Key('child');
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(key: child, width: 40, height: 40),
            ),
          ),
        ),
      ),
    );
    await selectForTweak(tester, controller, inApp(find.byType(Padding)));
    await tester.tap(tweakField('Padding', 'padding', 'link'));
    await tester.pump();
    await typeInto(tester, tweakField('Padding', 'padding', 'top'), '20');
    expect(
      tester.renderObject<RenderPadding>(inApp(find.byType(Padding))).padding,
      const EdgeInsets.fromLTRB(8, 20, 8, 8),
    );
  });

  // Acceptance: changing mainAxisAlignment on a Row rearranges its
  // children.
  testWidgets('mainAxisAlignment on a Row rearranges its children', (
    tester,
  ) async {
    const a = Key('a');
    const b = Key('b');
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: Row(
                children: [
                  SizedBox(key: a, width: 40, height: 40),
                  SizedBox(key: b, width: 40, height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final row = inApp(find.byType(Row));
    final rowLeft = tester.getTopLeft(row).dx;
    expect(tester.getTopLeft(find.byKey(b)).dx - rowLeft, 40);

    await selectForTweak(tester, controller, row);
    await choose(tester, 'Flex', 'mainAxisAlignment', 'spaceBetween');
    expect(tester.getTopLeft(find.byKey(a)).dx - rowLeft, 0);
    expect(tester.getTopLeft(find.byKey(b)).dx - rowLeft, 360);

    await choose(tester, 'Flex', 'mainAxisAlignment', 'center');
    expect(tester.getTopLeft(find.byKey(a)).dx - rowLeft, 160);
  });

  testWidgets('direction, cross axis, size and spacing of a flex', (
    tester,
  ) async {
    const b = Key('b');
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 40, height: 40),
                SizedBox(key: b, width: 40, height: 20),
              ],
            ),
          ),
        ),
      ),
    );
    final row = inApp(find.byType(Row));
    await selectForTweak(tester, controller, row);
    await typeInto(tester, tweakField('Flex', 'spacing'), '8');
    expect(tester.getTopLeft(find.byKey(b)).dx, 48);
    await choose(tester, 'Flex', 'crossAxisAlignment', 'start');
    expect(tester.getTopLeft(find.byKey(b)).dy, 0);
    await choose(tester, 'Flex', 'direction', 'vertical');
    expect(tester.getTopLeft(find.byKey(b)), const Offset(0, 48));
    final flex = tester.renderObject<RenderFlex>(row);
    expect(flex.direction, Axis.vertical);
    // Baseline needs a text baseline the Row does not set.
    expect(
      find.byKey(TweakTab.choiceKey('Flex', 'crossAxisAlignment', 'baseline')),
      findsNothing,
    );
  });

  testWidgets('flex and fit of an Expanded child', (tester) async {
    const a = Key('a');
    const b = Key('b');
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: Row(
                children: [
                  Expanded(child: SizedBox(key: a, height: 40)),
                  Expanded(child: SizedBox(key: b, height: 40)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(a)).width, 150);
    await selectForTweak(
      tester,
      controller,
      inApp(find.byType(Expanded)).first,
    );
    await typeInto(tester, tweakField('Flex child', 'flex'), '2');
    expect(tester.getSize(find.byKey(a)).width, 200);
    expect(tester.getSize(find.byKey(b)).width, 100);
    final tweak = controller.tweaks.tweaks.single;
    expect(tweak.target.createdBy, 'Expanded');
    expect(tweak.target.nearestLocal!.widget, 'Expanded');
  });

  // Acceptance: selecting a Container shows padding, size and decoration
  // in one tab.
  testWidgets('a Container shows padding, size and decoration together', (
    tester,
  ) async {
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: Center(
            child: Container(
              width: 200,
              height: 100,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFBBDEFB),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Inside'),
            ),
          ),
        ),
      ),
    );
    final container = inApp(find.byType(Container));
    await selectForTweak(tester, controller, container);

    final targets = tweakTargetsFor(controller.selection.value!);
    final titles = [for (final t in targets) t.section.title];
    expect(titles, containsAll(<String>['Padding', 'Size', 'Decoration']));
    // The child Text is a widget of its own: its section is not here.
    expect(titles, isNot(contains('Text')));
    for (final target in targets) {
      expect(target.nearestLocal!.widget, 'Container');
      expect(
        target.nearestLocal!.source!.file,
        endsWith('tweak_layout_test.dart'),
      );
    }
    final made = {for (final t in targets) t.section.title: t.createdBy};
    expect(made['Padding'], 'Padding');
    expect(made['Size'], 'ConstrainedBox');
    expect(made['Decoration'], 'DecoratedBox');

    // All three in the tab.
    expect(tweakField('Padding', 'padding', 'left'), findsOneWidget);
    expect(
      tweakField('Size', 'additionalConstraints', 'maxWidth'),
      findsOneWidget,
    );
    expect(tweakField('Decoration', 'color'), findsOneWidget);

    await typeInto(
      tester,
      tweakField('Size', 'additionalConstraints', 'maxWidth'),
      '240',
    );
    await typeInto(
      tester,
      tweakField('Size', 'additionalConstraints', 'minWidth'),
      '240',
    );
    expect(tester.getSize(container).width, 240);
  });

  // Watch out: Container(color:) uses a private render object, not
  // RenderDecoratedBox. Read-only in v1, and the panel says so.
  testWidgets('Container(color:) is read-only, and the tab says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      tweakHost(
        controller,
        Scaffold(
          body: Center(
            child: Container(
              width: 120,
              height: 60,
              color: const Color(0xFF00897B),
            ),
          ),
        ),
      ),
    );
    await selectForTweak(tester, controller, inApp(find.byType(Container)));
    final color = tweakTargetsFor(controller.selection.value!)
        .firstWhere((t) => t.section.title == 'Color')
        .section
        .properties
        .single;
    expect(color.label, '#00897B');
    expect(color.editable, isFalse);
    // The reason is the tooltip of the lock glyph.
    expect(color.note, contains('private render object'));
    expect(find.byTooltip(color.note!), findsOneWidget);
  });

  testWidgets('the constraint chain lists what each ancestor gives', (
    tester,
  ) async {
    await tester.pumpWidget(
      tweakHost(
        controller,
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: Padding(padding: EdgeInsets.all(10), child: Text('Chain')),
            ),
          ),
        ),
      ),
    );
    await selectForTweak(tester, controller, inApp(find.byType(Text)));
    final rows = constraintChain(controller.selection.value!.renderObject);
    expect(rows.first, ('RenderPadding', 'gives w 180, h 0-580'));
    expect(rows[1].$1, 'RenderConstrainedBox');
    expect(rows[1].$2, startsWith('gives w 200'));

    await tester.ensureVisible(find.byKey(TweakTab.chainKey));
    // Its left end: the launcher can sit over the panel's corner.
    await tester.tapAt(
      tester.getTopLeft(find.byKey(TweakTab.chainKey)) + const Offset(12, 8),
    );
    await tester.pump();
    expect(find.text('gives w 180, h 0-580'), findsOneWidget);
  });
}
