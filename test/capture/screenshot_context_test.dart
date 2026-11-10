import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/capture/screenshot.dart';

/// Milestone 6, build step 3: what the payload says about the image besides
/// its pixels.
void main() {
  group('debugPaintFlagsOn', () {
    test('is empty with every flag off', () {
      expect(debugPaintFlagsOn(), isEmpty);
    });

    test('names each flag that is on, because its marks are in the image', () {
      // flutter_test fails a test that leaves a paint flag set; reset it
      // here, in the test body.
      debugPaintSizeEnabled = true;
      debugRepaintRainbowEnabled = true;
      try {
        expect(debugPaintFlagsOn(), [
          'debugPaintSizeEnabled',
          'debugRepaintRainbowEnabled',
        ]);
      } finally {
        debugPaintSizeEnabled = false;
        debugRepaintRainbowEnabled = false;
      }
    });
  });

  group('platformViewsIn', () {
    final rootKey = GlobalKey();
    const view = Rect.fromLTWH(400, 300, 200, 100);

    Future<Element> pump(WidgetTester tester, {required bool withView}) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            key: rootKey,
            children: [
              const Positioned(left: 10, top: 10, child: Text('plain')),
              if (withView)
                Positioned.fromRect(
                  rect: view,
                  child: PlatformViewLink(
                    viewType: 'pinpoint.test',
                    onCreatePlatformView: (params) {
                      params.onPlatformViewCreated(params.id);
                      return _FakeController(params.id);
                    },
                    surfaceFactory: (context, controller) =>
                        PlatformViewSurface(
                          controller: controller,
                          gestureRecognizers:
                              const <Factory<OneSequenceGestureRecognizer>>{},
                          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                        ),
                  ),
                ),
            ],
          ),
        ),
      );
      return rootKey.currentContext! as Element;
    }

    testWidgets('finds a platform view that overlaps the crop', (tester) async {
      final root = await pump(tester, withView: true);
      expect(
        platformViewsIn(root, const Rect.fromLTWH(350, 250, 100, 100)),
        isTrue,
      );
    });

    testWidgets('ignores a platform view outside the crop', (tester) async {
      final root = await pump(tester, withView: true);
      expect(
        platformViewsIn(root, const Rect.fromLTWH(0, 0, 320, 200)),
        isFalse,
      );
    });

    testWidgets('is false with no platform view', (tester) async {
      final root = await pump(tester, withView: false);
      expect(
        platformViewsIn(root, const Rect.fromLTWH(0, 0, 800, 600)),
        isFalse,
      );
    });

    testWidgets('is null when the walk hits its cap, so the note can say it '
        'does not know', (tester) async {
      final root = await pump(tester, withView: false);
      expect(
        platformViewsIn(root, const Rect.fromLTWH(0, 0, 800, 600), maxNodes: 2),
        isNull,
      );
    });
  });
}

class _FakeController extends PlatformViewController {
  _FakeController(this.viewId);

  @override
  final int viewId;

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}
}
