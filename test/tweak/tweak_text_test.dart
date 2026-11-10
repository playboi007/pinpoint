import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/decoration_extractor.dart';
import 'package:pinpoint/src/info/extractors/paragraph_extractor.dart';
import 'package:pinpoint/src/overlay/tweak_panel.dart';
import 'package:pinpoint/src/tweak/tweak_scope.dart';
import 'package:pinpoint/src/tweak/tweak_session.dart';

import '../support/tweak_host.dart';

/// Milestone 11, build step 1: apply on the paragraph and decoration
/// extractors, end to end through the panel.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  InfoProperty<Object?> propertyOf(InfoSection section, String name) =>
      section.properties.firstWhere((p) => p.name == name);

  TweakTarget targetOf(RenderObject ro, InfoExtractor extract) =>
      TweakTarget(renderObject: ro, extractor: extract, section: extract(ro)!);

  group('paragraph extractor', () {
    testWidgets('font size goes to the root span; children keep theirs', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            // RichText: the span written here is the root. Text.rich puts
            // it under a root of its own, so there the size is read-only.
            child: RichText(
              text: const TextSpan(
                text: 'Save',
                style: TextStyle(fontSize: 16),
                children: [TextSpan(text: '!', style: TextStyle(fontSize: 10))],
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      final size = propertyOf(paragraphSection(paragraph)!, 'fontSize');
      expect(size.editable, isTrue);
      size.applyValue(24.0);
      final root = paragraph.text as TextSpan;
      expect(root.style!.fontSize, 24);
      expect(root.toPlainText(), isNotEmpty);
      expect(root.children, hasLength(1));
      expect((root.children!.single as TextSpan).style!.fontSize, 10);
      expect(propertyOf(paragraphSection(paragraph)!, 'fontSize').value, 24);
    });

    testWidgets('a value a child span sets is read-only, with a note', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Save', style: TextStyle(fontSize: 20)),
                ],
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      final size = propertyOf(paragraphSection(paragraph)!, 'fontSize');
      expect(size.value, 20);
      expect(size.editable, isFalse);
      expect(size.note, contains('child span'));
    });

    testWidgets('weight, color, height, letter spacing, align, lines', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Text('Save', style: TextStyle(color: Color(0xFF000000))),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText),
      );
      void set(String name, Object? value) =>
          propertyOf(paragraphSection(paragraph)!, name).applyValue(value);
      set('fontWeight', FontWeight.w700);
      set('color', const Color(0xFFFF0000));
      set('height', 1.5);
      set('letterSpacing', 2.0);
      set('textAlign', TextAlign.end);
      set('maxLines', 1);
      set('overflow', TextOverflow.ellipsis);
      final labels = {
        for (final p in paragraphSection(paragraph)!.properties)
          p.name: p.label,
      };
      expect(labels, {
        'text': 'Save',
        'fontSize': '14.0',
        'fontWeight': 'w700 (Bold)',
        'color': '#FF0000',
        'height': '1.5',
        'letterSpacing': '2',
        'textAlign': 'end',
        'maxLines': '1',
        'overflow': 'ellipsis',
      });
      // Back to null: the font's own line height again.
      set('height', null);
      expect((paragraph.text as TextSpan).style!.height, isNull);
      expect(
        propertyOf(paragraphSection(paragraph)!, 'height').label,
        'normal',
      );
    });
  });

  group('decoration extractor', () {
    testWidgets('color, radius and border are editable', (tester) async {
      await tester.pumpWidget(
        Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFFF0000),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(),
            ),
            child: const SizedBox(width: 40, height: 40),
          ),
        ),
      );
      final box = tester.renderObject<RenderDecoratedBox>(
        find.byType(DecoratedBox),
      );
      final section = decorationSection(box)!;
      expect(section.properties.every((p) => p.editable), isTrue);
      propertyOf(section, 'color').applyValue(const Color(0xFF00FF00));
      propertyOf(
        decorationSection(box)!,
        'borderRadius',
      ).applyValue(BorderRadius.circular(12));
      propertyOf(
        decorationSection(box)!,
        'border',
      ).applyValue(Border.all(width: 3, color: const Color(0xFF0000FF)));
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFF00FF00));
      expect(decoration.borderRadius, BorderRadius.circular(12));
      expect(decoration.border!.top.width, 3);
      await tester.pump();
      expect(box, paints..rrect(color: const Color(0xFF00FF00)));
    });

    testWidgets('a radius that differs per corner is read-only', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFFF0000),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(8)),
            ),
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      );
      final box = tester.renderObject<RenderDecoratedBox>(
        find.byType(DecoratedBox),
      );
      final radius = propertyOf(decorationSection(box)!, 'borderRadius');
      expect(radius.editable, isFalse);
      expect(radius.note, contains('Corners differ'));
    });
  });

  group('TweakSession.apply', () {
    testWidgets('records the widget value as from, the new one as to', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Text('Save', style: TextStyle(fontSize: 16))),
        ),
      );
      final paragraph = tester.renderObject(find.byType(RichText));
      final session = TweakSession();
      addTearDown(session.dispose);
      final target = targetOf(paragraph, paragraphSection);

      expect(session.apply(target, 'fontSize', 20.0), isTrue);
      expect(session.apply(target, 'fontSize', 24.0), isTrue);
      expect(session.length, 1);
      final tweak = session.tweaks.single;
      expect(tweak.original, 16);
      expect(tweak.fromLabel, '16.0');
      expect(tweak.value, 24);
      expect(tweak.toLabel, '24.0');
      expect(tweak.toJson(), containsPair('renderType', 'RenderParagraph'));

      // The widget's own value again ends the edit.
      expect(session.apply(target, 'fontSize', 16.0), isTrue);
      expect(session.isEmpty, isTrue);
    });

    testWidgets('a read-only property is refused, nothing changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Text('Save')),
        ),
      );
      final paragraph = tester.renderObject(find.byType(RichText));
      final session = TweakSession();
      addTearDown(session.dispose);
      final target = targetOf(paragraph, paragraphSection);
      expect(session.apply(target, 'text', 'Other'), isFalse);
      expect(session.apply(target, 'noSuchProperty', 1.0), isFalse);
      expect(session.isEmpty, isTrue);
    });
  });

  group('through the panel', () {
    // Acceptance: changing font size relayouts the paragraph and its
    // parent.
    testWidgets('font size relayouts the paragraph and its parent', (
      tester,
    ) async {
      const parent = Key('parent');
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(
            body: Center(
              child: DecoratedBox(
                key: parent,
                decoration: BoxDecoration(color: Color(0xFFEEEEEE)),
                child: Text('Save', style: TextStyle(fontSize: 16)),
              ),
            ),
          ),
        ),
      );
      final text = find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(Text),
      );
      final paragraph = tester.renderObject<RenderBox>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      final box = tester.renderObject<RenderBox>(find.byKey(parent));
      final before = (paragraph.size, box.size);

      await selectForTweak(tester, controller, text);
      await typeInto(tester, tweakField('Text', 'fontSize'), '32');

      expect(paragraph.size.height, greaterThan(before.$1.height));
      expect(paragraph.size.width, greaterThan(before.$1.width));
      expect(box.size, paragraph.size);
      expect(box.size, isNot(before.$2));
      expect(controller.tweaks.tweaks.single.toLabel, '32.0');
    });

    testWidgets('the stepper and arrow keys nudge the number', (tester) async {
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(
            body: Center(child: Text('Save', style: TextStyle(fontSize: 16))),
          ),
        ),
      );
      final text = find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(Text),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      double fontSize() => (paragraph.text as TextSpan).style!.fontSize!;

      await selectForTweak(tester, controller, text);
      await tester.tap(
        find.byKey(const ValueKey<String>('pinpoint.tweak.Text.fontSize.inc')),
      );
      await tester.pump();
      expect(fontSize(), 17);

      await tester.tap(
        find.descendant(
          of: tweakField('Text', 'fontSize'),
          matching: find.byType(EditableText),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(fontSize(), 19);
      // The arrows belong to the field: the selection did not move.
      expect(controller.selection.value!.element.widget, isA<Text>());
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(fontSize(), 18);
    });

    testWidgets('a choice from the menu: font weight', (tester) async {
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(body: Center(child: Text('Save'))),
        ),
      );
      final text = find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(Text),
      );
      await selectForTweak(tester, controller, text);
      await choose(tester, 'Text', 'fontWeight', 'w700 (Bold)');
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      expect((paragraph.text as TextSpan).style!.fontWeight, FontWeight.w700);
    });

    testWidgets('a hex color on a decoration', (tester) async {
      const box = Key('box');
      await tester.pumpWidget(
        tweakHost(
          controller,
          const Scaffold(
            body: Center(
              child: DecoratedBox(
                key: box,
                decoration: BoxDecoration(color: Color(0xFFFF0000)),
                child: SizedBox(width: 120, height: 80),
              ),
            ),
          ),
        ),
      );
      await selectForTweak(tester, controller, find.byKey(box));
      await typeInto(tester, tweakField('Decoration', 'color'), '#00ff00');
      final decoration =
          tester.renderObject<RenderDecoratedBox>(find.byKey(box)).decoration
              as BoxDecoration;
      expect(decoration.color, const Color(0xFF00FF00));
      // Not a color: the field shows the value again, nothing changes.
      await typeInto(tester, tweakField('Decoration', 'color'), 'green');
      expect(controller.tweaks.tweaks.single.toLabel, '#00FF00');
    });
  });

  test('parseHexColor', () {
    expect(parseHexColor('#FF3B30'), const Color(0xFFFF3B30));
    expect(parseHexColor('80ff3b30'), const Color(0x80FF3B30));
    expect(parseHexColor('#12345'), isNull);
    expect(parseHexColor('red'), isNull);
  });
}
