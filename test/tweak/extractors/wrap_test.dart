import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/wrap_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderWrap (Wrap).
void main() {
  testWidgets('spacing and run spacing move the children', (tester) async {
    const wrap = Key('wrap');
    const second = Key('second');
    const third = Key('third');
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 100,
            child: Wrap(
              key: wrap,
              children: [
                SizedBox(width: 40, height: 20),
                SizedBox(key: second, width: 40, height: 20),
                SizedBox(key: third, width: 40, height: 20),
              ],
            ),
          ),
        ),
      ),
    );
    final ro = tester.renderObject(find.byKey(wrap));
    setProperty(ro, wrapSection, 'spacing', 8.0);
    setProperty(ro, wrapSection, 'runSpacing', 4.0);
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(second)), const Offset(48, 0));
    expect(tester.getTopLeft(find.byKey(third)), const Offset(0, 24));
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(wrapSection));
  });
}
