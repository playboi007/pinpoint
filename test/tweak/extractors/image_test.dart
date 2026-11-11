import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/image_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderImage (Image, RawImage).
void main() {
  testWidgets('fit sizes the image in its box', (tester) async {
    final image = (await tester.runAsync(
      () => createTestImage(width: 100, height: 50),
    ))!;
    addTearDown(image.dispose);
    const raw = Key('raw');
    await tester.pumpWidget(
      Center(
        child: RawImage(key: raw, image: image, width: 100, height: 100),
      ),
    );
    final ro = tester.renderObject<RenderImage>(find.byKey(raw));
    expect(labelOf(ro, imageSection, 'fit'), 'none');
    setProperty(ro, imageSection, 'fit', BoxFit.fill);
    await tester.pump();
    expect(ro.fit, BoxFit.fill);
    expect(
      ro,
      paints..drawImageRect(destination: const Rect.fromLTWH(0, 0, 100, 100)),
    );
    setProperty(ro, imageSection, 'fit', null);
    expect(ro.fit, isNull);
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(imageSection));
  });
}
