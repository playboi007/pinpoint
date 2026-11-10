import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/screenshot.dart';

/// Milestone 10 acceptance: "with every detector off, a frame-time
/// comparison against the app without Pinpoint shows no measurable
/// difference". The frame times need a browser; this checks the cause
/// such a difference would have: an installed hook or a forced frame.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host() => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: const Scaffold(body: Center(child: Text('idle'))),
  );

  testWidgets('with every detector off, no hook is installed and an idle '
      'app draws no frames', (tester) async {
    final flutterError = FlutterError.onError;
    final platformError = PlatformDispatcher.instance.onError;
    controller.findings
      ..captureErrors = false
      ..trackImages = false;
    await tester.pumpWidget(host());
    await tester.pump();

    expect(FlutterError.onError, same(flutterError));
    expect(PlatformDispatcher.instance.onError, same(platformError));
    expect(debugOnPaintImage, isNull);
    expect(debugOnRebuildDirtyWidget, isNull);
    expect(debugPaintFlagsOn(), isEmpty);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });

  testWidgets('the default hooks (errors, images) force no frame either', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(debugOnPaintImage, isNotNull);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });
}
