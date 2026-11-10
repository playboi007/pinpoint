import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';

import '../support/fake_sink.dart';

/// Milestone 5, build step 3: keyboard and focus in the comment panel.
void main() {
  late PinPointController controller;
  late FakeSink sink;
  late FocusNode appField;
  late ValueNotifier<bool> showAppField;

  setUp(() {
    controller = PinPointController();
    sink = FakeSink();
    appField = FocusNode(debugLabel: 'app field');
    showAppField = ValueNotifier<bool>(true);
  });
  tearDown(() {
    controller.dispose();
    appField.dispose();
    showAppField.dispose();
  });

  Widget host() => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(sinks: [sink]),
      child: child,
    ),
    home: _AppPage(field: appField, showField: showAppField),
  );

  final panel = find.byKey(InfoPanel.panelKey);
  final field = find.byKey(CommentForm.fieldKey);
  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  FocusNode commentFocus(WidgetTester tester) =>
      tester.widget<TextField>(field).focusNode!;

  /// Whether primary focus is inside the panel.
  bool focusInPanel() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorWidgetOfExactType<InfoPanel>() != null;
  }

  Future<void> selectSave(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(appField.hasPrimaryFocus, isTrue);
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText('Save')));
    await tester.pump();
    await tester.pump(); // the post-frame focus request
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a new selection puts focus in the comment field', (
    tester,
  ) async {
    await selectSave(tester);
    expect(commentFocus(tester).hasPrimaryFocus, isTrue);
  });

  group('acceptance: Ctrl or Cmd plus Enter sends', () {
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      testWidgets(modifier.keyLabel, (tester) async {
        await selectSave(tester);
        await type(tester, 'Too tight');
        await chord(tester, modifier, LogicalKeyboardKey.enter);
        expect(sink.notes.single.comment, 'Too tight');
        expect(controller.mode, PinPointMode.idle);
      });
    }

    testWidgets('plain Enter does not send', (tester) async {
      await selectSave(tester);
      await type(tester, 'Too tight');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sink.notes, isEmpty);
      expect(controller.mode, PinPointMode.commenting);
      expect(commentFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('an input method composition is not cut off', (tester) async {
      await selectSave(tester);
      await type(tester, 'Too tight');
      controller.draft.text.value = const TextEditingValue(
        text: 'Too tight にほ',
        selection: TextSelection.collapsed(offset: 12),
        composing: TextRange(start: 10, end: 12),
      );
      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.enter,
      );
      expect(sink.notes, isEmpty, reason: 'Enter commits the composition');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting, reason: 'Esc too');
    });
  });

  testWidgets('acceptance: Esc returns to picking with the selection kept', (
    tester,
  ) async {
    await selectSave(tester);
    final selection = controller.selection.value;
    await type(tester, 'Too tight');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(controller.mode, PinPointMode.picking);
    expect(controller.selection.value, same(selection));
    expect(controller.draft.text.text, 'Too tight');
    expect(commentFocus(tester).hasFocus, isFalse, reason: 'keys go back');
    expect(appField.hasFocus, isFalse, reason: 'and not to the app');

    // A click on the field resumes the comment on the same widget.
    await tester.tap(field);
    await tester.pump();
    await tester.pump();
    expect(controller.mode, PinPointMode.commenting);
    expect(controller.selection.value, same(selection));
    expect(commentFocus(tester).hasPrimaryFocus, isTrue);
  });

  group('arrow keys belong to the text field (watch out for)', () {
    testWidgets('arrows, brackets and P do not navigate or freeze', (
      tester,
    ) async {
      await selectSave(tester);
      final selection = controller.selection.value;
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.bracketLeft,
        LogicalKeyboardKey.keyP,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(controller.selection.value, same(selection));
      expect(controller.frozen, isFalse);
      expect(commentFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('the Info tab gives the arrows back to navigation', (
      tester,
    ) async {
      await selectSave(tester);
      await tester.tap(find.byKey(InfoPanel.infoTabKey));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(controller.selection.value!.entry.name, 'ElevatedButton');

      // And Comment puts focus back in the field.
      await tester.tap(find.byKey(InfoPanel.commentTabKey));
      await tester.pump();
      await tester.pump();
      expect(commentFocus(tester).hasPrimaryFocus, isTrue);
    });
  });

  testWidgets('Tab cycles inside the panel and never lands on the app', (
    tester,
  ) async {
    await selectSave(tester);
    final seen = <FocusNode>{};
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInPanel(), isTrue, reason: 'Tab $i');
      seen.add(FocusManager.instance.primaryFocus!);
    }
    expect(seen.length, greaterThan(3), reason: 'it moves');
    expect(seen.contains(commentFocus(tester)), isTrue, reason: 'it wraps');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 16; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInPanel(), isTrue, reason: 'Shift+Tab $i');
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(appField.hasFocus, isFalse);
  });

  group('acceptance: after closing, focus returns to the app field', () {
    testWidgets('after a send', (tester) async {
      await selectSave(tester);
      await type(tester, 'Too tight');
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump();
      expect(controller.mode, PinPointMode.idle);
      expect(appField.hasPrimaryFocus, isTrue);
    });

    testWidgets('after the shortcut, which keeps the comment', (tester) async {
      await selectSave(tester);
      await type(tester, 'Too tight');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.mode, PinPointMode.idle);
      expect(appField.hasPrimaryFocus, isTrue);
      expect(controller.draft.text.text, 'Too tight');
    });

    // Watch out for: on mobile web, focusing a field again can reopen the
    // on-screen keyboard. Restore only to a field still in the tree.
    testWidgets('not to a field that was removed meanwhile', (tester) async {
      await selectSave(tester);
      showAppField.value = false;
      await tester.pump();
      await type(tester, 'Too tight');
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump();
      expect(controller.mode, PinPointMode.idle);
      expect(appField.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the panel keeps its tickers while the app is frozen '
      '(watch out for)', (tester) async {
    await selectSave(tester);
    controller.toggleFreeze();
    await tester.pump();
    expect(
      TickerMode.valuesOf(tester.element(appText('Save'))).enabled,
      isFalse,
    );
    expect(TickerMode.valuesOf(tester.element(field)).enabled, isTrue);
  });

  testWidgets('selection handles and the text menu have an Overlay '
      '(watch out for)', (tester) async {
    await selectSave(tester);
    await type(tester, 'Too tight');
    await tester.longPress(field);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(Overlay),
        matching: find.byType(AdaptiveTextSelectionToolbar),
      ),
      findsOneWidget,
    );
    expect(panel, findsOneWidget);
  });
}

/// An app page with a text field and the fixture's Save button.
class _AppPage extends StatelessWidget {
  const _AppPage({required this.field, required this.showField});

  final FocusNode field;
  final ValueListenable<bool> showField;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: showField,
            builder: (context, show, _) =>
                show ? TextField(focusNode: field) : const SizedBox(height: 48),
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('Save')),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
