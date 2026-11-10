import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/truncation_detector.dart';

/// Milestone 10, build step 2: truncated text.
void main() {
  final long = 'A long title that never fits on one line ' * 10;

  List<Finding> scan(WidgetTester tester) => scanTree(
    tester.binding.renderViews.first,
    const [TruncationDetector()],
  ).findings;

  Widget page(Widget child) => MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 200, child: child)),
    ),
  );

  testWidgets('acceptance: a Text with maxLines 1 and long content is '
      'listed with its full string', (tester) async {
    await tester.pumpWidget(
      page(Text(long, maxLines: 1, overflow: TextOverflow.ellipsis)),
    );

    final finding = scan(tester).single;
    expect(finding.kind, 'truncated_text');
    // Truncation is often intended (list titles): info, never auto-filed.
    expect(finding.severity, Severity.info);
    expect(finding.data['text'], '${long.substring(0, 300 - 1)}…');
    expect(finding.data['maxLines'], 1);
    expect(finding.data['overflow'], 'ellipsis');
    expect(finding.summary, startsWith('Text cut at 1 line: "A long title'));
    expect(finding.rect, tester.getRect(find.byType(RichText)));
  });

  testWidgets('a short string under 300 characters is kept whole', (
    tester,
  ) async {
    const text = 'Twelve words that are a little too many for this narrow box';
    await tester.pumpWidget(page(const Text(text, maxLines: 1)));
    expect(scan(tester).single.data['text'], text);
  });

  testWidgets('text that fits, or has no line limit, is silent', (
    tester,
  ) async {
    await tester.pumpWidget(page(const Text('Short', maxLines: 1)));
    expect(scan(tester), isEmpty);
    await tester.pumpWidget(page(Text(long)));
    expect(scan(tester), isEmpty);
  });

  testWidgets('the visible bounds are recorded', (tester) async {
    await tester.pumpWidget(page(Text(long, maxLines: 2)));
    final finding = scan(tester).single;
    final visible = finding.data['visible']! as Map<String, Object?>;
    expect(visible['w'], 200);
    expect(visible['h'], tester.getSize(find.byType(RichText)).height);
  });
}
