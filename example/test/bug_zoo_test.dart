// The findings list's keys are not public.
// ignore_for_file: implementation_imports

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/overlay/findings_panel.dart';
import 'package:pinpoint_example/main.dart';
import 'package:pinpoint_example/screens/bug_zoo_screen.dart';

/// Milestone 10 "How to verify": the bug zoo has one planted instance of
/// every problem. The scan and the audit find exactly those, and nothing
/// on the clean screens.
void main() {
  late PinPointController controller;

  setUp(() {
    controller = PinPointController();
    controller.draft.includeScreenshot = false;
  });
  tearDown(() => controller.dispose());

  /// A window tall enough for the whole zoo at 360 x 800.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ExampleApp(controller: controller));
  }

  /// Not pumpAndSettle: the zoo's dot and the counter's spinner never
  /// settle.
  Future<void> open(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> openList(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
    await tester.tap(find.byKey(FindingsPanel.buttonKey));
    await tester.pump();
  }

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.byKey(FindingsPanel.scanKey));
    await tester.pump();
  }

  /// The audit builds semantics in one frame, then captures for contrast
  /// outside the fake clock.
  Future<void> audit(WidgetTester tester) async {
    await tester.tap(find.byKey(FindingsPanel.auditKey));
    for (var i = 0; i < 20 && controller.findings.auditing; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
    expect(controller.findings.auditing, isFalse);
  }

  Map<String, int> kinds() {
    final counts = <String, int>{};
    for (final finding in controller.findings.findings) {
      counts[finding.kind] = (counts[finding.kind] ?? 0) + 1;
    }
    return counts;
  }

  Finding only(String kind) =>
      controller.findings.findings.singleWhere((f) => f.kind == kind);

  testWidgets('the bug zoo: the scan and the audit find exactly the planted '
      'problems', (tester) async {
    await pumpApp(tester);
    await open(tester, HomeScreen.bugZooTitle);
    // The planted build error, captured by the error hook.
    expect(tester.takeException(), isStateError);
    // The 2000 x 2000 image is drawn outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);

    controller.environment.setViewport(const Size(360, 800));
    await tester.pump();
    expect(tester.takeException(), isFlutterError);

    await openList(tester);
    await scan(tester);
    expect(kinds(), {
      'overflow': 1,
      'truncated_text': 1,
      'oversized_image': 1,
      'exception': 1,
    });

    // Acceptance: the deliberately overflowing Row, with the right amount.
    final overflow = only('overflow');
    expect(overflow.summary, 'Row overflows by 72 px on the right');
    expect(overflow.source?.uri, endsWith('lib/screens/bug_zoo_screen.dart'));
    expect(only('truncated_text').data['text'], BugZooScreen.longTitle);
    expect(only('oversized_image').data['decoded'], '2000x2000');
    expect(only('exception').data['widget'], '_BrokenCard');

    await audit(tester);
    expect(kinds(), {
      'overflow': 1,
      'truncated_text': 1,
      'oversized_image': 1,
      'exception': 1,
      'unlabeled_action': 1,
      'small_tap_target': 1,
      'low_contrast': 1,
    });
    expect(only('small_tap_target').data['widget'], 'IconButton');
    expect(SemanticsBinding.instance.semanticsEnabled, isFalse);

    // Rebuild heat: the pulsing dot.
    await tester.tap(find.byKey(FindingsPanel.rebuildsKey));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await scan(tester);
    final heat = controller.findings.findings
        .where((f) => f.kind == 'rebuild_heat')
        .toList();
    expect(heat.first.data['widget'], '_Pulse');
    expect(heat.first.source?.uri, endsWith('bug_zoo_screen.dart'));
    await tester.tap(find.byKey(FindingsPanel.rebuildsKey));
    await tester.pump();

    // After a second width, the overflow is still there, with its new
    // amount; Flutter itself does not report it again.
    controller.environment.setViewport(const Size(390, 844));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(only('overflow').data['overflow'], 42.0);
  }, semanticsEnabled: false);

  testWidgets('the clean screens are silent', (tester) async {
    await pumpApp(tester);
    await openList(tester);
    // Back to idle so the home list takes taps; the list opens per screen.
    controller.stop();
    await tester.pump();

    for (final screen in HomeScreen.screens) {
      await open(tester, screen.title);
      await openList(tester);
      await scan(tester);
      await audit(tester);
      expect(
        controller.findings.findings.map(
          (f) => '${f.kind}: ${f.summary} ${f.data} ${f.rect}',
        ),
        isEmpty,
        reason: screen.title,
      );
      controller.stop();
      await tester.pump();
      await back(tester);
    }
  }, semanticsEnabled: false);
}
