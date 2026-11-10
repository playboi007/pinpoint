import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint_example/main.dart';

/// Milestone 3 acceptance on the example app: clicking a button's label
/// selects the `Text`, with a file under `example/lib` and the right line.
///
/// No `PINPOINT_ROOT` is set here, so this also covers classification
/// through the exclusion rule. The panel shows paths shortened from the
/// package directory.
void main() {
  const saveBarFile = 'lib/widgets/save_bar.dart';
  const formFile = 'lib/screens/form_screen.dart';

  /// The 1-based line of the first line in [file] containing [code].
  int lineOf(String file, String code) {
    final index = File(file)
        .readAsLinesSync()
        .indexWhere((l) => l.contains(code));
    expect(index, greaterThanOrEqualTo(0), reason: '$code not in $file');
    return index + 1;
  }

  Finder panelText(String text) => find.descendant(
    of: find.byKey(const ValueKey<String>('pinpoint.infoPanel')),
    matching: find.text(text),
  );

  Future<void> shortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
  }

  testWidgets('the Save label on the form screen selects its Text', (
    tester,
  ) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.tap(find.text('Form'));
    await tester.pumpAndSettle();
    final save = find.descendant(
      of: find.byType(Scaffold),
      matching: find.text('Save'),
    );
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();

    await shortcut(tester);
    await tester.tapAt(tester.getCenter(save));
    await tester.pump();

    final textLine = lineOf(saveBarFile, "child: const Text('Save')");
    expect(panelText('Text'), findsWidgets);
    expect(panelText('example/$saveBarFile:$textLine'), findsOneWidget);
    final crumbs = find.byKey(
      const ValueKey<String>('pinpoint.infoPanel.crumbs'),
    );
    for (final name in ['Row', 'ElevatedButton', 'Text']) {
      expect(
        find.descendant(of: crumbs, matching: find.text(name)),
        findsOneWidget,
      );
    }

    // Arrow Up: the button, then the Row, then SaveBar in the form screen.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final buttonLine = lineOf(saveBarFile, 'ElevatedButton(');
    expect(panelText('example/$saveBarFile:$buttonLine'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final barLine = lineOf(formFile, 'SaveBar(');
    // In the header and in the breadcrumb.
    expect(panelText('SaveBar'), findsNWidgets(2));
    expect(panelText('example/$formFile:$barLine'), findsOneWidget);

    await shortcut(tester); // back to idle
  });
}
