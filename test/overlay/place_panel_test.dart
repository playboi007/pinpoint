import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';

/// Milestone 5, build step 1: where the panel goes next to its target.
void main() {
  const viewport = Size(1280, 720);
  const panel = Size(360, 300);
  const marginX = panelMarginX;
  const marginY = panelMarginY;
  const gap = panelGap;

  Rect placed(Rect target, {Size size = panel, Size area = viewport}) =>
      placePanel(target, size, area) & size;

  bool inside(Rect rect, Size area) =>
      rect.left >= marginX - 1e-9 &&
      rect.top >= marginY - 1e-9 &&
      rect.right <= area.width - marginX + 1e-9 &&
      rect.bottom <= area.height - marginY + 1e-9;

  group('order: below, above, right, left', () {
    test('below the target when there is room', () {
      const target = Rect.fromLTWH(100, 100, 80, 20);
      expect(placePanel(target, panel, viewport), const Offset(100, 128));
    });

    test('above when there is no room below', () {
      const target = Rect.fromLTWH(100, 600, 80, 20);
      expect(
        placePanel(target, panel, viewport),
        Offset(100, 600 - gap - panel.height),
      );
    });

    test('right when neither below nor above fits', () {
      // 500 px tall in a 720 px viewport: no room for 300 above or below.
      const target = Rect.fromLTWH(100, 110, 200, 500);
      expect(placePanel(target, panel, viewport), const Offset(300 + gap, 110));
    });

    test('left when right does not fit either', () {
      const target = Rect.fromLTWH(800, 110, 300, 500);
      expect(
        placePanel(target, panel, viewport),
        Offset(800 - gap - panel.width, 110),
      );
    });

    test('when no side fits, the side with the most room', () {
      // A 300 px tall, 360 px wide panel reaches past the margin by 52 px
      // below, 100 px above, 16 px to the right and 364 px to the left.
      const target = Rect.fromLTWH(12, 220, 908, 232);
      final at = placePanel(target, panel, viewport);
      expect(at, Offset(viewport.width - marginX - panel.width, 220));
      // Pulled back 16 px, less the 8 px gap: 8 px over the target.
      final covered = (at & panel).intersect(target);
      expect(covered.width, closeTo(8, 1e-9));
    });

    test('over the target, clamped, when no side fits at all', () {
      const target = Rect.fromLTWH(0, 0, 1280, 720);
      final rect = placed(target);
      expect(inside(rect, viewport), isTrue);
      expect(rect.size, panel);
    });
  });

  group('clamping with an 8 px side and a 12 px top and bottom margin', () {
    test('below a target at the right edge, pulled back inside', () {
      const target = Rect.fromLTWH(1200, 100, 80, 20);
      expect(
        placePanel(target, panel, viewport).dx,
        viewport.width - marginX - panel.width,
      );
    });

    test('below a target off the left edge, pushed inside', () {
      const target = Rect.fromLTWH(-50, 100, 80, 20);
      expect(placePanel(target, panel, viewport).dx, marginX);
    });

    test('beside a target that starts above the screen', () {
      const target = Rect.fromLTWH(100, -200, 200, 900);
      final at = placePanel(target, panel, viewport);
      expect(at.dy, marginY);
      expect(at.dx, 300 + gap);
    });

    test('a panel larger than the viewport sits at the margin', () {
      final at = placePanel(
        const Rect.fromLTWH(10, 10, 10, 10),
        const Size(2000, 2000),
        viewport,
      );
      expect(at, const Offset(marginX, marginY));
    });

    test('a target with no finite rect still gives a finite place', () {
      final at = placePanel(
        const Rect.fromLTRB(0, 0, double.infinity, double.nan),
        panel,
        viewport,
      );
      expect(at.isFinite, isTrue);
      expect(inside(at & panel, viewport), isTrue);
    });

    test('clampPanel keeps a dragged panel inside the margin', () {
      expect(
        clampPanel(const Offset(-500, -500), panel, viewport),
        const Offset(marginX, marginY),
      );
      expect(
        clampPanel(const Offset(5000, 5000), panel, viewport),
        Offset(
          viewport.width - marginX - panel.width,
          viewport.height - marginY - panel.height,
        ),
      );
      expect(
        clampPanel(const Offset(200, 100), panel, viewport),
        const Offset(200, 100),
      );
    });
  });

  group('acceptance: never overflows at 360 px and 1920 px widths', () {
    for (final area in const [Size(360, 640), Size(1920, 1080)]) {
      test('${area.width.toInt()} x ${area.height.toInt()}', () {
        final width = panelWidthFor(area.width);
        expect(width, lessThanOrEqualTo(area.width - 2 * marginX));
        // Short, typical and as tall as the space allows.
        final heights = [120.0, 420.0, area.height - 2 * marginY];
        // Targets of many sizes all over the screen and past its edges.
        for (final height in heights) {
          final size = Size(width, height);
          for (var x = -100.0; x <= area.width + 100; x += 37) {
            for (var y = -100.0; y <= area.height + 100; y += 41) {
              for (final target in [
                Rect.fromLTWH(x, y, 24, 24),
                Rect.fromLTWH(x, y, 300, 48),
                Rect.fromLTWH(x, y, area.width, 200),
              ]) {
                final rect = placed(target, size: size, area: area);
                expect(
                  inside(rect, area),
                  isTrue,
                  reason: 'target $target, panel $size, got $rect',
                );
              }
            }
          }
        }
      });
    }

    test('panelWidthFor caps at InfoPanel.width', () {
      expect(panelWidthFor(1920), InfoPanel.width);
      expect(panelWidthFor(360), 360 - 2 * marginX);
      expect(panelWidthFor(10), 0);
    });
  });
}
