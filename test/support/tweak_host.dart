import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/tweak_panel.dart';

/// [home] inside a `MaterialApp` with Pinpoint around it.
Widget tweakHost(PinPointController controller, Widget home) => MaterialApp(
  builder: (context, child) =>
      PinPointWrapper(controller: controller, child: child),
  home: home,
);

/// Selects the widget [finder] finds, as a click and then a breadcrumb
/// click would, and opens the Tweak tab.
Future<void> selectForTweak(
  WidgetTester tester,
  PinPointController controller,
  Finder finder, {
  bool openTab = true,
}) async {
  final element = tester.element(finder);
  if (!controller.isActive) controller.startPicking();
  await tester.pump();
  await tester.tapAt(tester.getCenter(finder));
  await tester.pump();
  final pick = controller.selection.value;
  expect(pick, isNotNull, reason: 'nothing selected at $finder');
  final index = pick!.chain.elements.indexOf(element);
  expect(index, isNonNegative, reason: '$finder is not in the chain');
  controller.selectChainIndex(index);
  await tester.pump();
  expect(controller.selection.value!.element, same(element));
  if (openTab) {
    await tester.tap(find.byKey(InfoPanel.tweakTabKey));
    await tester.pump();
  }
}

/// The editor of [property] in [section], or one of its parts.
Finder tweakField(String section, String property, [String? part]) =>
    find.byKey(TweakTab.fieldKey(section, property, part));

/// Types [text] into the number or color field and presses Enter.
Future<void> typeInto(WidgetTester tester, Finder field, String text) async {
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  await tester.ensureVisible(editable);
  await tester.enterText(editable, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

/// Opens the menu of a choice field and picks [label].
Future<void> choose(
  WidgetTester tester,
  String section,
  String property,
  String label,
) async {
  final field = tweakField(section, property);
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.byKey(TweakTab.choiceKey(section, property, label)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}
