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
      expect(layout.hammer, isFalse);
      expect(layout.cones, isFalse);
      expect(layout.barrow, isFalse);
      expect(layout.painter, isFalse);
      expect(layout.classes, ['ppc-bare']);
      final tall = ConstructionLayout.of(300, 24);
      expect(tall.hammer, isTrue);
    });

    test('a worker is min(56 px, 85% of the height) at most', () {
      expect(ConstructionLayout.of(600, 400).workerHeight, 56);
      final short = ConstructionLayout.of(600, 40);
      expect(short.workerHeight, lessThanOrEqualTo(0.85 * 40));
      expect(short.workerHeight, greaterThanOrEqualTo(14));
    });

    test('the workers stay below the tape', () {
      for (final h in [24.0, 30.0, 40.0, 60.0, 120.0]) {
        final layout = ConstructionLayout.of(500, h);
        if (!layout.hammer) continue;
        expect(
          layout.height - layout.workerHeight - 2,
          greaterThanOrEqualTo(layout.tapeTop + layout.tapeHeight - 0.01),
          reason: 'height $h',
        );
      }
    });

    test('narrow: one hammer worker, in the middle', () {
      final layout = ConstructionLayout.of(70, 80);
      expect(layout.hammer, isTrue);
      expect(layout.barrow, isFalse);
      expect(layout.painter, isFalse);
      final hammerWidth = 95 * layout.hammerScale;
      expect(
        layout.hammerLeft,
        closeTo((layout.width - hammerWidth) / 2, 0.01),
      );
    });

    test('a very narrow widget shrinks the worker to fit, or has none', () {
      final fits = ConstructionLayout.of(40, 80);
      if (fits.hammer) {
        expect(95 * fits.hammerScale, lessThanOrEqualTo(fits.width));
      }
      expect(ConstructionLayout.of(14, 80).hammer, isFalse);
    });

    test('medium: hammer at the left, the wheelbarrow, a cone at each end', () {
      final layout = ConstructionLayout.of(360, 70);
      expect(layout.hammer, isTrue);
      expect(layout.cones, isTrue);
      expect(layout.barrow, isTrue);
      expect(layout.barrowRun, greaterThanOrEqualTo(ConstructionLayout.minRun));
      expect(layout.hammerLeft, lessThan(layout.width / 4));
    });

    test('wide: and a painter at the right when there is room', () {
      final layout = ConstructionLayout.of(900, 180);
      expect(layout.painter, isTrue);
      expect(layout.classes, containsAll(['ppc-cones', 'ppc-barrow-on']));
      expect(layout.classes, contains('ppc-painter-on'));
      // The barrow never walks into the painter or the hammer worker.
      final barrowWidth = 121 * layout.barrowScale;
      final painterLeft =
          layout.width - layout.painterRight - 114 * layout.painterScale;
      expect(
        layout.barrowLeft + layout.barrowRun + barrowWidth,
        lessThanOrEqualTo(painterLeft),
      );
      expect(
        layout.barrowLeft,
        greaterThanOrEqualTo(layout.hammerLeft + 95 * layout.hammerScale),
      );
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
      expect(vars, isNot(contains('NaN')));
    });
  });

  group('the markup', () {
    final urls = {
      for (final name in ConstructionMarkup.assetNames) name: 'x/$name.webp',
    };

    test('has the eight assets of the folder, each used', () {
      expect(ConstructionMarkup.assetNames, hasLength(8));
      final html = ConstructionMarkup.siteHtml(urls);
      for (final name in ConstructionMarkup.assetNames) {
        expect(html, contains('src="x/$name.webp"'));
      }
      expect(html, contains('UNDER PROGRESS'));
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
      ]) {
        expect(css, contains('@keyframes $name'));
      }
      expect(css, contains('prefers-reduced-motion:reduce'));
      expect(css, contains('.${ConstructionMarkup.reducedClass}'));
      expect(css, contains('mix-blend-mode:multiply'));
      expect(css, contains('repeating-linear-gradient'));
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
