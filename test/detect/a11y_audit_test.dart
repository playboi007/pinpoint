import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/detect/a11y_audit.dart';
import 'package:pinpoint/src/detect/detector.dart';

import '../support/markers.dart';

const String _file = 'test/detect/a11y_audit_test.dart';

/// Milestone 10, build step 4: the accessibility audit.
void main() {
  Widget page(Widget child) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(key: _boundary, child: child),
      ),
    ),
  );

  RenderObject root(WidgetTester tester) =>
      tester.renderObject(find.byKey(_boundary));

  FindingLocator locator(WidgetTester tester) =>
      FindingLocator(boundary: tester.binding.rootElement);

  /// The semantics checks, with semantics on as the audit turns them on.
  List<Finding> semantics(WidgetTester tester) => semanticsFindings(
    root(tester),
    locator: locator(tester),
    devicePixelRatio: tester.view.devicePixelRatio,
  );

  testWidgets('acceptance: a 24x24 IconButton without a tooltip yields two '
      'accessibility findings', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      page(
        // PIN:small_button
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.add, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(IconButton)), const Size(24, 24));

    final findings = semantics(tester);
    expect(findings.map((f) => f.kind).toSet(), {
      'unlabeled_action',
      'small_tap_target',
    });
    expect(findings, hasLength(2));
    for (final finding in findings) {
      expect(finding.severity, Severity.warning);
      expect(finding.source?.line, markerLine(_file, 'small_button'));
      expect(finding.data['widget'], 'IconButton');
    }
    final small = findings.firstWhere((f) => f.kind == 'small_tap_target');
    expect(small.data['width'], 24);
    expect(small.data['height'], 24);
    expect(small.data['min'], 48);
    expect(small.summary, 'IconButton tap target is 24x24, under 48x48');
    expect(small.rect, tester.getRect(find.byType(IconButton)));
    handle.dispose();
  });

  testWidgets('a labeled button of 48x48 is silent', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      page(
        IconButton(
          tooltip: 'Add',
          onPressed: () {},
          icon: const Icon(Icons.add),
        ),
      ),
    );
    expect(semantics(tester), isEmpty);
    handle.dispose();
  });

  testWidgets('a disabled or hidden control is silent', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      page(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(onPressed: null, icon: Icon(Icons.add)),
            ExcludeSemantics(
              child: SizedBox(width: 10, height: 10, child: _TapBox()),
            ),
          ],
        ),
      ),
    );
    expect(semantics(tester), isEmpty);
    handle.dispose();
  });

  testWidgets('the audit turns semantics on for its frame only', (
    tester,
  ) async {
    // testWidgets turns semantics on by default; this test must not.
    await tester.pumpWidget(
      page(IconButton(onPressed: () {}, icon: const Icon(Icons.add))),
    );
    expect(SemanticsBinding.instance.semanticsEnabled, isFalse);

    final audit = runAccessibilityAudit(
      root(tester),
      locator: locator(tester),
      devicePixelRatio: tester.view.devicePixelRatio,
      contrast: false,
    );
    expect(SemanticsBinding.instance.semanticsEnabled, isTrue);
    await tester.pump();
    final findings = await audit;
    expect(findings.map((f) => f.kind), ['unlabeled_action']);
    expect(SemanticsBinding.instance.semanticsEnabled, isFalse);
  }, semanticsEnabled: false);

  group('contrast', () {
    Widget text(Color color, {Color background = Colors.white}) => page(
      ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(8),
          // Words with spaces: the test font draws each glyph as a solid
          // box, and the gaps show the background.
          child: Text(
            'Low contrast text here',
            style: TextStyle(color: color, fontSize: 14),
          ),
        ),
      ),
    );

    Future<List<Finding>> contrast(WidgetTester tester) async {
      final paragraphs = visibleParagraphs(root(tester));
      return (await tester.runAsync(
        () => contrastFindings(
          root(tester) as RenderRepaintBoundary,
          paragraphs,
          locator: locator(tester),
        ),
      ))!;
    }

    testWidgets('light grey text on white is under 4.5:1', (tester) async {
      await tester.pumpWidget(text(const Color(0xFFBDBDBD)));
      final finding = (await contrast(tester)).single;
      expect(finding.kind, 'low_contrast');
      expect(finding.severity, Severity.warning);
      expect(finding.data['foreground'], '#BDBDBD');
      expect(finding.data['background'], '#FFFFFF');
      expect(finding.data['ratio'], closeTo(1.9, 0.05));
      expect(finding.data['required'], 4.5);
      expect(finding.data['confidence'], 'high');
      expect(finding.rect, tester.getRect(find.byType(RichText)));
    });

    testWidgets('see-through glyphs are not taken for the background', (
      tester,
    ) async {
      // Painted lighter than declared: the background comes from around
      // the text, not from its glyphs.
      await tester.pumpWidget(
        page(
          ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Label',
                style: TextStyle(color: Colors.black.withValues(alpha: 0.9)),
              ),
            ),
          ),
        ),
      );
      expect(await contrast(tester), isEmpty);
    });

    testWidgets('text not painted in its own color is skipped', (tester) async {
      // Under an Opacity, no pixel has the declared color: no ratio can be
      // trusted, so none is reported.
      await tester.pumpWidget(
        page(
          const ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Opacity(
                opacity: 0.3,
                child: Text('Faded', style: TextStyle(color: Colors.black)),
              ),
            ),
          ),
        ),
      );
      expect(await contrast(tester), isEmpty);
    });

    testWidgets('black text on white is silent', (tester) async {
      await tester.pumpWidget(text(Colors.black));
      expect(await contrast(tester), isEmpty);
    });

    testWidgets('large text needs only 3:1', (tester) async {
      await tester.pumpWidget(
        page(
          const ColoredBox(
            color: Colors.white,
            child: Text(
              'Big grey title',
              // 3.5:1 on white.
              style: TextStyle(color: Color(0xFF878787), fontSize: 24),
            ),
          ),
        ),
      );
      expect(await contrast(tester), isEmpty);
    });
  });

  test('contrast ratio follows WCAG', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.01));
    expect(
      contrastRatio(const Color(0xFF767676), Colors.white),
      closeTo(4.54, 0.01),
    );
  });
}

const Key _boundary = ValueKey<String>('boundary');

class _TapBox extends StatelessWidget {
  const _TapBox();

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: () {}, child: const SizedBox.expand());
}
