import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/construction/construction_layout.dart';
import 'package:pinpoint/src/overlay/construction/construction_markup.dart';

/// How a site is laid out for the size of its widget, and the markup and
/// CSS that carry it. All plain strings and numbers.
void main() {
  group('the layout', () {
    test('covers the widget and 1 px more on each side', () {
      final layout = ConstructionLayout.of(200, 60);
      expect(layout.width, 202);
      expect(layout.height, 62);
    });

    test('under 24 px tall there are no workers: tape and hatching', () {
      final layout = ConstructionLayout.of(300, 23);
      expect(layout.hasWorkers, isFalse);
      expect(layout.planners, 0);
      expect(layout.hammer, isFalse);
      expect(layout.cones, isFalse);
      expect(layout.barrow, isFalse);
      expect(layout.painter, isFalse);
      expect(layout.classes, ['ppc-bare']);
      final tall = ConstructionLayout.of(300, 24);
      expect(tall.hasWorkers, isTrue);
    });

    test('a worker is 56 px, or half the height on a big widget (at most '
        '110 px), and never over 85% of the height', () {
      expect(ConstructionLayout.of(600, 100).workerHeight, 56);
      expect(ConstructionLayout.of(900, 180).workerHeight, 90);
      expect(ConstructionLayout.of(900, 400).workerHeight, 110);
      final short = ConstructionLayout.of(600, 40);
      expect(short.workerHeight, lessThanOrEqualTo(0.85 * 40));
      expect(short.workerHeight, greaterThanOrEqualTo(14));
    });

    test('the snapped tape swings down at most 35 degrees, less on a wide '
        'widget, so it stays over it', () {
      expect(ConstructionLayout.of(900, 180).fallDegrees, closeTo(15.6, 0.2));
      expect(ConstructionLayout.of(60, 200).fallDegrees, 35);
      expect(ConstructionLayout.of(2000, 20).fallDegrees, 6);
      expect(ConstructionLayout.of(900, 180).variables, contains('--fa:'));
    });

    test('the workers stay below the tape', () {
      for (final h in [24.0, 30.0, 40.0, 60.0, 120.0]) {
        final layout = ConstructionLayout.of(500, h);
        if (!layout.hasWorkers) continue;
        expect(
          layout.height - layout.workerHeight - 2,
          greaterThanOrEqualTo(layout.tapeTop + layout.tapeHeight - 0.01),
          reason: 'height $h',
        );
      }
    });

    test('small: planners only, boxes still shown', () {
      final layout = ConstructionLayout.of(140, 60);
      expect(layout.hasWorkers, isTrue);
      expect(layout.planners, 2);
      expect(layout.hammer, isFalse);
      expect(layout.cones, isFalse);
      expect(layout.barrow, isFalse);
      expect(layout.painter, isFalse);
      expect(layout.classes, ['ppc-plan2']);
    });

    test('very small: one planner, the one that reads the blueprint', () {
      final layout = ConstructionLayout.of(70, 80);
      expect(layout.hasWorkers, isTrue);
      expect(layout.planners, 1);
      expect(layout.hammer, isFalse);
      expect(layout.classes, isNot(contains('ppc-plan2')));
      final plannerWidth = 74 * layout.hammerScale;
      expect(plannerWidth, lessThanOrEqualTo(layout.width - 8));
    });

    test('a very narrow widget shrinks the workers to fit, or has none', () {
      final fits = ConstructionLayout.of(40, 80);
      if (fits.hasWorkers) {
        expect(74 * fits.hammerScale, lessThanOrEqualTo(fits.width));
      }
      expect(ConstructionLayout.of(14, 80).hasWorkers, isFalse);
    });

    test('medium: planners and the builder, between cones', () {
      final layout = ConstructionLayout.of(220, 70);
      expect(layout.planners, 2);
      expect(layout.hammer, isTrue);
      expect(layout.cones, isTrue);
      expect(layout.barrow, isFalse);
      expect(layout.painter, isFalse);
      // The builder stays left of the planners.
      expect(
        layout.hammerLeft + 95 * layout.hammerScale,
        lessThanOrEqualTo(layout.zoneEnd),
      );
      expect(
        layout.zoneEnd,
        lessThanOrEqualTo(layout.width - layout.plannersWidth),
      );
    });

    test('wider: and the wheelbarrow, a cone at each end', () {
      final layout = ConstructionLayout.of(360, 70);
      expect(layout.hammer, isTrue);
      expect(layout.cones, isTrue);
      expect(layout.barrow, isTrue);
      expect(layout.barrowRun, greaterThanOrEqualTo(ConstructionLayout.minRun));
      expect(layout.hammerLeft, lessThan(layout.width / 4));
    });

    test('wide: everything, with the painter for the finish', () {
      final layout = ConstructionLayout.of(900, 180);
      expect(layout.painter, isTrue);
      expect(
        layout.classes,
        containsAll([
          'ppc-plan2',
          'ppc-hammer-on',
          'ppc-cones',
          'ppc-barrow-on',
          'ppc-painter-on',
        ]),
      );
      // The wheelbarrow never walks into the builder or the planners.
      final barrowWidth = 121 * layout.barrowScale;
      expect(
        layout.barrowLeft + layout.barrowRun + barrowWidth,
        lessThanOrEqualTo(layout.zoneEnd),
      );
      expect(
        layout.barrowLeft,
        greaterThanOrEqualTo(layout.hammerLeft + 95 * layout.hammerScale),
      );
    });

    test('the parts come in as the widget grows', () {
      var steps = 0;
      var last = (0, false, false, false);
      for (var w = 40.0; w <= 1000; w += 20) {
        final l = ConstructionLayout.of(w, 100);
        final now = (l.planners, l.hammer, l.barrow, l.painter);
        // Never fewer parts on a wider widget.
        expect(now.$1, greaterThanOrEqualTo(last.$1), reason: 'width $w');
        for (final (a, b) in [
          (now.$2, last.$2),
          (now.$3, last.$3),
          (now.$4, last.$4),
        ]) {
          expect(!a && b, isFalse, reason: 'width $w');
        }
        if (now != last) steps++;
        last = now;
      }
      expect(steps, greaterThanOrEqualTo(4));
    });

    test('the tape text shrinks with the width', () {
      expect(ConstructionLayout.of(900, 100).tapeFont, 10);
      expect(
        ConstructionLayout.of(80, 100).tapeFont,
        lessThan(ConstructionLayout.of(900, 100).tapeFont),
      );
    });

    test('the variables are CSS custom properties with units', () {
      final vars = ConstructionLayout.of(500, 80).variables;
      expect(vars, contains('--sh:'));
      expect(vars, contains('--run:'));
      expect(vars, matches(RegExp(r'--bl:[\d.]+px')));
      expect(vars, contains('--wd:'));
      for (final name in [
        '--sw',
        '--hin',
        '--bin',
        '--pout',
        '--pa',
        '--pb',
        '--cl2',
        '--ppw',
        '--prun',
        '--dl',
      ]) {
        expect(vars, contains('$name:'));
      }
      expect(vars, isNot(contains('NaN')));
      expect(vars, isNot(contains('Infinity')));
    });
  });

  group('the markup', () {
    final urls = {
      for (final name in ConstructionMarkup.assetNames) name: 'x/$name.webp',
    };

    test('uses every asset of the manifest, each in its place', () {
      final html = ConstructionMarkup.siteHtml(urls);
      for (final name in ConstructionMarkup.assetNames) {
        expect(html, contains('src="x/$name.webp"'));
      }
      expect(html, contains('UNDER PROGRESS'));
      // Every two-frame character has both frames.
      for (final pair in [
        'planner_read',
        'planner_point',
        'builder',
        'walk',
        'painter',
      ]) {
        expect(html, contains('x/${pair}_a.webp'));
        expect(html, contains('x/${pair}_b.webp'));
      }
    });

    test('asset paths are inside the package', () {
      expect(
        ConstructionMarkup.assetPath('cone'),
        'packages/pinpoint/assets/construction/cone.webp',
      );
    });

    test('puts the site where the layout says', () {
      final layout = ConstructionLayout.of(200, 60);
      final style = ConstructionMarkup.siteStyle(layout, left: 9, top: 19);
      expect(style, startsWith('left:9.00px;top:19.00px;'));
      expect(style, contains('width:202.00px;height:62.00px;'));
      expect(
        ConstructionMarkup.siteClass(layout, revealing: true),
        contains(ConstructionMarkup.revealClass),
      );
      expect(
        ConstructionMarkup.siteClass(layout, revealing: true),
        isNot(contains(ConstructionMarkup.earlyClass)),
      );
      expect(
        ConstructionMarkup.siteClass(layout, revealing: true, early: true),
        contains(ConstructionMarkup.earlyClass),
      );
      expect(
        ConstructionMarkup.siteClass(layout, early: true),
        isNot(contains(ConstructionMarkup.earlyClass)),
        reason: 'only a finish can be early',
      );
    });

    test('the CSS follows the drafting rules: no blur, only hard shadows', () {
      const css = ConstructionMarkup.css;
      expect(css, isNot(contains('blur')));
      expect(css, isNot(contains('backdrop-filter')));
      expect(css, isNot(contains('border-radius')));
      expect(css, isNot(contains('drop-shadow')));
      // Every box-shadow is an offset with no blur radius.
      for (final m in RegExp(r'box-shadow:([^;}]*)').allMatches(css)) {
        expect(m.group(1), matches(RegExp(r'^\d+px \d+px 0 ')));
      }
    });

    test('the CSS has the motion, and a reduced-motion switch', () {
      const css = ConstructionMarkup.css;
      for (final name in [
        'ppc-swing',
        'ppc-dust',
        'ppc-walk',
        'ppc-la',
        'ppc-roll',
        'ppc-pop',
        'ppc-fall-l',
        'ppc-fall-r',
        'ppc-peel',
        'ppc-bounce',
        'ppc-break',
        'ppc-fix',
        'ppc-slip',
        'ppc-snap',
        'ppc-sweep',
        'ppc-dimx',
        'ppc-dimy',
        'ppc-hin',
        'ppc-bin',
        'ppc-pleave',
        'ppc-prun',
        'ppc-paint',
      ]) {
        expect(css, contains('@keyframes $name'));
      }
      expect(css, contains('prefers-reduced-motion:reduce'));
      expect(css, contains('.${ConstructionMarkup.reducedClass}'));
      expect(css, contains('mix-blend-mode:multiply'));
      expect(css, contains('repeating-linear-gradient'));
    });

    test('no Flutter-side motion: the CSS uses no JavaScript or timer', () {
      expect(ConstructionMarkup.css, isNot(contains('javascript')));
      expect(ConstructionMarkup.siteHtml(urls), isNot(contains('onload')));
      expect(ConstructionMarkup.siteHtml(urls), isNot(contains('<script')));
    });

    test('the root does not take pointer events', () {
      expect(
        ConstructionMarkup.css,
        contains('#${ConstructionMarkup.rootId}{position:fixed'),
      );
      expect(ConstructionMarkup.css, contains('pointer-events:none'));
    });
  });
}
