import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/construction/construction_assets.dart';
import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';
import 'package:pinpoint/src/overlay/construction/construction_layout.dart';
import 'package:pinpoint/src/overlay/construction/construction_markup.dart';

/// The lifecycle of a site: planning, building, finishing and reveal. All of
/// it is numbers in the markup and CSS (delays), so it is read here as text.
void main() {
  const css = ConstructionMarkup.css;
  final urls = {
    for (final name in ConstructionMarkup.assetNames) name: 'x/$name.webp',
  };

  /// The body of the rule whose selector list contains [selector].
  String rule(String selector) {
    final m = RegExp(
      '#${ConstructionMarkup.rootId} ${RegExp.escape(selector)}(?![\\w-])[^{]*\\{([^}]*)\\}',
    ).firstMatch(css);
    expect(m, isNotNull, reason: 'a rule for $selector');
    return m!.group(1)!;
  }

  String animationOf(String selector) {
    final body = rule(selector);
    final m = RegExp(r'animation:([^;]*)').firstMatch(body);
    expect(m, isNotNull, reason: '$selector has an animation');
    return m!.group(1)!;
  }

  List<ConstructionBox> boxes(int n) => [
    for (var i = 0; i < n; i++)
      ConstructionBox(4.0 + (i % 5) * 30, 4.0 + (i ~/ 5) * 20, 26, 16),
  ];

  group('planning: 2.5 s, from the moment the site goes up', () {
    test('the clock and the CSS say 2.5 s', () {
      expect(ConstructionTimeline.planSeconds, 2.5);
      expect(ConstructionMarkup.planMillis, 2500);
      // Everything that belongs to building is delayed by it.
      expect(animationOf('.ppc-hammer-on .ppc-pl'), contains(' 2.5s '));
      expect(animationOf('.ppc-hin'), contains(' 2.5s '));
      expect(animationOf('.ppc-barrow'), contains(' 2.5s '));
      expect(animationOf('.ppc-wa'), contains(' 2.5s '));
    });

    test('the planners are two frames switched by CSS steps', () {
      expect(animationOf('.ppc-fa'), contains('step-end'));
      expect(animationOf('.ppc-fb'), contains('step-end'));
      final html = ConstructionMarkup.siteHtml(urls);
      for (final name in [
        'planner_point_a',
        'planner_point_b',
        'planner_read_a',
        'planner_read_b',
      ]) {
        expect(html, contains('x/$name.webp'));
      }
    });

    test('the boxes are drawn, measured and swept inside the 2.5 s', () {
      final plans = ConstructionBoxes.plan(5, boxes(40));
      for (final p in plans) {
        expect(p.drawDelay, lessThan(ConstructionTimeline.planSeconds));
        // The ticks draw for 0.5 s after their box: still planning.
        expect(
          p.drawDelay + 0.25 + 0.5,
          lessThanOrEqualTo(ConstructionTimeline.planSeconds),
        );
        expect(p.breakDelay, greaterThanOrEqualTo(2.5));
      }
      // A dashed measure line sweeps once, and is hidden after.
      expect(rule('.ppc-measure'), contains('dashed'));
      expect(animationOf('.ppc-measure'), isNot(contains('infinite')));
      expect(animationOf('.ppc-measure'), contains('both'));
    });

    test('the boxes show at their real places while planning', () {
      // The default (and the start of the break) is no transform.
      expect(css, contains('@keyframes ppc-break{from{transform:none}'));
      final html = ConstructionMarkup.boxesHtml(1, boxes(3));
      expect(RegExp('class="ppc-box"').allMatches(html), hasLength(3));
      expect(html, contains('left:4px;top:4px;width:26px;height:16px;'));
    });
  });

  group('building: from 2.5 s until fixed, by delays only', () {
    test('the builder walks in, then hits every 0.6 s without end', () {
      expect(ConstructionTimeline.hammerStart, closeTo(3.6, 1e-9));
      expect(animationOf('.ppc-arm'), contains('.6s'));
      expect(animationOf('.ppc-arm'), contains('3.6s'));
      expect(animationOf('.ppc-arm'), contains('infinite'));
      expect(animationOf('.ppc-dip'), contains('3.6s infinite'));
      expect(animationOf('.ppc-ha'), contains('3.6s infinite'));
      expect(animationOf('.ppc-bwalk'), contains('4.1s infinite'));
    });

    test('the blueprint breaks at 2.5 s and a box is repaired at a hit', () {
      for (final n in [1, 4, 10, 11, 40]) {
        final plans = ConstructionBoxes.plan(9, boxes(n));
        var previous = 0.0;
        for (final (i, p) in plans.indexed) {
          expect(p.breakDelay, inInclusiveRange(2.5, 3.1));
          // The repair starts after the break ends.
          expect(p.repairDelay, greaterThan(p.breakDelay + 0.35));
          // And one after the other.
          expect(p.repairDelay, greaterThan(previous));
          previous = p.repairDelay;
          // It lands on a hit: 0.15 s into a 0.6 s swing.
          final hit = p.repairDelay + ConstructionTimeline.fixLead;
          final swings = (hit - ConstructionTimeline.hammerStart - 0.15) / 0.6;
          expect(
            (swings - swings.round()).abs(),
            lessThan(0.02),
            reason: 'box $i of $n lands on a hit',
          );
        }
      }
    });

    test('with many boxes a repair comes at every hit, else every second', () {
      expect(ConstructionTimeline.repairStep(10), closeTo(1.2, 1e-9));
      expect(ConstructionTimeline.repairStep(11), closeTo(0.6, 1e-9));
    });

    test('once all are repaired, a slow loop goes on: a few slip in turn', () {
      final plans = ConstructionBoxes.plan(3, boxes(20));
      final slips = [
        for (final p in plans)
          if (p.slipDelay != null) p,
      ];
      expect(
        slips.length,
        inInclusiveRange(1, ConstructionTimeline.maxSlippers),
      );
      final lastRepair = plans.last.repairDelay + ConstructionTimeline.fixLead;
      for (final p in slips) {
        expect(p.slipDelay, greaterThan(lastRepair));
      }
      // They slip one at a time: each at least 1.5 s after the one before.
      final delays = [for (final p in slips) p.slipDelay!]..sort();
      for (var i = 1; i < delays.length; i++) {
        expect(delays[i] - delays[i - 1], greaterThanOrEqualTo(1.5));
      }
      expect(animationOf('.ppc-slip.ppc-sl'), contains('ppc-slip 12s'));
      expect(animationOf('.ppc-slip.ppc-sl'), contains('infinite'));
      final html = ConstructionMarkup.boxesHtml(3, boxes(20));
      expect(RegExp('ppc-slip ppc-sl').allMatches(html).length, slips.length);
    });

    test('a few boxes still loop: even one box slips', () {
      final plans = ConstructionBoxes.plan(3, boxes(1));
      expect(plans.single.slipDelay, isNotNull);
      expect(ConstructionBoxes.plan(3, const []), isEmpty);
    });

    test('a broken box is a delayed transform, not a Dart timer', () {
      final html = ConstructionMarkup.boxesHtml(2, boxes(2));
      for (final v in ['--dx', '--dy', '--dr', '--bd', '--rd', '--pd']) {
        expect(html, contains('$v:'));
      }
      expect(animationOf('.ppc-box'), contains('var(--bd)'));
      expect(animationOf('.ppc-fix'), contains('var(--rd)'));
    });

    test('the planners leave when a builder comes; alone they stay', () {
      expect(
        css,
        contains('.ppc-hammer-on .ppc-pl{animation:ppc-pleave'),
        reason: 'only a site with a builder sends the planners away',
      );
    });
  });

  group('finishing, then the reveal, in one sequence', () {
    double seconds(String text) => double.parse(text.replaceAll('s', ''));

    /// The delay (the second time) of an animation shorthand.
    double delayOf(String selector) {
      final times = RegExp(r'(?<![\w.-])(\.?\d+(?:\.\d+)?)s(?![\w-])')
          .allMatches(animationOf(selector))
          .map((m) => seconds('${m.group(1)}s'));
      final list = times.map((t) => t).toList();
      return list.length > 1 ? list[1] : 0;
    }

    double durationOf(String selector) {
      final m = RegExp(r'(?<![\w.-])(\.?\d+(?:\.\d+)?)s')
          .firstMatch(animationOf(selector));
      return double.parse(
        m!.group(1)!.startsWith('.') ? '0${m.group(1)}' : m.group(1)!,
      );
    }

    test('the boxes snap into place at once, first', () {
      expect(animationOf('.ppc-reveal .ppc-box'), contains('ppc-snap .3s'));
      expect(animationOf('.ppc-reveal .ppc-fix'), 'none');
      expect(animationOf('.ppc-reveal .ppc-slip'), 'none');
      expect(delayOf('.ppc-reveal .ppc-box'), 0);
    });

    test(
      'the painter rolls across, the others stop, the done worker turns',
      () {
        expect(
          animationOf('.ppc-reveal .ppc-painter'),
          contains('ppc-prun .8s'),
        );
        expect(
          animationOf('.ppc-reveal .ppc-paint'),
          contains('ppc-paint .8s'),
        );
        expect(animationOf('.ppc-reveal .ppc-dip'), 'none');
        expect(animationOf('.ppc-reveal .ppc-arm'), 'none');
        expect(rule('.ppc-reveal .ppc-bwalk'), contains('paused'));
        expect(animationOf('.ppc-reveal .ppc-done'), contains('ppc-pop 1.2s'));
        // The done worker comes when the painter is nearly through.
        expect(delayOf('.ppc-reveal .ppc-done'), closeTo(0.7, 1e-9));
        // The painter only shows in the finish.
        expect(
          css,
          contains('.ppc-painter-on.ppc-reveal .ppc-w-painter{display:block}'),
        );
      },
    );

    test('then the tape snaps, the cover peels and the picture bounces', () {
      final fall = delayOf('.ppc-reveal .ppc-half-l');
      final peel = delayOf('.ppc-reveal .ppc-cover');
      final bounce = delayOf('.ppc-shotbox');
      expect(fall, closeTo(0.8, 1e-9), reason: 'after the finishing part');
      expect(peel, greaterThan(fall));
      expect(bounce, greaterThan(peel));
      expect(delayOf('.ppc-reveal .ppc-half-r'), fall);
      // The painter is done (0.8 s) before the tape falls.
      expect(
        fall,
        greaterThanOrEqualTo(durationOf('.ppc-reveal .ppc-painter')),
      );
    });

    test('about 2 s in all: the site is removed when the bounce ends', () {
      final bounceEnd = delayOf('.ppc-shotbox') + durationOf('.ppc-shotbox');
      expect(bounceEnd, closeTo(2.2, 1e-9));
      expect(
        ConstructionMarkup.revealMillis,
        inInclusiveRange(bounceEnd * 1000, bounceEnd * 1000 + 100),
      );
      expect(ConstructionMarkup.revealMillis, lessThanOrEqualTo(2500));
    });

    test('a finish before the builders walked in leaves them out', () {
      expect(
        css,
        contains(
          '.ppc-early .ppc-w-hammer,#${ConstructionMarkup.rootId} .ppc-early .ppc-w-barrow{display:none}',
        ),
      );
    });
  });

  group('the boxes', () {
    test('the seed depends only on the note id', () {
      expect(ConstructionBoxes.seedOf('abc'), ConstructionBoxes.seedOf('abc'));
      expect(
        ConstructionBoxes.seedOf('abc'),
        isNot(ConstructionBoxes.seedOf('abd')),
      );
      expect(ConstructionBoxes.seedOf(''), greaterThan(0));
      // Known values: the same on every platform (the browser test checks
      // the same ones).
      expect(ConstructionBoxes.seedOf('a'), 1014);
      expect(ConstructionBoxes.seedOf('note-1'), 802338714);
    });

    test('known numbers: the same in the VM and in the browser', () {
      final plans = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('note-1'),
        const [
          ConstructionBox(0, 0, 200, 100),
          ConstructionBox(10, 10, 40, 20),
          ConstructionBox(60, 10, 80, 30),
        ],
      );
      expect(
        [for (final p in plans) (p.dx, p.dy, p.degrees)],
        [(-23.87, -8.46, -3.66), (-3.99, -3.0, -3.46), (-3.72, -3.39, -3.06)],
      );
      expect([for (final p in plans) p.repairDelay], [4.62, 5.82, 7.02]);
      expect([for (final p in plans) p.slipDelay], [8.35, 12.35, 16.35]);
    });

    test('broken offsets are deterministic from the note id and the index', () {
      final list = boxes(12);
      final a = ConstructionBoxes.plan(ConstructionBoxes.seedOf('n1'), list);
      final b = ConstructionBoxes.plan(ConstructionBoxes.seedOf('n1'), list);
      final c = ConstructionBoxes.plan(ConstructionBoxes.seedOf('n2'), list);
      expect(
        [for (final p in a) (p.dx, p.dy, p.degrees)],
        [for (final p in b) (p.dx, p.dy, p.degrees)],
      );
      expect([
        for (final p in a) (p.dx, p.dy, p.degrees),
      ], isNot([for (final p in c) (p.dx, p.dy, p.degrees)]));
      // The index matters: the boxes do not all move the same.
      expect({for (final p in a) p.dx}.length, greaterThan(6));
      // A box's offset does not depend on the boxes after it.
      final shorter = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('n1'),
        list.take(5).toList(),
      );
      for (var i = 0; i < 5; i++) {
        expect(shorter[i].dx, a[i].dx);
        expect(shorter[i].degrees, a[i].degrees);
      }
    });

    test(
      'offsets are a few px up to about 12% of the size, and a few degrees',
      () {
        const big = ConstructionBox(0, 0, 300, 200);
        const small = ConstructionBox(0, 0, 20, 10);
        for (var seed = 1; seed < 200; seed++) {
          for (final box in [big, small]) {
            final p = ConstructionBoxes.plan(seed, [box]).single;
            expect(p.dx.abs(), inInclusiveRange(3, 3.001 + 0.12 * box.width));
            expect(p.dy.abs(), inInclusiveRange(3, 3.001 + 0.12 * box.height));
            expect(p.degrees.abs(), inInclusiveRange(1.5, 5.5));
          }
        }
        // Big boxes move far, small ones a few px.
        final p = ConstructionBoxes.plan(1, [big, small]);
        expect(p[1].dx.abs(), 3);
        expect(
          [
            for (var s = 1; s < 50; s++)
              ConstructionBoxes.plan(s, [big]).single.dx.abs(),
          ].reduce((a, b) => a > b ? a : b),
          greaterThan(20),
        );
      },
    );

    test(
      'a long thin box turns less, so its ends swing at most about 9 px',
      () {
        const line = ConstructionBox(0, 0, 500, 10);
        for (var seed = 1; seed < 100; seed++) {
          final p = ConstructionBoxes.plan(seed, [line]).single;
          expect(p.degrees.abs(), lessThanOrEqualTo(2.1));
          expect(
            250 * math.sin(p.degrees.abs() * math.pi / 180),
            lessThanOrEqualTo(9.2),
          );
        }
      },
    );

    test('some boxes overlap when broken', () {
      // A tight row: shifts of up to 12% make neighbours overlap.
      final row = [
        for (var i = 0; i < 8; i++) ConstructionBox(i * 40.0, 10, 40, 40),
      ];
      final plans = ConstructionBoxes.plan(7, row);
      var overlaps = 0;
      for (var i = 0; i < row.length; i++) {
        for (var j = i + 1; j < row.length; j++) {
          final a = row[i];
          final b = row[j];
          final ar = (
            a.left + plans[i].dx,
            a.top + plans[i].dy,
            a.left + plans[i].dx + a.width,
            a.top + plans[i].dy + a.height,
          );
          final br = (
            b.left + plans[j].dx,
            b.top + plans[j].dy,
            b.left + plans[j].dx + b.width,
            b.top + plans[j].dy + b.height,
          );
          if (ar.$1 < br.$3 &&
              br.$1 < ar.$3 &&
              ar.$2 < br.$4 &&
              br.$2 < ar.$4) {
            overlaps++;
          }
        }
      }
      expect(overlaps, greaterThan(0));
    });

    test('dimension ticks go on at most ten big boxes', () {
      final list = [
        for (var i = 0; i < 30; i++)
          ConstructionBox(0, i * 50.0, 100 + i * 2, 40),
        const ConstructionBox(0, 2000, 30, 20),
      ];
      final plans = ConstructionBoxes.plan(1, list);
      expect(plans.where((p) => p.dimX).length, lessThanOrEqualTo(10));
      expect(plans.where((p) => p.dimX).length, greaterThan(0));
      expect(plans.last.dimX, isFalse);
      expect(plans.last.dimY, isFalse);
      // Ticks are for boxes that fit them.
      for (final p in plans) {
        if (p.dimX) expect(p.box.width, greaterThanOrEqualTo(44));
        if (p.dimY) expect(p.box.height, greaterThanOrEqualTo(36));
      }
    });

    test('generic boxes come from the size, and stay inside the widget', () {
      for (final (w, h) in [
        (300.0, 60.0),
        (120.0, 40.0),
        (80.0, 30.0),
        (60.0, 24.0),
      ]) {
        final list = ConstructionBoxes.generic(w, h);
        expect(list, isNotEmpty, reason: '$w x $h');
        for (final b in list) {
          expect(b.width, greaterThanOrEqualTo(ConstructionBoxes.minSide));
          expect(b.height, greaterThanOrEqualTo(ConstructionBoxes.minSide));
          expect(b.left, greaterThanOrEqualTo(0));
          expect(b.top, greaterThanOrEqualTo(0));
          expect(b.left + b.width, lessThanOrEqualTo(w + 0.01));
          expect(b.top + b.height, lessThanOrEqualTo(h + 0.01));
        }
      }
      expect(ConstructionBoxes.generic(300, 60).length, greaterThan(2));
      expect(ConstructionBoxes.generic(5, 5), isEmpty);
    });

    test('at most 40 boxes are drawn', () {
      expect(ConstructionBoxes.maxBoxes, 40);
      final html = ConstructionMarkup.boxesHtml(1, boxes(40));
      expect(RegExp('class="ppc-box"').allMatches(html), hasLength(40));
    });
  });

  group('sizes', () {
    test('bare, small, medium and wide have the parts of their tier', () {
      final bare = ConstructionLayout.of(300, 20);
      expect(bare.classes, ['ppc-bare']);
      final tiny = ConstructionLayout.of(40, 80);
      expect(tiny.planners, 1);
      expect(tiny.hammer, isFalse);
      final small = ConstructionLayout.of(120, 60);
      expect(small.planners, 2);
      expect(small.hammer, isFalse);
      final medium = ConstructionLayout.of(230, 70);
      expect(medium.hammer, isTrue);
      expect(medium.barrow, isFalse);
      final wide = ConstructionLayout.of(900, 180);
      expect([wide.hammer, wide.barrow, wide.painter], everyElement(isTrue));
    });

    test('the CSS shows each part only for its class', () {
      expect(css, contains('.ppc-bare .ppc-bp'));
      expect(css, contains('.ppc-hammer-on .ppc-w-hammer'));
      expect(css, contains('.ppc-barrow-on .ppc-w-barrow'));
      expect(css, contains('.ppc-plan2 .ppc-pl-a{display:block}'));
    });
  });

  group('the manifest', () {
    const names = [
      'planner_read_a',
      'planner_read_b',
      'planner_point_a',
      'planner_point_b',
      'builder_a',
      'builder_b',
      'walk_a',
      'walk_b',
      'painter_a',
      'painter_b',
      'done',
      'cone',
    ];

    test('both sets have the names of the coloured set', () {
      for (final set in [
        ConstructionAssets.placeholders,
        ConstructionAssets.colouredSet,
      ]) {
        final have = {for (final a in set) a.name};
        expect(have, containsAll(names));
        expect(set.map((a) => a.name).toSet().length, set.length);
      }
      expect(ConstructionAssets.colouredSet, hasLength(names.length));
    });

    test('the coloured files are named like their assets, all coloured', () {
      for (final a in ConstructionAssets.colouredSet) {
        expect(a.file, a.name);
        expect(a.lineArt, isFalse, reason: a.name);
      }
    });

    test('the placeholders are the existing files, all line art', () {
      for (final a in ConstructionAssets.placeholders) {
        expect(a.lineArt, isTrue, reason: a.name);
        expect(
          File('assets/construction/${a.file}.webp').existsSync(),
          isTrue,
          reason: '${a.name} -> ${a.file}',
        );
      }
    });

    test('the set in use is the placeholders until the coloured one lands', () {
      expect(ConstructionAssets.coloured, isFalse);
      expect(ConstructionAssets.all, ConstructionAssets.placeholders);
      expect(ConstructionAssets.looseParts, isTrue);
      expect(ConstructionAssets.names, contains('hammer_arm'));
      expect(ConstructionAssets.of('cone').file, 'cone');
    });

    test('the sizes keep each character\'s design box', () {
      // Both frames of a character have one size, so it does not jump.
      for (final set in [
        ConstructionAssets.placeholders,
        ConstructionAssets.colouredSet,
      ]) {
        for (final base in [
          'planner_read',
          'planner_point',
          'builder',
          'walk',
          'painter',
        ]) {
          final a = set.firstWhere((x) => x.name == '${base}_a');
          final b = set.firstWhere((x) => x.name == '${base}_b');
          expect((a.width, a.height), (b.width, b.height), reason: base);
        }
      }
      final c = {for (final a in ConstructionAssets.colouredSet) a.name: a};
      expect((c['builder_a']!.width, c['builder_a']!.height), (95, 123));
      expect((c['walk_a']!.width, c['walk_a']!.height), (121, 112));
      expect((c['painter_a']!.width, c['painter_a']!.height), (114, 189));
      expect((c['done']!.width, c['done']!.height), (88, 146));
      expect((c['cone']!.width, c['cone']!.height), (65, 81));
      expect(
        (c['planner_read_a']!.width, c['planner_read_a']!.height),
        (74, 123),
      );
    });

    test('multiply is only for line art', () {
      // The CSS multiplies only the class of line art.
      expect(RegExp(r'mix-blend-mode:multiply').allMatches(css).length, 1);
      expect(css, contains('img.ppc-line{mix-blend-mode:multiply}'));
      // Every picture of a line-art asset has the class, others do not.
      final html = ConstructionMarkup.siteHtml(urls);
      for (final img in RegExp(r'<img [^>]*>').allMatches(html)) {
        final tag = img.group(0)!;
        final src = RegExp(r'src="x/([a-z_]+)\.webp"')
            .firstMatch(tag)!
            .group(1)!;
        final asset = ConstructionAssets.of(src);
        expect(tag.contains('ppc-line'), asset.lineArt, reason: src);
      }
      // A site built from the coloured set would carry no multiply class.
      expect(ConstructionAssets.colouredSet.where((a) => a.lineArt), isEmpty);
    });

    test('the pictures have inline sizes from the manifest', () {
      final html = ConstructionMarkup.siteHtml(urls);
      expect(html, contains('style="width:60px;height:123px"'));
      expect(html, contains('style="width:74px;height:123px"'));
      expect(html, contains('style="width:68px;height:68px"'));
    });
  });
}
