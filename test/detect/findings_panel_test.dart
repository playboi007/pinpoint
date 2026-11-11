import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/debug_paint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/overlay/environment_panel.dart';
import 'package:pinpoint/src/overlay/findings_panel.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';

import '../support/markers.dart';

const String _file = 'test/detect/findings_panel_test.dart';

/// Milestone 10, build step 3: the findings list and "Make note".
void main() {
  late PinPointController controller;
  late ValueNotifier<bool> showRow;

  setUp(() {
    controller = PinPointController();
    showRow = ValueNotifier<bool>(true);
    // No image capture in these tests: the screenshot path has its own.
    controller.draft.includeScreenshot = false;
  });
  tearDown(() {
    controller.dispose();
    showRow.dispose();
  });

  final long = 'A title much too long for one line of this page ' * 3;

  /// A page with a row that overflows below 432 px wide and a cut title.
  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<bool>(
              valueListenable: showRow,
              builder: (context, show, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (show)
                    // PIN:panel_row
                    const Row(
                      children: [
                        SizedBox(width: 200, height: 20),
                        SizedBox(width: 200, height: 20),
                      ],
                    ),
                  SizedBox(
                    width: 200,
                    child: Text(long, maxLines: 1, overflow: TextOverflow.fade),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Picks at 360 x 800, where the row overflows by 72 px.
  Future<void> narrow(WidgetTester tester) async {
    controller.environment.setViewport(const Size(360, 800));
    await tester.pump();
    expect(tester.takeException(), isFlutterError);
  }

  Future<void> openPanel(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
    await tester.tap(find.byKey(FindingsPanel.buttonKey));
    await tester.pump();
    expect(find.byKey(FindingsPanel.panelKey), findsOneWidget);
  }

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.byKey(FindingsPanel.scanKey));
    await tester.pump();
  }

  Finding overflow() =>
      controller.findings.findings.firstWhere((f) => f.kind == 'overflow');

  testWidgets('the button shows while a mode is active, with a count', (
    tester,
  ) async {
    await pumpHost(tester);
    await narrow(tester);
    expect(find.byKey(FindingsPanel.buttonKey), findsNothing);

    await openPanel(tester);
    await scan(tester);
    expect(
      find.descendant(
        of: find.byKey(FindingsPanel.buttonKey),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a scan lists the findings grouped by kind', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    expect(find.text('Scan this screen'), findsOneWidget);
    await scan(tester);

    expect(find.byKey(FindingsPanel.groupKey('overflow')), findsOneWidget);
    expect(
      find.byKey(FindingsPanel.groupKey('truncated_text')),
      findsOneWidget,
    );
    expect(find.text('Row overflows by 72 px on the right'), findsOneWidget);
  });

  testWidgets('scanning again does not pile up copies', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    await scan(tester);
    // The error hook captured the same overflow; it is one finding.
    expect(controller.findings.findings, hasLength(2));
    await scan(tester);
    await scan(tester);
    expect(controller.findings.findings, hasLength(2));
  });

  testWidgets('a what-if change rescans while the list is open', (
    tester,
  ) async {
    await pumpHost(tester);
    await openPanel(tester);
    await scan(tester);
    expect(controller.findings.findings.map((f) => f.kind), ['truncated_text']);

    controller.environment.setViewport(const Size(360, 800));
    await tester.pump();
    expect(tester.takeException(), isFlutterError);
    await tester.pump();
    expect(overflow().data['overflow'], 72.0);
  });

  testWidgets('hovering a finding outlines its rect', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    await scan(tester);
    final finding = overflow();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(FindingsPanel.rowKey(finding))),
    );
    await tester.pump();
    expect(controller.findings.hovered.value?.key, finding.key);
    expect(
      find.byKey(InspectorOverlay.findingKey),
      paints..rect(rect: tester.getRect(find.byType(Row).first)),
    );

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(controller.findings.hovered.value, isNull);
  });

  testWidgets('Make note creates a draft with the comment, a check and the '
      'environment pre-filled', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    await scan(tester);
    final finding = overflow();

    await tester.tap(find.byKey(FindingsPanel.noteKey(finding)));
    await tester.pump();

    final note = controller.notes.drafts.single;
    expect(note.status, NoteStatus.draft);
    expect(note.comment, 'Row overflows by 72 px on the right');
    expect(note.intent, AnnotationIntent.bug);
    expect(note.finding?['kind'], 'overflow');
    expect(note.finding?['key'], finding.key);
    expect(note.checks, [
      {'type': 'no_overflow'},
    ]);
    expect(note.environment, {
      'viewport': {'width': 360, 'height': 800},
    });
    expect(note.target.widget, 'Row');
    expect(note.target.source?.line, markerLine(_file, 'panel_row'));
    expect(controller.notes.numberOf(note.id), 1);
    // The mode and the list stay, for the next finding.
    expect(controller.mode, PinPointMode.picking);
    expect(find.byKey(FindingsPanel.panelKey), findsOneWidget);
    // The row now names its note instead of offering another.
    expect(find.byKey(FindingsPanel.noteKey(finding)), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(FindingsPanel.rowKey(finding)),
        matching: find.text('Note 1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a truncated text note is a suggestion with its own check', (
    tester,
  ) async {
    await pumpHost(tester);
    await openPanel(tester);
    await scan(tester);
    final finding = controller.findings.findings.single;
    await tester.tap(find.byKey(FindingsPanel.noteKey(finding)));
    await tester.pump();
    final note = controller.notes.drafts.single;
    expect(note.intent, AnnotationIntent.improve);
    expect(note.checks, [
      {'type': 'not_truncated'},
    ]);
    // The local widget, not the RichText inside Text.
    expect(note.target.widget, 'Text');
  });

  testWidgets('Make note on a widget that is gone says so', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    await scan(tester);
    final finding = overflow();
    showRow.value = false;
    await tester.pump();

    await tester.tap(find.byKey(FindingsPanel.noteKey(finding)));
    await tester.pump();
    expect(controller.notes.notes, isEmpty);
    expect(find.textContaining('is gone'), findsOneWidget);
  });

  testWidgets('a finding with no widget offers no note', (tester) async {
    await pumpHost(tester);
    await openPanel(tester);
    controller.findings.addCaptured([
      const Finding(
        kind: 'exception',
        severity: Severity.error,
        summary: 'Uncaught StateError: late',
      ),
    ]);
    await tester.pump();
    final finding = controller.findings.findings.single;
    expect(find.byKey(FindingsPanel.rowKey(finding)), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.byKey(FindingsPanel.noteKey(finding)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a finding with no widget says why, and Copy puts the full '
      'error on the clipboard', (tester) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpHost(tester);
    await openPanel(tester);
    controller.findings.addCaptured([
      const Finding(
        kind: 'exception',
        severity: Severity.error,
        summary: 'AssertionErrorImpl: Assertion failed: text_editing',
        data: {
          'exception': 'Assertion failed: text_editing.dart:42\nsecond line',
          'stack': ['#0 frame one', '#1 frame two'],
          'library': 'services library',
        },
      ),
    ]);
    await tester.pump();
    final finding = controller.findings.findings.single;

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(FindingsPanel.noteKey(finding)),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('No widget'));

    await tester.tap(find.byKey(FindingsPanel.copyKey(finding)));
    await tester.pump();
    expect(copied, hasLength(1));
    expect(
      copied.single,
      'AssertionErrorImpl: Assertion failed: text_editing\n'
      '\n'
      'Assertion failed: text_editing.dart:42\n'
      'second line\n'
      '\n'
      'Library: services library\n'
      '\n'
      'Stack:\n'
      '#0 frame one\n'
      '#1 frame two',
    );
    expect(find.text('Error copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a finding with a widget has no Copy button', (tester) async {
    await pumpHost(tester);
    await narrow(tester);
    await openPanel(tester);
    await scan(tester);
    final finding = controller.findings.findings.firstWhere(
      (f) => f.element != null,
    );
    expect(find.byKey(FindingsPanel.noteKey(finding)), findsOneWidget);
    expect(find.byKey(FindingsPanel.copyKey(finding)), findsNothing);
  });

  testWidgets('Clear empties the list', (tester) async {
    await pumpHost(tester);
    await openPanel(tester);
    await scan(tester);
    expect(controller.findings.findings, isNotEmpty);
    await tester.tap(find.byKey(FindingsPanel.clearKey));
    await tester.pump();
    expect(controller.findings.findings, isEmpty);
  });

  testWidgets('the findings list and the what-if panel take turns', (
    tester,
  ) async {
    await pumpHost(tester);
    await openPanel(tester);
    await tester.tap(find.byKey(EnvironmentBar.toggleKey));
    await tester.pump();
    expect(find.byKey(EnvironmentPanel.panelKey), findsOneWidget);
    expect(find.byKey(FindingsPanel.panelKey), findsNothing);

    await tester.tap(find.byKey(FindingsPanel.buttonKey));
    await tester.pump();
    expect(find.byKey(FindingsPanel.panelKey), findsOneWidget);
    expect(find.byKey(EnvironmentPanel.panelKey), findsNothing);
  });

  testWidgets('the list closes when picking stops', (tester) async {
    await pumpHost(tester);
    await openPanel(tester);
    controller.stop();
    await tester.pump();
    expect(find.byKey(FindingsPanel.panelKey), findsNothing);
    controller.startPicking();
    await tester.pump();
    expect(find.byKey(FindingsPanel.panelKey), findsNothing);
  });

  group('build step 4 controls', () {
    Future<void> pumpButtonPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: Scaffold(
            body: Center(
              child: IconButton(
                onPressed: () {},
                icon: const Icon(Icons.add, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('Check accessibility lists the audit, then semantics go '
        'off again', (tester) async {
      await pumpButtonPage(tester);
      await openPanel(tester);
      await tester.tap(find.byKey(FindingsPanel.auditKey));
      // One frame builds the semantics; the contrast capture then needs
      // real time, outside the fake clock.
      for (var i = 0; i < 10 && controller.findings.auditing; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
      expect(controller.findings.auditing, isFalse);
      expect(controller.findings.findings.map((f) => f.kind).toSet(), {
        'unlabeled_action',
        'small_tap_target',
      });
      // Pinpoint's own small buttons are not the app's.
      expect(
        controller.findings.findings.every(
          (f) => f.data['widget'] == 'IconButton',
        ),
        isTrue,
      );
      expect(SemanticsBinding.instance.semanticsEnabled, isFalse);
    }, semanticsEnabled: false);

    testWidgets('with rebuild heat on, a scan lists the hot spots and tints '
        'them', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      await tester.tap(find.byKey(FindingsPanel.rebuildsKey));
      await tester.pump();
      expect(controller.findings.trackRebuilds, isTrue);
      for (var i = 0; i < 12; i++) {
        showRow.value = !showRow.value;
        await tester.pump();
      }
      await scan(tester);
      final heat = controller.findings.findings
          .where((f) => f.kind == 'rebuild_heat')
          .toList();
      expect(heat, isNotEmpty);
      expect(heat.first.data['count'], greaterThanOrEqualTo(12));
      expect(
        find.byKey(InspectorOverlay.findingKey),
        paints..rect(color: FindingPainter.heat.withValues(alpha: 0.18)),
      );

      await tester.tap(find.byKey(FindingsPanel.rebuildsKey));
      await tester.pump();
      expect(debugOnRebuildDirtyWidget, isNull);
    });

    testWidgets('the debug paint chips set the flags', (tester) async {
      await pumpHost(tester);
      await openPanel(tester);
      await tester.tap(find.byKey(FindingsPanel.paintKey(DebugPaintFlag.size)));
      await tester.pump();
      expect(debugPaintSizeEnabled, isTrue);
      await tester.tap(find.byKey(FindingsPanel.paintKey(DebugPaintFlag.size)));
      await tester.pump();
      expect(debugPaintSizeEnabled, isFalse);
    });
  });
}
