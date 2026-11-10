import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/error_capture.dart';

import '../support/markers.dart';

const String _file = 'test/detect/error_capture_test.dart';

/// Milestone 10, build step 2: overflow and exceptions, captured through
/// `FlutterError.onError` and `PlatformDispatcher.onError`.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget home) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: home,
  );

  List<Finding> findings() => controller.findings.findings;

  testWidgets('acceptance: a thrown build error appears as a finding with '
      "the widget's file and line", (tester) async {
    await tester.pumpWidget(
      host(
        const Scaffold(
          // PIN:broken_widget
          body: _Broken(),
        ),
      ),
    );
    expect(tester.takeException(), isStateError);
    // Watch out for: nothing is touched inside onError. The finding is
    // made after the frame, from a one-shot timer.
    expect(findings(), isEmpty);
    await tester.pump(Duration.zero);

    final finding = findings().single;
    expect(finding.kind, 'exception');
    expect(finding.severity, Severity.error);
    expect(finding.summary, contains('StateError'));
    expect(finding.summary, contains('_Broken'));
    expect(finding.data['widget'], '_Broken');
    expect(finding.data['exception'], contains('planted build error'));
    expect(finding.data['stack'], isA<List<String>>());
    expect((finding.data['stack']! as List).length, inInclusiveRange(1, 8));
    expect(finding.source?.uri, endsWith(_file));
    expect(finding.source?.line, markerLine(_file, 'broken_widget'));
    expect(finding.element?.widget, isA<_Broken>());
  });

  testWidgets("an overflow error gives the render object and Flutter's "
      'amount', (tester) async {
    await tester.pumpWidget(
      host(
        const Center(
          child: SizedBox(
            width: 328,
            // PIN:captured_row
            child: Row(
              children: [
                SizedBox(width: 200, height: 20),
                SizedBox(width: 200, height: 20),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isFlutterError);
    await tester.pump(Duration.zero);

    final finding = findings().single;
    expect(finding.kind, 'overflow');
    expect(finding.summary, 'Row overflows by 72 px on the right');
    expect(finding.data['overflow'], 72.0);
    expect(finding.data['captured'], isTrue);
    expect(finding.element?.widget, isA<Row>());
    expect(finding.source?.line, markerLine(_file, 'captured_row'));
    expect(finding.rect, tester.getRect(find.byType(Row)));
  });

  testWidgets('every error still reaches the previous handler', (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: _Broken())));
    // The test binding's handler is the previous one: it has the error.
    expect(tester.takeException(), isStateError);
    await tester.pump(Duration.zero);
    expect(findings(), hasLength(1));
  });

  testWidgets("watch out for: an error inside Pinpoint's own handler only "
      'prints, and the error still goes on', (tester) async {
    final printed = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    ErrorCapture.debugFailHandler = true;
    addTearDown(() => ErrorCapture.debugFailHandler = false);

    await tester.pumpWidget(host(const Scaffold(body: _Broken())));
    expect(tester.takeException(), isStateError);
    await tester.pump(Duration.zero);
    // flutter test checks debugPrint at the end of the body, before any
    // tear-down.
    debugPrint = previousPrint;
    expect(findings(), isEmpty);
    expect(printed.join('\n'), contains('pinpoint: error capture failed'));
  });

  testWidgets('an uncaught error from PlatformDispatcher becomes a finding '
      'with no widget', (tester) async {
    await tester.pumpWidget(host(const SizedBox()));
    final handler = PlatformDispatcher.instance.onError!;
    handler(UnsupportedError('planted async error'), StackTrace.current);
    await tester.pump(Duration.zero);

    final finding = findings().single;
    expect(finding.kind, 'exception');
    expect(finding.element, isNull);
    expect(finding.data['exception'], contains('planted async error'));
  });

  testWidgets('the same error twice is one finding', (tester) async {
    await tester.pumpWidget(host(const Scaffold(body: _Broken())));
    tester.takeException();
    await tester.pump(Duration.zero);
    controller.findings.clear();

    // One constructor call, so one source location and one finding; the
    // newest error's text is kept.
    Widget broken(int n) => _Broken(n: n);
    await tester.pumpWidget(host(Scaffold(body: broken(1))));
    tester.takeException();
    await tester.pumpWidget(host(Scaffold(body: broken(2))));
    tester.takeException();
    await tester.pump(Duration.zero);
    expect(findings(), hasLength(1));
    expect(findings().single.data['exception'], contains('error 2'));
  });

  testWidgets('turned off, nothing is captured and the handlers are the '
      "previous ones", (tester) async {
    final before = FlutterError.onError;
    final beforePlatform = PlatformDispatcher.instance.onError;
    controller.findings.captureErrors = false;
    await tester.pumpWidget(host(const SizedBox()));
    expect(FlutterError.onError, same(before));
    expect(PlatformDispatcher.instance.onError, same(beforePlatform));

    controller.findings.captureErrors = true;
    expect(FlutterError.onError, isNot(same(before)));
    controller.findings.captureErrors = false;
    expect(FlutterError.onError, same(before));
    expect(PlatformDispatcher.instance.onError, same(beforePlatform));
  });

  testWidgets('disposing the wrapper restores both handlers', (tester) async {
    final before = FlutterError.onError;
    final beforePlatform = PlatformDispatcher.instance.onError;
    await tester.pumpWidget(host(const SizedBox()));
    expect(FlutterError.onError, isNot(same(before)));
    await tester.pumpWidget(const SizedBox());
    expect(FlutterError.onError, same(before));
    expect(PlatformDispatcher.instance.onError, same(beforePlatform));
  });
}

class _Broken extends StatelessWidget {
  const _Broken({this.n = 0});

  final int n;

  @override
  Widget build(BuildContext context) =>
      throw StateError('planted build error $n');
}
