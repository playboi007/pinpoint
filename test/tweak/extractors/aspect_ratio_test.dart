import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/aspect_ratio_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderAspectRatio (AspectRatio).
void main() {
  testWidgets('the ratio sets the height from the width', (tester) async {
    const ratio = Key('ratio');
    await tester.pumpWidget(
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          child: AspectRatio(key: ratio, aspectRatio: 2),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(ratio)), const Size(200, 100));
    setProperty(
      tester.renderObject(find.byKey(ratio)),
      aspectRatioSection,
      'aspectRatio',
      4.0,
    );
    await tester.pump();
    expect(tester.getSize(find.byKey(ratio)), const Size(200, 50));
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(aspectRatioSection));
  });
}
