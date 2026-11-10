import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/image_detector.dart';

/// Milestone 10, build step 2: oversized images.
///
/// `flutter test` fails a test that leaves `debugOnPaintImage` set: every
/// test here disposes the wrapper (the test framework unmounts it before it
/// checks) or never installs the hook.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<ui.Image> image(WidgetTester tester, int width, int height) async =>
      (await tester.runAsync(
        () => createTestImage(width: width, height: height),
      ))!;

  Widget raw(ui.Image image, {String? label}) => MaterialApp(
    home: Center(
      child: RawImage(
        image: image,
        width: 100,
        height: 100,
        debugImageLabel: label,
      ),
    ),
  );

  List<Finding> scan(WidgetTester tester) => scanTree(
    tester.binding.renderViews.first,
    [ImageDetector(devicePixelRatio: tester.view.devicePixelRatio)],
  ).findings;

  testWidgets('acceptance: a 2000x2000 image shown at 100x100 is flagged', (
    tester,
  ) async {
    final big = await image(tester, 2000, 2000);
    addTearDown(big.dispose);
    await tester.pumpWidget(raw(big, label: 'big.png'));

    final finding = scan(tester).single;
    final ratio = tester.view.devicePixelRatio;
    expect(finding.kind, 'oversized_image');
    expect(finding.severity, Severity.warning);
    expect(finding.data['decoded'], '2000x2000');
    expect(
      finding.data['displayed'],
      '${(100 * ratio).round()}x'
      '${(100 * ratio).round()}',
    );
    expect(finding.data['label'], 'big.png');
    expect(finding.summary, contains('2000x2000'));
    expect(finding.rect, tester.getRect(find.byType(RawImage)));
  });

  testWidgets('an image at most twice the shown pixels is silent', (
    tester,
  ) async {
    // The test view's device pixel ratio is 3: 100 logical is 300 px.
    final fine = await image(tester, 400, 400);
    addTearDown(fine.dispose);
    await tester.pumpWidget(raw(fine));
    expect(scan(tester), isEmpty);
  });

  group('the paint hook', () {
    Widget host(Widget home) => MaterialApp(
      builder: (context, child) =>
          PinPointWrapper(controller: controller, child: child),
      home: home,
    );

    testWidgets('records an oversized image it cannot locate, after the '
        'frame', (tester) async {
      await tester.pumpWidget(host(const SizedBox()));
      expect(debugOnPaintImage, isNotNull);
      // As paintImage reports a decoration image: no RenderImage carries
      // its label.
      debugOnPaintImage!(
        ImageSizeInfo(
          source: 'background.jpg',
          displaySize: const Size(300, 300),
          imageSize: const Size(4000, 3000),
        ),
      );
      // Watch out for: the callback runs during paint. It only appends; the
      // finding comes after the frame.
      expect(controller.findings.findings, isEmpty);
      await tester.pump();
      final finding = controller.findings.findings.single;
      expect(finding.kind, 'oversized_image');
      expect(finding.element, isNull);
      expect(finding.data['label'], 'background.jpg');
      expect(finding.data['decoded'], '4000x3000');

      await tester.pumpWidget(const SizedBox());
      expect(debugOnPaintImage, isNull);
    });

    testWidgets('an image a RenderImage shows is left to the scan, and a '
        'small one is ignored', (tester) async {
      final big = await image(tester, 2000, 2000);
      addTearDown(big.dispose);
      await tester.pumpWidget(host(Center(child: _raw(big, 'shown.png'))));
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      expect(controller.findings.findings, isEmpty);

      debugOnPaintImage!(
        ImageSizeInfo(
          source: 'small.png',
          displaySize: const Size(300, 300),
          imageSize: const Size(400, 400),
        ),
      );
      await tester.pump();
      expect(controller.findings.findings, isEmpty);
    });

    testWidgets('turned off, the hook is not installed', (tester) async {
      controller.findings.trackImages = false;
      await tester.pumpWidget(host(const SizedBox()));
      expect(debugOnPaintImage, isNull);
      controller.findings.trackImages = true;
      expect(debugOnPaintImage, isNotNull);
      controller.findings.trackImages = false;
      expect(debugOnPaintImage, isNull);
    });
  });
}

Widget _raw(ui.Image image, String label) =>
    RawImage(image: image, width: 100, height: 100, debugImageLabel: label);
