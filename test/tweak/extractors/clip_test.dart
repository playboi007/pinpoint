import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/clip_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderClipRRect (ClipRRect).
void main() {
  testWidgets('a uniform radius is editable and clips again', (tester) async {
    const clip = Key('clip');
    await tester.pumpWidget(
      Center(
        child: ClipRRect(
          key: clip,
          borderRadius: BorderRadius.circular(4),
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );
    final ro = tester.renderObject<RenderClipRRect>(find.byKey(clip));
    setProperty(ro, clipSection, 'borderRadius', BorderRadius.circular(20));
    await tester.pump();
    expect(ro.borderRadius, BorderRadius.circular(20));
    expect(
      ro,
      paints..clipRRect(
        rrect: RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 40, 40),
          const Radius.circular(20),
        ),
      ),
    );
  });

  testWidgets('corners that differ are read-only', (tester) async {
    const clip = Key('clip');
    await tester.pumpWidget(
      const Center(
        child: ClipRRect(
          key: clip,
          borderRadius: BorderRadius.only(topLeft: Radius.circular(8)),
          child: SizedBox(width: 40, height: 40),
        ),
      ),
    );
    final property = clipSection(tester.renderObject(find.byKey(clip)))!
        .properties
        .single;
    expect(property.editable, isFalse);
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(clipSection));
  });
}
