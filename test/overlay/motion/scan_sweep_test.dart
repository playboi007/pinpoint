import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/note_book.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/findings_controller.dart';
import 'package:pinpoint/src/overlay/findings_panel.dart';
import 'package:pinpoint/src/overlay/motion/scan_sweep.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// Moment 5: "Scan this screen" sweeps a line over the app once, and the
/// findings' markers pop in as it passes.
void main() {
  late FindingsController findings;

  setUp(() {
    findings = FindingsController()
      ..setScanned(const [
        Finding(
          kind: 'overflow',
          severity: Severity.error,
          summary: 'Row overflows by 12 px',
          rect: Rect.fromLTWH(20, 100, 200, 40),
        ),
        Finding(
          kind: 'truncated_text',
          severity: Severity.warning,
          summary: 'Text is cut',
          rect: Rect.fromLTWH(20, 400, 200, 20),
        ),
      ]);
  });
  tearDown(() => findings.dispose());

  Future<void> pump(WidgetTester tester, {bool reduced = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              disableAnimations: reduced,
            ),
            child: SizedBox.expand(
              child: ScanSweep(findings: findings, origin: () => Offset.zero),
            ),
          ),
        ),
      );

  RenderBox paintBox(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byKey(ScanSweep.paintKey));

  /// Matches a canvas with at least [n] paths drawn. The line is two paths
  /// (halo and mark); each marker is four (outline and corner mark, each
  /// over a halo).
  PaintPattern paintsAtLeast(int n) {
    final pattern = paints;
    for (var i = 0; i < n; i++) {
      pattern.path();
    }
    return pattern;
  }

  testWidgets('at rest it runs nothing and paints nothing', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(paintBox(tester), paintsNothing);
  });

  testWidgets('a scan asks for one sweep: the line moves down, markers pop '
      'in as it passes, and all of it ends', (tester) async {
    await pump(tester);
    findings.sweep();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    // 100 ms in: the line is near the top, above both findings.
    expect(paintBox(tester), paintsAtLeast(2));
    expect(paintBox(tester), isNot(paintsAtLeast(3)));

    // 300 ms: the line is past the first finding (y 100 of 600), not the
    // second (y 400).
    await tester.pump(const Duration(milliseconds: 200));
    expect(paintBox(tester), paintsAtLeast(6));
    expect(paintBox(tester), isNot(paintsAtLeast(10)));

    // 500 ms: the line is past both.
    await tester.pump(const Duration(milliseconds: 200));
    expect(paintBox(tester), paintsAtLeast(10));

    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(paintBox(tester), paintsNothing, reason: 'gone after the sweep');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the sweep takes about 1.5 s in all, no more', (tester) async {
    await pump(tester);
    findings.sweep();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a second scan sweeps again', (tester) async {
    await pump(tester);
    findings.sweep();
    await tester.pumpAndSettle();
    findings.sweep();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    expect(paintBox(tester), paintsAtLeast(2));
    await tester.pumpAndSettle();
    expect(paintBox(tester), paintsNothing);
  });

  testWidgets('a rescan that is not the button does not sweep', (tester) async {
    await pump(tester);
    findings.setScanned(const []);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(paintBox(tester), paintsNothing);
  });

  testWidgets('reduced motion: no sweep, no markers, no running animation', (
    tester,
  ) async {
    await pump(tester, reduced: true);
    findings.sweep();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(paintBox(tester), paintsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(paintBox(tester), paintsNothing);
  });

  testWidgets('it takes no pointer events', (tester) async {
    await pump(tester);
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(ScanSweep.paintKey),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('"Scan this screen" scans first, then asks for a sweep', (
    tester,
  ) async {
    final notes = NoteBook();
    addTearDown(notes.dispose);
    final order = <String>[];
    findings.sweeps.addListener(() => order.add('sweep'));
    await tester.pumpWidget(
      MaterialApp(
        theme: pinPointThemeData(PinPointPalette.redline),
        home: Scaffold(
          body: FindingsPanel(
            findings: findings,
            notes: notes,
            onScan: () => order.add('scan'),
            onAudit: () {},
            onMakeNote: (_) {},
            onSendDraft: (_) {},
            onCopy: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(FindingsPanel.scanKey));
    await tester.pump();
    expect(order, ['scan', 'sweep']);
    expect(findings.sweeps.value, 1);
  });
}
