import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/align_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderPositionedBox (Align, Center).
void main() {
  testWidgets('alignment moves the child; factors size the box', (
    tester,
  ) async {
    const child = Key('child');
    const align = Key('align');
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          // Loose, so the width factor can make the Align smaller.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200, maxHeight: 100),
            child: const Align(
              key: align,
              child: SizedBox(key: child, width: 20, height: 20),
            ),
          ),
        ),
      ),
    );
    final ro = tester.renderObject(find.byKey(align));
    expect(tester.getTopLeft(find.byKey(child)), const Offset(90, 40));
    expect(labelOf(ro, alignSection, 'alignment'), 'Alignment.center');

    setProperty(ro, alignSection, 'alignment', Alignment.bottomRight);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(child)), const Offset(180, 80));

    setProperty(ro, alignSection, 'widthFactor', 2.0);
    await tester.pump();
    expect(tester.getSize(find.byKey(align)).width, 40);
  });

  test('named alignments read without the class name', () {
    expect(alignmentLabel(Alignment.topLeft), 'topLeft');
    expect(alignmentLabel(const Alignment(0.5, 0)), 'Alignment(0.5, 0.0)');
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(alignSection));
  });
}
