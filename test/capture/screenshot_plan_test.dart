import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/capture/screenshot.dart';

/// Milestone 6, build step 1: the crop math as pure functions, fractional
/// pixel ratios included.
void main() {
  const bounds = Size(800, 600);
  final screen = Offset.zero & bounds;

  group('cropFor', () {
    test('a small widget keeps 320 x 200 of its surroundings, centred', () {
      final target = Rect.fromCenter(
        center: const Offset(400, 300),
        width: 24,
        height: 24,
      );
      final crop = cropFor(target, bounds);
      expect(crop.size, minCropSize);
      expect(crop.center, target.center);
    });

    test('a large widget gets 48 px around it', () {
      const target = Rect.fromLTWH(100, 100, 500, 300);
      expect(cropFor(target, bounds), target.inflate(cropMargin));
    });

    test('at the screen edge the crop moves inside, so it keeps its size', () {
      const corner = Rect.fromLTWH(0, 0, 24, 24);
      final crop = cropFor(corner, bounds);
      expect(crop, const Rect.fromLTWH(0, 0, 320, 200));

      const farCorner = Rect.fromLTWH(776, 576, 24, 24);
      expect(
        cropFor(farCorner, bounds),
        const Rect.fromLTWH(480, 400, 320, 200),
      );
    });

    test('a widget larger than the screen is cut to the screen', () {
      const target = Rect.fromLTWH(-100, -50, 1200, 900);
      expect(cropFor(target, bounds), screen);
    });

    test('a widget partly scrolled off keeps only what is on screen', () {
      const target = Rect.fromLTWH(100, 500, 600, 300);
      final crop = cropFor(target, bounds);
      expect(screen.intersect(crop), crop);
      expect(crop.bottom, 600);
      expect(crop.left, 100 - cropMargin);
    });

    test('a widget off screen gives an empty crop', () {
      const target = Rect.fromLTWH(900, 100, 50, 50);
      expect(cropFor(target, bounds).isEmpty, isTrue);
    });

    test('a screen smaller than the minimum is taken whole', () {
      const small = Size(300, 150);
      const target = Rect.fromLTWH(10, 10, 20, 20);
      expect(cropFor(target, small), Offset.zero & small);
    });
  });

  group('pixelRectFor', () {
    const image = Size(2000, 1500);

    test('is exact for a whole ratio', () {
      const rect = Rect.fromLTWH(10, 20, 100, 50);
      expect(
        pixelRectFor(rect, 2, image),
        const Rect.fromLTWH(20, 40, 200, 100),
      );
    });

    for (final ratio in [1.25, 1.5, 2.625, 0.83]) {
      test('rounds outward to whole pixels at ratio $ratio', () {
        const rect = Rect.fromLTWH(10.3, 20.7, 100.1, 30.2);
        final pixels = pixelRectFor(rect, ratio, image);
        for (final edge in [
          pixels.left,
          pixels.top,
          pixels.right,
          pixels.bottom,
        ]) {
          expect(edge, edge.roundToDouble(), reason: 'whole pixels');
        }
        final exact = Rect.fromLTRB(
          rect.left * ratio,
          rect.top * ratio,
          rect.right * ratio,
          rect.bottom * ratio,
        );
        expect(pixels.left, lessThanOrEqualTo(exact.left));
        expect(pixels.top, lessThanOrEqualTo(exact.top));
        expect(pixels.right, greaterThanOrEqualTo(exact.right));
        expect(pixels.bottom, greaterThanOrEqualTo(exact.bottom));
        expect(exact.left - pixels.left, lessThan(1));
        expect(pixels.right - exact.right, lessThan(1));
      });
    }

    test('does not add a pixel for a float error', () {
      // 200 * 1.1 is 220.00000000000003 in doubles.
      const rect = Rect.fromLTWH(0, 0, 200, 100);
      expect(pixelRectFor(rect, 1.1, image).width, 220);
    });

    test('is clamped to the image', () {
      const rect = Rect.fromLTWH(-5.5, -3, 2000, 1000);
      final pixels = pixelRectFor(rect, 1.25, image);
      expect(pixels.left, 0);
      expect(pixels.top, 0);
      expect(pixels.right, image.width);
      expect(pixels.bottom, lessThanOrEqualTo(image.height));
    });
  });

  group('planCapture', () {
    const target = Rect.fromLTWH(333.3, 222.7, 41.9, 17.3);

    for (final ratio in [1.0, 1.25, 1.5, 2.0, 2.625]) {
      test('the image size is the crop size times $ratio', () {
        final plan = planCapture(target, bounds, ratio)!;
        expect(plan.pixelRatio, ratio);
        expect(plan.width, (plan.crop.width * ratio).round());
        expect(plan.height, (plan.crop.height * ratio).round());
        expect(plan.width, plan.source.width);
        expect(plan.height, plan.source.height);
      });

      test('the source stays inside the full capture at $ratio', () {
        final full = fullImageSize(bounds, ratio);
        // A target at the far edge, where rounding outward could leave the
        // image.
        final edge = Rect.fromLTWH(
          bounds.width - 7.3,
          bounds.height - 3.1,
          7.3,
          3.1,
        );
        for (final t in [target, edge]) {
          final plan = planCapture(t, bounds, ratio)!;
          expect(plan.source.left, greaterThanOrEqualTo(0));
          expect(plan.source.top, greaterThanOrEqualTo(0));
          expect(plan.source.right, lessThanOrEqualTo(full.width));
          expect(plan.source.bottom, lessThanOrEqualTo(full.height));
        }
      });

      test('the outline sits on the target within 1 px at $ratio', () {
        final plan = planCapture(target, bounds, ratio)!;
        final expected = Rect.fromLTRB(
          (target.left - plan.crop.left) * ratio,
          (target.top - plan.crop.top) * ratio,
          (target.right - plan.crop.left) * ratio,
          (target.bottom - plan.crop.top) * ratio,
        );
        expect((plan.outline.left - expected.left).abs(), lessThan(1));
        expect((plan.outline.top - expected.top).abs(), lessThan(1));
        expect((plan.outline.right - expected.right).abs(), lessThan(1));
        expect((plan.outline.bottom - expected.bottom).abs(), lessThan(1));
      });
    }

    test('is null for a target off screen', () {
      expect(
        planCapture(const Rect.fromLTWH(900, 0, 10, 10), bounds, 2),
        isNull,
      );
    });

    test('is null for a ratio that is not positive or finite', () {
      expect(planCapture(target, bounds, 0), isNull);
      expect(planCapture(target, bounds, double.nan), isNull);
    });
  });
}
