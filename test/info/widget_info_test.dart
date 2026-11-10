import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/info/widget_info.dart';

/// Milestone 2, build step 3: WidgetInfo and the first two extractors.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: child),
  );

  WidgetInfo infoOf(WidgetTester tester, Finder finder) =>
      WidgetInfo.fromRenderObject(tester.renderObject(finder));

  Map<String, String> labels(WidgetInfo info, String section) => {
    for (final p
        in info.sections.firstWhere((s) => s.title == section).properties)
      p.name: p.label,
  };

  group('geometry and labels', () {
    testWidgets('size, position, constraints and depth', (tester) async {
      const box = Key('box');
      await pump(
        tester,
        const Stack(
          children: [
            Positioned(
              left: 12,
              top: 80.5,
              child: SizedBox(key: box, width: 320, height: 48),
            ),
          ],
        ),
      );
      final ro = tester.renderObject(find.byKey(box));

      final info = WidgetInfo.fromRenderObject(ro);
      expect(info.renderType, 'RenderConstrainedBox');
      expect(info.size, const Size(320, 48));
      expect(info.globalPosition, const Offset(12, 80.5));
      expect(info.globalRect, const Rect.fromLTWH(12, 80.5, 320, 48));
      expect(info.depth, ro.depth);
      expect(info.sizeLabel, '320.0 x 48.0');
      expect(info.positionLabel, '(12.0, 80.5)');
      expect(info.constraintsLabel, 'w 0-∞, h 0-∞');
    });

    testWidgets('tight constraints read as "tight W x H"', (tester) async {
      const box = Key('box');
      await pump(
        tester,
        const Center(
          child: SizedBox(
            width: 320,
            height: 48,
            child: SizedBox.expand(key: box),
          ),
        ),
      );
      expect(
        infoOf(tester, find.byKey(box)).constraintsLabel,
        'tight 320 x 48',
      );
    });

    testWidgets('slivers: SliverConstraints and a finite size', (tester) async {
      await pump(
        tester,
        CustomScrollView(
          slivers: [
            SliverList.builder(
              itemCount: 50,
              itemBuilder: (context, i) =>
                  SizedBox(height: 40, child: Text('$i')),
            ),
          ],
        ),
      );
      final info = infoOf(tester, find.byType(SliverList));
      expect(info.constraints, isA<SliverConstraints>());
      expect(info.size.isFinite, isTrue);
      expect(info.size.width, 800);
      expect(info.constraintsLabel, startsWith('sliver down'));
    });
  });

  group('RenderParagraph', () {
    testWidgets('text, font size, weight label and color as hex', (
      tester,
    ) async {
      await pump(
        tester,
        const Center(
          child: Text(
            'Save',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFFFF3B30),
            ),
          ),
        ),
      );

      final info = infoOf(tester, find.text('Save'));
      expect(labels(info, 'Text'), {
        'text': 'Save',
        'fontSize': '16.0',
        'fontWeight': 'w700 (Bold)',
        'color': '#FF3B30',
        // Milestone 11: the rest of what the Tweak tab edits.
        'height': 'normal',
        'letterSpacing': 'normal',
        'textAlign': 'start',
        'maxLines': 'none',
        'overflow': 'clip',
      });
    });

    testWidgets('a null root style reads the first span that has one', (
      tester,
    ) async {
      await pump(
        tester,
        Center(
          child: RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'big',
                  style: TextStyle(fontSize: 20, color: Color(0x80112233)),
                ),
                TextSpan(text: 'small', style: TextStyle(fontSize: 8)),
              ],
            ),
          ),
        ),
      );

      final info = infoOf(tester, find.byType(RichText));
      final text = labels(info, 'Text');
      expect(text['text'], 'bigsmall');
      expect(text['fontSize'], '20.0');
      expect(text['color'], '#80112233', reason: 'alpha shown when not opaque');
      expect(text['fontWeight'], 'w400 (Regular)');
    });

    testWidgets('long text is truncated', (tester) async {
      await pump(tester, Center(child: Text('x' * 500)));
      final text = labels(infoOf(tester, find.byType(Text)), 'Text')['text']!;
      expect(text.length, lessThanOrEqualTo(WidgetInfo.maxTextLength + 1));
      expect(text, endsWith('…'));
    });
  });

  group('RenderDecoratedBox', () {
    testWidgets('background, border radius and border', (tester) async {
      const box = Key('box');
      await pump(
        tester,
        Center(
          child: DecoratedBox(
            key: box,
            decoration: BoxDecoration(
              color: const Color(0xFF00FF00),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(width: 2, color: const Color(0xFF0000FF)),
            ),
            child: const SizedBox(width: 50, height: 50),
          ),
        ),
      );

      expect(labels(infoOf(tester, find.byKey(box)), 'Decoration'), {
        'color': '#00FF00',
        'borderRadius': '8.0',
        'border': '2.0 #0000FF',
      });
    });

    testWidgets('uneven corners and sides are listed one by one', (
      tester,
    ) async {
      const box = Key('box');
      await pump(
        tester,
        const Center(
          child: DecoratedBox(
            key: box,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.only(topLeft: Radius.circular(4)),
              border: Border(top: BorderSide(color: Color(0xFF000000))),
            ),
            child: SizedBox(width: 50, height: 50),
          ),
        ),
      );

      final decoration = labels(infoOf(tester, find.byKey(box)), 'Decoration');
      expect(decoration.containsKey('color'), isFalse);
      expect(decoration['borderRadius'], 'tl 4.0, tr 0.0, br 0.0, bl 0.0');
      expect(decoration['border'], 'top 1.0 #000000');
    });

    testWidgets('a widget without a known render type has no sections', (
      tester,
    ) async {
      const box = Key('box');
      await pump(tester, const SizedBox(key: box));
      expect(infoOf(tester, find.byKey(box)).sections, isEmpty);
    });
  });

  testWidgets('an extractor that throws is skipped', (tester) async {
    await pump(tester, const Center(child: Text('ok')));
    final info = WidgetInfo.fromRenderObject(
      tester.renderObject(find.text('ok')),
      extractors: [
        (_) => throw StateError('bad extractor'),
        ...WidgetInfo.defaultExtractors,
      ],
    );
    expect(info.sections.single.title, 'Text');
  });

  testWidgets('toJson carries names and labels only', (tester) async {
    await pump(tester, const Center(child: Text('Save')));
    final json = infoOf(tester, find.text('Save')).toJson();

    expect(json['renderType'], 'RenderParagraph');
    expect(json['size'], isA<String>());
    final sections = json['sections']! as List<Object?>;
    final text = sections.single! as Map<String, Object?>;
    expect(text['title'], 'Text');
    final properties = text['properties']! as List<Object?>;
    expect(properties.first, {'name': 'text', 'label': 'Save'});
  });
}
