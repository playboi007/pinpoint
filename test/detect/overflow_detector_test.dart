import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/overflow_detector.dart';
import 'package:pinpoint/src/env/environment_host.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../support/markers.dart';

const String _file = 'test/detect/overflow_detector_test.dart';

/// Milestone 10, build step 1: the measured overflow detector.
void main() {
  /// Scans the whole tree under the test's root.
  List<Finding> scan(WidgetTester tester, {Element? boundary}) {
    final root = tester.binding.rootElement!;
    return scanTree(
      tester.binding.renderViews.first,
      const [OverflowDetector()],
      locator: FindingLocator(
        resolver: const SourceResolver(),
        boundary: boundary ?? root,
      ),
    ).findings;
  }

  /// A row of two 200 px boxes in [width].
  Widget row(
    double width, {
    TextDirection direction = TextDirection.ltr,
    double spacing = 0,
  }) => Directionality(
    textDirection: direction,
    child: Center(
      child: SizedBox(
        width: width,
        // PIN:overflow_row
        child: Row(
          spacing: spacing,
          children: const [
            SizedBox(width: 200, height: 20),
            SizedBox(width: 200, height: 20),
          ],
        ),
      ),
    ),
  );

  testWidgets('a row two boxes do not fit: the amount and the side', (
    tester,
  ) async {
    await tester.pumpWidget(row(328));
    // Flutter reports the overflow once through FlutterError.onError.
    expect(tester.takeException(), isFlutterError);

    final findings = scan(tester);
    expect(findings, hasLength(1));
    final finding = findings.single;
    expect(finding.kind, 'overflow');
    expect(finding.severity, Severity.error);
    expect(finding.summary, 'Row overflows by 72 px on the right');
    expect(finding.data['overflow'], 72.0);
    expect(finding.data['side'], 'right');
    expect(finding.data['axis'], 'horizontal');
    expect(finding.element?.widget, isA<Row>());
    expect(finding.rect, tester.getRect(find.byType(Row)));
    expect(finding.source?.line, markerLine(_file, 'overflow_row'));
  });

  testWidgets('spacing counts toward the size', (tester) async {
    await tester.pumpWidget(row(408, spacing: 10));
    expect(tester.takeException(), isFlutterError);
    expect(scan(tester).single.data['overflow'], 2.0);
  });

  testWidgets('in RTL the overflow is on the left', (tester) async {
    await tester.pumpWidget(row(328, direction: TextDirection.rtl));
    expect(tester.takeException(), isFlutterError);
    expect(scan(tester).single.summary, 'Row overflows by 72 px on the left');
  });

  testWidgets('a column reports the bottom', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            height: 150,
            child: Column(
              children: [
                SizedBox(width: 10, height: 100),
                SizedBox(width: 10, height: 75.5),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isFlutterError);
    expect(
      scan(tester).single.summary,
      'Column overflows by 25.5 px at the bottom',
    );
  });

  testWidgets('a row that fits, or overflows by rounding only, is silent', (
    tester,
  ) async {
    await tester.pumpWidget(row(400));
    expect(scan(tester), isEmpty);

    // Watch out for: rounding produces false errors without a tolerance.
    await tester.pumpWidget(row(399.7));
    tester.takeException();
    expect(scan(tester), isEmpty);
  });

  testWidgets('a route beneath an opaque route is not scanned', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: row(328)),
      ),
    );
    expect(tester.takeException(), isFlutterError);
    expect(scan(tester), hasLength(1));

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(scan(tester), isEmpty);
  });

  testWidgets('a row scrolled out of view is not scanned', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: [row(328), const SizedBox(height: 3000)],
        ),
      ),
    );
    expect(tester.takeException(), isFlutterError);
    expect(scan(tester), hasLength(1));

    controller.jumpTo(1000);
    await tester.pump();
    expect(scan(tester), isEmpty);
  });

  testWidgets('a detector that throws is skipped; the others still run', (
    tester,
  ) async {
    await tester.pumpWidget(row(328));
    tester.takeException();
    final root = tester.binding.rootElement!;
    final result = scanTree(
      tester.binding.renderViews.first,
      [_Throwing(), const OverflowDetector()],
      locator: FindingLocator(resolver: const SourceResolver(), boundary: root),
    );
    expect(result.findings.single.kind, 'overflow');
    expect(result.errors, greaterThan(0));
  });

  group('acceptance', () {
    late PinPointController controller;

    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    testWidgets('after changing the viewport width twice, overflow is still '
        'reported each time', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: const [
                  SizedBox(width: 200, height: 20),
                  SizedBox(width: 200, height: 20),
                ],
              ),
            ),
          ),
        ),
      );
      expect(scan(tester), isEmpty);

      List<Finding> scanApp() {
        final boundary = tester.renderObject(
          find
              .descendant(
                of: find.byType(ViewportFrame),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        return scanTree(boundary, const [OverflowDetector()]).findings;
      }

      // Flutter itself reports an overflow once per render object, until
      // the next reassemble: only the first change reaches onError.
      controller.environment.setViewport(const Size(360, 800));
      await tester.pump();
      expect(tester.takeException(), isFlutterError);
      expect(scanApp().single.data['overflow'], 72.0);

      controller.environment.setViewport(const Size(390, 844));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(scanApp().single.data['overflow'], 42.0);

      controller.environment.setViewport(const Size(360, 800));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(scanApp().single.data['overflow'], 72.0);
    });
  });
}

class _Throwing implements Detector {
  @override
  String get kind => 'throwing';

  @override
  Iterable<Finding> scan(RenderObject renderObject, ScanContext context) =>
      throw StateError('a broken detector');
}
