import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/extractors/opacity_extractor.dart';

import 'support.dart';

/// Milestone 11, build step 4: RenderOpacity (Opacity).
void main() {
  testWidgets('opacity repaints the child faded', (tester) async {
    const opacity = Key('opacity');
    await tester.pumpWidget(
      const Center(
        child: Opacity(
          key: opacity,
          opacity: 1,
          child: ColoredBox(
            color: Color(0xFF0000FF),
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      ),
    );
    final ro = tester.renderObject<RenderOpacity>(find.byKey(opacity));
    setProperty(ro, opacitySection, 'opacity', 0.5);
    await tester.pump();
    expect(ro.opacity, 0.5);
    expect(ro.debugNeedsPaint, isFalse);
    expect(tester.layers.whereType<OpacityLayer>().single.alpha, 128);
    expect(labelOf(ro, opacitySection, 'opacity'), '0.5');
  });

  test('registered', () {
    expect(WidgetInfo.renderExtractors, contains(opacitySection));
  });
}
