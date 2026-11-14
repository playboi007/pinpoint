import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/construction/construction_assets.dart';
import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';
import 'package:pinpoint/src/overlay/construction/construction_crew.dart';
import 'package:pinpoint/src/overlay/construction/construction_layout.dart';
import 'package:pinpoint/src/overlay/construction/construction_markup.dart';

/// The builder's aim at the biggest box, and the stacker with the
/// wheelbarrow: who repairs what, and when. All numbers, read as numbers.
void main() {
  // A card 700 x 190: a tall avatar at the left (the big container), a
  // title and lines of text above, buttons below.
  const card = [
    ConstructionBox(12, 12, 150, 166),
    ConstructionBox(178, 14, 260, 18),
    ConstructionBox(178, 44, 500, 10),
    ConstructionBox(178, 62, 480, 10),
    ConstructionBox(178, 80, 420, 10),
    ConstructionBox(178, 98, 380, 10),
    ConstructionBox(178, 138, 96, 36),
    ConstructionBox(284, 138, 96, 36),
    ConstructionBox(600, 20, 70, 24),
  ];
  final cardLayout = ConstructionLayout.of(700, 190, boxes: card);
  final urls = {
    for (final name in ConstructionMarkup.assetNames) name: 'x/$name.webp',
  };

  group('the builder aims at an edge of the big box', () {
    test('his hammer head lands on the edge, at his hammer height', () {
      expect(cardLayout.aimed, isTrue);
      // The big box's right edge, in the site (1 px of overscan).
      expect(cardLayout.hammerHeadX, closeTo(12 + 150 + 1, 0.01));
      // The head's height is beside the box, not above or under it.
      expect(cardLayout.hammerHeadY, greaterThan(12 + 1));
      expect(cardLayout.hammerHeadY, lessThan(12 + 166 + 1));
      // 0.987 of the picture's width: the head is at the strike frame's tip.
      expect(
        cardLayout.hammerLeft +
            ConstructionAssets.hammerHeadX * cardLayout.hammerBoxWidth,
        closeTo(cardLayout.hammerHeadX, 1e-9),
      );
    });

    test('he moves right of his usual place, and stays in the zone', () {
      final plain = ConstructionLayout.of(700, 190);
      expect(plain.aimed, isFalse);
      expect(cardLayout.hammerLeft, greaterThan(plain.hammerLeft));
      expect(
        cardLayout.hammerLeft + cardLayout.hammerBoxWidth,
        lessThanOrEqualTo(cardLayout.zoneEnd),
      );
      // The wheelbarrow keeps its lane, behind him.
      expect(
        cardLayout.barrowLeft,
        greaterThanOrEqualTo(cardLayout.hammerLeft + cardLayout.hammerBoxWidth),
      );
      expect(
        cardLayout.barrowRun,
        greaterThanOrEqualTo(ConstructionLayout.minRun),
      );
    });

    test('the place is a CSS variable', () {
      final m = RegExp(r'--hl:([\d.]+)px').firstMatch(cardLayout.variables);
      expect(m, isNotNull);
      expect(double.parse(m!.group(1)!), closeTo(cardLayout.hammerLeft, 0.001));
      expect(cardLayout.variables, contains('--hin:'));
    });

    test('with no box, no big box, or a box not at his height: as before', () {
      final plain = ConstructionLayout.of(700, 190);
      void usual(List<ConstructionBox> boxes, String why) {
        final l = ConstructionLayout.of(700, 190, boxes: boxes);
        expect(l.aimed, isFalse, reason: why);
        expect(l.hammerLeft, plain.hammerLeft, reason: why);
      }

      usual(const [], 'no box');
      // Smaller than a tenth of the widget.
      usual(const [ConstructionBox(12, 12, 100, 60)], 'no big box');
      // Big, but only in the top of the widget: his head is not beside it.
      usual(const [ConstructionBox(12, 4, 300, 50)], 'above his head');
      // Big and tall, but its edges are where he cannot stand: the left
      // edge is left of his zone, the right edge is behind the planners.
      usual(const [ConstructionBox(8, 8, 684, 174)], 'edges out of the zone');
    });

    test('the biggest box is the one he aims at', () {
      // Two boxes: the second is bigger and further right.
      final boxes = [
        const ConstructionBox(12, 100, 60, 60),
        const ConstructionBox(100, 12, 90, 166),
      ];
      final l = ConstructionLayout.of(700, 190, boxes: boxes);
      expect(l.aimed, isTrue);
      expect(
        l.hammerHeadX,
        anyOf(closeTo(100 + 1, 0.01), closeTo(190 + 1, 0.01)),
      );
    });

    test('small sites without a builder keep no aim', () {
      final l = ConstructionLayout.of(120, 60, boxes: card);
      expect(l.hammer, isFalse);
      expect(l.aimed, isFalse);
    });
  });

  group('the stacker: tiers', () {
    test('only where the wheelbarrow is, and only with a box up high', () {
      for (final (w, h) in [
        (40.0, 80.0),
        (120.0, 60.0),
        (230.0, 70.0),
        (360.0, 70.0),
        (420.0, 100.0),
        (520.0, 150.0),
        (700.0, 190.0),
        (900.0, 180.0),
        (900.0, 400.0),
      ]) {
        final boxes = ConstructionBoxes.generic(w, h);
        final l = ConstructionLayout.of(w, h, boxes: boxes);
        if (l.stacker) {
          expect(l.barrow, isTrue, reason: '${w}x$h');
          expect(l.classes, contains('ppc-stacker-on'));
          expect(l.stackerLeft, greaterThan(l.barrowLeft + l.barrowRun));
        } else {
          expect(l.classes, isNot(contains('ppc-stacker-on')));
        }
      }
      expect(cardLayout.stacker, isTrue);
      expect(ConstructionLayout.of(900, 180, boxes: card).stacker, isTrue);
      // Small sites have none.
      expect(ConstructionLayout.of(230, 70, boxes: card).stacker, isFalse);
      expect(ConstructionLayout.of(120, 60, boxes: card).stacker, isFalse);
      // A wide site without a box in the upper half: no stacker.
      final low = [const ConstructionBox(20, 120, 300, 40)];
      final noHigh = ConstructionLayout.of(700, 190, boxes: low);
      expect(noHigh.barrow, isTrue);
      expect(noHigh.stacker, isFalse);
      expect(ConstructionLayout.of(700, 190).stacker, isFalse);
    });

    test('he stands at the end of the lane, the wheelbarrow stops by him', () {
      final l = cardLayout;
      final barrowEnd = l.barrowLeft + l.barrowRun + l.barrowBoxWidth;
      expect(
        l.stackerLeft - barrowEnd,
        closeTo(ConstructionLayout.handoffGap, 1e-6),
      );
      expect(l.stackerLeft + l.stackerBoxWidth, lessThanOrEqualTo(l.zoneEnd));
      // The wheelbarrow walks a short way only: a trip of a few seconds.
      expect(l.barrowRun, lessThanOrEqualTo(ConstructionLayout.maxHandoffRun));
    });

    test('characters keep their proportions: scaled by height', () {
      final l = cardLayout;
      expect(l.hammerBoxHeight, closeTo(l.workerHeight, 1e-6));
      // His canvas is taller than he is (the block over his head, the
      // flames): the standing figure is as tall as the others.
      expect(
        l.stackerBoxHeight * ConstructionAssets.stackerFigure,
        closeTo(l.workerHeight, 1e-6),
      );
      expect(l.stackerBoxHeight, greaterThan(l.workerHeight));
      expect(l.hammerBoxWidth / l.hammerBoxHeight, closeTo(119 / 130.5, 1e-6));
      expect(l.barrowBoxWidth / l.barrowBoxHeight, closeTo(139.5 / 124, 1e-6));
      expect(l.stackerBoxWidth / l.stackerBoxHeight, closeTo(110 / 165, 1e-6));
    });
  });

  group('the stacker: who repairs what', () {
    final crew = ConstructionCrew.of(cardLayout, card)!;
    final plans = ConstructionBoxes.plan(7, card, crew: crew);

    test(
      'the boxes in the upper half are his, the low ones the builder\'s',
      () {
        for (final (i, p) in plans.indexed) {
          final high = card[i].top + card[i].height / 2 < 190 / 2;
          expect(p.stacker, high, reason: 'box $i');
          expect(crew.boxes.contains(i), high, reason: 'box $i');
        }
        // The big avatar's centre is exactly half: the builder's.
        expect(plans[0].stacker, isFalse);
        expect(plans[1].stacker, isTrue);
        expect(plans[6].stacker, isFalse);
      },
    );

    test('the builder keeps the old rhythm over his own boxes', () {
      final mine = [
        for (final (i, p) in plans.indexed)
          if (!p.stacker) i,
      ];
      for (final (k, i) in mine.indexed) {
        final hit = plans[i].repairDelay + ConstructionTimeline.fixLead;
        expect(
          hit,
          closeTo(ConstructionTimeline.hitOf(k, mine.length), 0.01),
          reason: 'box $i',
        );
      }
    });

    test('a stacker box is repaired when he places the block on it', () {
      for (final t in crew.trips) {
        final p = plans[t.box];
        expect(
          p.repairDelay + ConstructionTimeline.fixLead,
          closeTo(t.hitAt, 0.01),
        );
        // After the box broke, and after he came there.
        expect(p.repairDelay, greaterThan(p.breakDelay + 0.35));
        expect(t.hitAt, greaterThan(t.arriveAt));
        expect(t.hitAt, lessThan(t.liftAt));
      }
    });

    test(
      'the hand-off comes before each flight, then he places, then lands',
      () {
        for (final t in [...crew.trips, ...crew.loop]) {
          expect(t.throwAt, greaterThan(t.start));
          expect(t.catchAt, greaterThan(t.throwAt));
          expect(t.catchAt - t.throwAt, closeTo(0.35, 1e-9));
          expect(t.arriveAt, greaterThan(t.catchAt));
          expect(t.hitAt, greaterThan(t.arriveAt));
          expect(t.liftAt, greaterThan(t.hitAt));
          expect(t.landAt, greaterThan(t.liftAt));
          // The wheelbarrow worker turns after the block left him.
          expect(t.turnAt, greaterThan(t.catchAt - 0.01));
          // From the catch to the ground: about 2.2 to 3 s.
          expect(t.landAt - t.catchAt, inInclusiveRange(2.19, 3.0));
        }
      },
    );

    test('trips follow one another: on the ground before the next block', () {
      for (final list in [crew.trips, crew.loop]) {
        for (var i = 0; i + 1 < list.length; i++) {
          expect(list[i + 1].start, closeTo(list[i].end, 1e-9));
          expect(list[i + 1].throwAt, greaterThan(list[i].landAt));
        }
      }
      expect(crew.trips.first.start, ConstructionTimeline.barrowStart);
      expect(crew.buildEnd, closeTo(crew.trips.last.end, 1e-9));
      // The cycle is a few seconds, long enough for the walk there and back.
      for (final t in crew.trips) {
        expect(t.cycle, inInclusiveRange(2.9, 4.2));
        expect(t.cycle, greaterThanOrEqualTo(2 * t.walk + 0.45));
      }
    });

    test(
      'the slow loop goes on with both: his boxes slip, he repairs them',
      () {
        expect(crew.loop, hasLength(inInclusiveRange(1, 2)));
        expect(crew.loopLength, closeTo(crew.loop.last.end, 1e-9));
        for (final t in crew.loop) {
          expect(crew.boxes, contains(t.box));
        }
        final slipping = [
          for (final p in plans)
            if (p.stackerSlip != null) p,
        ];
        expect(slipping, hasLength(crew.loop.length));
        // The builder's slips start when everything is repaired.
        final builderSlips = [
          for (final p in plans)
            if (p.slipDelay != null) p,
        ];
        expect(builderSlips, isNotEmpty);
        final repairEnd = crew.buildEnd;
        for (final p in builderSlips) {
          expect(p.slipDelay, greaterThan(repairEnd));
          expect(p.stacker, isFalse);
        }
        // At most six boxes slip all in all.
        expect(slipping.length + builderSlips.length, lessThanOrEqualTo(6));
      },
    );

    test('it is the same for the same note, every time', () {
      final a = ConstructionCrew.of(cardLayout, card)!;
      final b = ConstructionCrew.of(cardLayout, card)!;
      expect(
        a.css('k1', ConstructionMarkup.rootId),
        b.css('k1', ConstructionMarkup.rootId),
      );
      expect(
        [for (final t in a.trips) (t.box, t.start, t.hitAt, t.dx, t.dy)],
        [for (final t in b.trips) (t.box, t.start, t.hitAt, t.dx, t.dy)],
      );
      final p1 = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('n1'),
        card,
        crew: a,
      );
      final p2 = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('n1'),
        card,
        crew: b,
      );
      expect(
        [for (final p in p1) (p.dx, p.dy, p.repairDelay, p.slipDelay)],
        [for (final p in p2) (p.dx, p.dy, p.repairDelay, p.slipDelay)],
      );
      // Another note breaks the boxes another way.
      final p3 = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('n2'),
        card,
        crew: a,
      );
      expect([for (final p in p3) p.dx], isNot([for (final p in p1) p.dx]));
    });

    test('no stacker boxes in a plan without a crew: the builder does all', () {
      final p = ConstructionBoxes.plan(7, card);
      expect(p.where((x) => x.stacker), isEmpty);
      expect(p.where((x) => x.stackerSlip != null), isEmpty);
    });

    test('there is no crew for a layout without the stacker', () {
      expect(
        ConstructionCrew.of(ConstructionLayout.of(230, 70, boxes: card), card),
        isNull,
      );
      expect(
        ConstructionMarkup.siteCss(
          ConstructionLayout.of(230, 70, boxes: card),
          card,
          'k1',
        ),
        isEmpty,
      );
    });
  });

  group('the stacker: where he is', () {
    final crew = ConstructionCrew.of(cardLayout, card)!;

    test('he drops in from above after planning, then waits at the spot', () {
      final above = crew.offsetAt(0);
      expect(above.$1, 0);
      expect(above.$2, lessThan(-cardLayout.groundY));
      expect(crew.offsetAt(2.5).$2, closeTo(above.$2, 1e-9));
      expect(crew.offsetAt(3.3), (0.0, 0.0));
      expect(crew.offsetAt(crew.trips.first.throwAt), (0.0, 0.0));
    });

    test('he is at the box when he places the block, on the ground after', () {
      for (final t in crew.trips) {
        final at = crew.offsetAt(t.hitAt);
        expect(at.$1, closeTo(t.dx, 1e-6));
        expect(at.$2, closeTo(t.dy, 1e-6));
        expect(t.dy, lessThan(0), reason: 'he flies up');
        expect(crew.offsetAt(t.landAt + 0.01), (0.0, 0.0));
      }
    });

    test('he rises straight up from the spot, and cruises over the lane', () {
      final t = crew.trips.first;
      final early = crew.offsetAt(t.catchAt + 0.15 * t.flight);
      expect(early.$1, 0);
      expect(early.$2, lessThan(0));
      final mid = crew.offsetAt(t.catchAt + 0.7 * t.flight);
      expect(mid.$1, lessThan(0));
    });

    test('the loop repeats: the same place a loop later', () {
      final t = crew.loop.first;
      final a = crew.offsetAt(crew.buildEnd + t.hitAt);
      final b = crew.offsetAt(crew.buildEnd + crew.loopLength + t.hitAt);
      expect(a.$1, closeTo(b.$1, 1e-6));
      expect(a.$2, closeTo(b.$2, 1e-6));
      expect(a.$2, lessThan(0));
    });

    // The layouts to check: the card, a short wide field, a big card.
    final cases = <(String, double, double, List<ConstructionBox>)>[
      ('card', 700, 190, card),
      (
        'field',
        420,
        100,
        const [
          ConstructionBox(12, 8, 90, 10),
          ConstructionBox(12, 26, 396, 40),
          ConstructionBox(22, 40, 160, 12),
          ConstructionBox(372, 36, 24, 20),
          ConstructionBox(12, 74, 200, 8),
        ],
      ),
      ('generic wide', 900, 180, ConstructionBoxes.generic(900, 180)),
      ('generic big', 900, 400, ConstructionBoxes.generic(900, 400)),
      (
        'mid card',
        520,
        150,
        const [
          ConstructionBox(10, 10, 80, 130),
          ConstructionBox(104, 12, 200, 16),
          ConstructionBox(104, 38, 380, 10),
          ConstructionBox(104, 54, 340, 10),
          ConstructionBox(104, 100, 90, 32),
        ],
      ),
    ];

    test('he stays in the site and under the tape, in every trip', () {
      var checked = 0;
      for (final (name, w, h, boxes) in cases) {
        final l = ConstructionLayout.of(w, h, boxes: boxes);
        final c = ConstructionCrew.of(l, boxes);
        if (c == null) continue;
        checked++;
        final tapeBottom = l.tapeTop + l.tapeHeight;
        final spotTop = l.groundY - l.stackerBoxHeight;
        final bh = l.stackerBoxHeight;
        final bw = l.stackerBoxWidth;
        // Every place of his flight, not only where he hovers.
        final places = <(double, double)>[
          for (final t in [...c.trips, ...c.loop]) ...[
            (t.dx, t.dy),
            for (var k = 0; k <= 20; k++)
              c.offsetAt(
                (c.trips.contains(t) ? 0 : c.buildEnd) +
                    t.catchAt +
                    (t.landAt - t.catchAt) * k / 20,
              ),
          ],
        ];
        for (final (dx, dy) in places) {
          final top = spotTop + dy;
          final left = l.stackerLeft + dx;
          // The block over his head is under the tape, unless he is on the
          // ground (a site too short to fly in).
          if (dy < -0.01) {
            expect(
              top + ConstructionAssets.stackerContentTop * bh,
              greaterThanOrEqualTo(tapeBottom),
              reason: '$name: under the tape',
            );
          }
          // His content is inside the site, left and right.
          expect(
            left + ConstructionAssets.stackerContentLeft * bw,
            greaterThanOrEqualTo(-0.01),
            reason: '$name: left edge',
          );
          expect(
            left + ConstructionAssets.stackerContentRight * bw,
            lessThanOrEqualTo(l.width + 0.01),
            reason: '$name: right edge',
          );
          // And never under the ground.
          expect(top, lessThanOrEqualTo(spotTop + 0.01), reason: name);
        }
      }
      expect(checked, greaterThanOrEqualTo(3));
    });

    test('at the box the block of the place pose is on its top edge', () {
      final l = cardLayout;
      final bh = l.stackerBoxHeight;
      final bw = l.stackerBoxWidth;
      final spotTop = l.groundY - bh;
      for (final t in crew.trips) {
        final b = card[t.box];
        final top = spotTop + t.dy;
        final blockBottom =
            top + ConstructionAssets.stackerPlaceBlockBottom * bh;
        final blockX =
            l.stackerLeft + t.dx + ConstructionAssets.stackerPlaceBlockX * bw;
        // On the top edge, unless the tape holds him lower.
        expect(blockBottom, greaterThanOrEqualTo(b.top + 1 - 0.01));
        if (blockBottom > b.top + 1 + 0.01) {
          expect(
            top + ConstructionAssets.stackerContentTop * bh,
            closeTo(l.tapeTop + l.tapeHeight + 1, 0.01),
          );
        }
        // Centred on the box (or held inside the site).
        expect(blockX, closeTo(b.left + 1 + b.width / 2, 0.01));
      }
    });

    test('he lands on his spot, and starts each trip from it', () {
      for (final t in [...crew.trips]) {
        expect(crew.offsetAt(t.landAt), (0.0, 0.0));
        expect(crew.offsetAt(t.catchAt), (0.0, 0.0));
        expect(crew.offsetAt(t.throwAt), (0.0, 0.0));
      }
    });
  });

  group('the stacker: keyframes', () {
    final crew = ConstructionCrew.of(cardLayout, card)!;
    final css = crew.css('k3', ConstructionMarkup.rootId);
    final sel = '#${ConstructionMarkup.rootId} .ppc-k3';

    test('one keyframes per track, for the building and for the loop', () {
      for (final track in [
        'sf',
        'bx',
        'bf',
        'ta',
        'sst',
        'sfy',
        'spl',
        'sfl',
        'scb',
        'thr',
      ]) {
        expect(css, contains('@keyframes ppc-k3-$track{'), reason: track);
        expect(css, contains('@keyframes ppc-k3-$track-l{'), reason: track);
      }
      for (var k = 0; k < crew.loop.length; k++) {
        expect(css, contains('@keyframes ppc-k3-ss$k{'));
      }
    });

    test('each element plays the building keyframes, then the loop', () {
      final b = crew.buildEnd
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '');
      for (final target in [
        '.ppc-stk',
        '.ppc-bwalk',
        '.ppc-flip',
        '.ppc-tb',
        '.ppc-sp-st',
        '.ppc-sfly',
        '.ppc-sp-pl',
        '.ppc-sfl',
        '.ppc-scb',
        '.ppc-thrown',
      ]) {
        final m = RegExp(
          '${RegExp.escape(sel)} ${RegExp.escape(target)}\\{animation:([^}]*)\\}',
        ).firstMatch(css);
        expect(m, isNotNull, reason: target);
        final value = m!.group(1)!;
        expect(value, contains('${b}s linear 0s both'));
        expect(value, contains('infinite'));
        expect(value, contains('-l '));
      }
    });

    test('the keyframes are valid steps: percentages rise from 0 to 100', () {
      for (final m in RegExp(r'@keyframes ([\w-]+)\{(.*)\}').allMatches(css)) {
        final body = m.group(2)!;
        final ps = [
          for (final p in RegExp(r'(?:^|\})([\d.]+)%\{').allMatches(body))
            double.parse(p.group(1)!),
        ];
        expect(ps, isNotEmpty, reason: m.group(1));
        expect(ps.first, 0, reason: m.group(1));
        expect(ps.last, 100, reason: m.group(1));
        for (var i = 1; i < ps.length; i++) {
          expect(ps[i], greaterThanOrEqualTo(ps[i - 1]), reason: m.group(1));
        }
      }
    });

    test('the block shows only while it flies, the poses take turns', () {
      final thr = RegExp('@keyframes ppc-k3-thr\\{([^@]*)\\}\\n')
          .firstMatch(css)!
          .group(1)!;
      expect(thr, contains('opacity:1'));
      expect(thr, contains('step-end'));
      final first = crew.trips.first;
      final p = (first.throwAt / crew.buildEnd * 100);
      expect(
        thr,
        contains(
          '${p.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '')}%{opacity:1',
        ),
      );
    });

    test('on reveal they stop: the barrow is paused, the rest has none', () {
      expect(
        css,
        contains('$sel.ppc-reveal .ppc-bwalk{animation-play-state:paused}'),
      );
      expect(
        css,
        contains('$sel.ppc-reveal .ppc-flip{animation-play-state:paused}'),
      );
      expect(css, contains('$sel.ppc-reveal .ppc-stk{animation:none}'));
      expect(css, contains('$sel.ppc-reveal .ppc-thrown{animation:none}'));
      expect(
        css,
        contains('$sel.ppc-reveal .ppc-slip.ppc-ss0{animation:none}'),
      );
    });

    test('drafting rules: no blur, no radius, no multiply', () {
      expect(css, isNot(contains('blur')));
      expect(css, isNot(contains('border-radius')));
      expect(css, isNot(contains('box-shadow')));
      expect(css, isNot(contains('mix-blend-mode')));
      expect(css, isNot(contains('NaN')));
      expect(css, isNot(contains('Infinity')));
    });

    test('the markup marks the slipping boxes of the stacker', () {
      final plans = ConstructionBoxes.plan(1, card, crew: crew);
      final html = ConstructionMarkup.boxesHtml(1, card, crew: crew);
      for (final p in plans) {
        if (p.stackerSlip != null) {
          expect(html, contains('ppc-slip ppc-ss ppc-ss${p.stackerSlip}'));
        }
      }
      // The builder's own slips keep their class.
      expect(html, contains('ppc-slip ppc-sl"'));
    });

    test('the site html has the stacker and the block, all in place', () {
      final html = ConstructionMarkup.siteHtml(
        urls,
        id: 'n1',
        boxes: card,
        layout: cardLayout,
      );
      for (final cls in [
        'ppc-w-stack',
        'ppc-lnd',
        'ppc-stk',
        'ppc-sk',
        'ppc-sp-st',
        'ppc-sfly',
        'ppc-sfa',
        'ppc-sfb',
        'ppc-sp-pl',
        'ppc-thrown',
        'ppc-tb',
      ]) {
        expect(html, contains(cls), reason: cls);
      }
      // His own art, and the block's picture.
      expect(html, contains('x/stacker_stand.webp'));
      expect(html, contains('x/block.webp'));
      // The CSS flames and block are for the placeholders only.
      expect(html, isNot(contains('class="ppc-sfl"')));
      expect(html, isNot(contains('class="ppc-scb"')));
      // On the canvas: 110 x 165, in the middle at the bottom.
      expect(html, contains('width:110px;height:165px;margin-left:-55px'));
    });

    test('the stage class and the landing variables', () {
      expect(
        ConstructionMarkup.siteClass(cardLayout, key: 'k3'),
        contains('ppc-k3 '),
      );
      expect(
        ConstructionMarkup.siteClass(cardLayout),
        isNot(contains('ppc-k')),
      );
      expect(
        ConstructionMarkup.siteClass(cardLayout),
        contains('ppc-stacker-on'),
      );
      final style = ConstructionMarkup.siteStyle(
        cardLayout,
        left: 1,
        top: 2,
        landing: (-12.5, -40),
      );
      expect(style, contains('--ax:-12.5px;--ay:-40px'));
      expect(
        ConstructionMarkup.siteStyle(cardLayout, left: 1, top: 2),
        isNot(contains('--ax')),
      );
      expect(
        ConstructionMarkup.css,
        contains(
          '@keyframes ppc-land{from{transform:translate(var(--ax,0px),var(--ay,0px))}',
        ),
      );
      expect(
        ConstructionMarkup.css,
        contains('.ppc-reveal .ppc-lnd{animation:ppc-land'),
      );
    });
  });
}
