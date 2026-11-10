import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/search/pick_result.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_pick.dart';

/// Milestone 3, build step 3: keyboard navigation along the chain.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host() => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: const FixturePage(),
  );

  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  Future<PickResult> selectSave(WidgetTester tester) async {
    await tester.pumpWidget(host());
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText('Save')));
    await tester.pump();
    // Milestone 5: a selection puts focus in the comment field, where the
    // arrows edit text. The Info tab gives them back to navigation.
    await tester.tap(find.byKey(InfoPanel.infoTabKey));
    await tester.pump();
    return controller.selection.value!;
  }

  PickResult selection() => controller.selection.value!;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  Future<void> pressWithAlt(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
  }

  bool holds(Rect outer, Rect inner) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;

  group('acceptance', () {
    // PLAN.md asks for an outline that grows each time. A custom widget
    // shares its render object (and rect) with the root of its build, here
    // SaveBar and its Padding, so that one step keeps the rect. Every step
    // to another render object grows it.
    testWidgets(
      'Arrow Up moves to the ElevatedButton, then on to the custom widget',
      (tester) async {
        final text = await selectSave(tester);
        expect(text.entry.name, 'Text');

        final names = <String>[];
        var previous = text;
        while (selection().entry.name != 'SaveBar') {
          await press(tester, LogicalKeyboardKey.arrowUp);
          final current = selection();
          expect(current, isNot(same(previous)), reason: 'Up moved');
          names.add(current.entry.name);
          expect(current.entry.isLocal, isTrue);
          expect(holds(current.globalRect, previous.globalRect), isTrue);
          if (!identical(current.renderObject, previous.renderObject)) {
            expect(current.globalRect, isNot(previous.globalRect));
          }
          previous = current;
          expect(names.length, lessThan(10), reason: 'SaveBar not reached');
        }

        expect(names, ['ElevatedButton', 'Row', 'Padding', 'SaveBar']);
        expect(selection().globalRect, tester.getRect(find.byType(SaveBar)));
        // The outline is drawn on the new rect.
        expect(
          tester.renderObject(find.byKey(InspectorOverlay.highlightKey)),
          paints..rect(
            rect: selection().globalRect,
            color: HighlightColors.selected.withValues(alpha: 0.12),
          ),
        );
      },
    );

    testWidgets('the first Up selects the button with a larger outline', (
      tester,
    ) async {
      final text = await selectSave(tester);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(selection().element.widget, isA<ElevatedButton>());
      expect(
        selection().globalRect,
        tester.getRect(find.byType(ElevatedButton)),
      );
      expect(selection().globalRect.width, greaterThan(text.globalRect.width));
    });
  });

  testWidgets('Arrow Down goes back toward the picked widget', (tester) async {
    await selectSave(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selection().entry.name, 'Row');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selection().entry.name, 'ElevatedButton');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selection().entry.name, 'Text');

    // Below the Text there is only the framework's RichText: no move.
    final atBottom = selection();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selection(), same(atBottom));
  });

  testWidgets('[ and ] work like Arrow Up and Down', (tester) async {
    await selectSave(tester);
    await press(tester, LogicalKeyboardKey.bracketLeft);
    expect(selection().entry.name, 'ElevatedButton');
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(selection().entry.name, 'Text');
  });

  testWidgets('Alt plus an arrow steps through framework widgets too', (
    tester,
  ) async {
    final text = await selectSave(tester);

    await pressWithAlt(tester, LogicalKeyboardKey.arrowUp);
    expect(selection().chainIndex, text.chainIndex + 1);
    expect(selection().entry.isLocal, isFalse);

    await pressWithAlt(tester, LogicalKeyboardKey.arrowDown);
    expect(selection().chainIndex, text.chainIndex);
    // One more: the picked RichText itself.
    await pressWithAlt(tester, LogicalKeyboardKey.arrowDown);
    expect(selection().chainIndex, 0);
    expect(selection().element.widget, isA<RichText>());
  });

  testWidgets('navigation keeps the mode and survives Esc to picking', (
    tester,
  ) async {
    await selectSave(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(controller.mode, PinPointMode.commenting);

    await press(tester, LogicalKeyboardKey.escape);
    expect(controller.mode, PinPointMode.picking);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selection().entry.name, 'Row');
  });

  test('stepSelection without a selection, or at the end, does nothing', () {
    expect(controller.stepSelection(up: true), isFalse);
    controller
      ..startPicking()
      ..select(fakePick());
    final only = controller.selection.value;
    // A chain of one element with no location.
    expect(controller.stepSelection(up: true), isFalse);
    expect(controller.stepSelection(up: true, localOnly: false), isFalse);
    expect(controller.stepSelection(up: false, localOnly: false), isFalse);
    expect(controller.selection.value, same(only));
  });
}
