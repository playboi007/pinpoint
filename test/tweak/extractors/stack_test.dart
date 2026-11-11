import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/stack_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderStack and StackParentData
/// (Stack, Positioned).
void main() {
  testWidgets('stack alignment and fit; positioned offsets', (tester) async {
    const stack = Key('stack');
    const loose = Key('loose');
    const placed = Key('placed');
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 100,
            child: Stack(
              key: stack,
              children: [
                SizedBox(key: loose, width: 20, height: 20),
                Positioned(
                  left: 10,
                  top: 10,
                  child: SizedBox(key: placed, width: 20, height: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final ro = tester.renderObject(find.byKey(stack));
    setProperty(ro, stackSection, 'alignment', Alignment.bottomRight);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(loose)), const Offset(180, 80));

    setProperty(ro, stackSection, 'fit', StackFit.expand);
    await tester.pump();
    expect(tester.getSize(find.byKey(loose)), const Size(200, 100));

    final child = tester.renderObject(find.byKey(placed));
    expect(stackSection(child), isNull);
    setProperty(child, positionedSection, 'left', 50.0);
    setProperty(child, positionedSection, 'width', 60.0);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(placed)), const Offset(50, 10));
    expect(tester.getSize(find.byKey(placed)).width, 60);
    expect(labelOf(child, positionedSection, 'right'), 'none');
  });

  test('registered; Positioned is parent data', () {
    expect(WidgetInfo.renderExtractors, contains(stackSection));
    expect(WidgetInfo.parentDataExtractors, contains(positionedSection));
  });
}
