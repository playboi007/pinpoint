@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/construction/construction_assets.dart';
import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';
import 'package:pinpoint/src/overlay/construction/construction_crew.dart';
import 'package:pinpoint/src/overlay/construction/construction_layout.dart';
import 'package:pinpoint/src/overlay/construction/construction_markup.dart';
import 'package:pinpoint/src/overlay/construction/construction_stage.dart';
import 'package:pinpoint/src/overlay/construction/construction_stage_web.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// The construction stage in Chrome, on the real DOM:
/// `flutter test --platform chrome test/overlay/construction/web`.
///
/// Nothing here runs a Flutter frame: the stage only writes elements. The
/// look and the keyframes are checked by eye in the preview page.
void main() {
  late ConstructionStage stage;

  /// A blueprint: a header, a button and a line, relative to the widget.
  const sample = <ConstructionBox>[
    ConstructionBox(8, 6, 120, 20),
    ConstructionBox(8, 34, 60, 24),
    ConstructionBox(80, 38, 100, 8),
  ];

  JSObject document() => globalContext['document']! as JSObject;

  JSObject? byId(String id) =>
      document().callMethod<JSObject?>('getElementById'.toJS, id.toJS);

  List<JSObject> all(String selector, [JSObject? within]) {
    final list = (within ?? document()).callMethod<JSObject>(
      'querySelectorAll'.toJS,
      selector.toJS,
    );
    final length = (list['length']! as JSNumber).toDartInt;
    return [
      for (var i = 0; i < length; i++)
        list.callMethod<JSObject>('item'.toJS, i.toJS),
    ];
  }

  JSObject? first(String selector, [JSObject? within]) => (within ?? document())
      .callMethod<JSObject?>('querySelector'.toJS, selector.toJS);

  String text(JSObject el, String prop) => (el[prop]! as JSString).toDart;

  JSObject root() => byId(ConstructionMarkup.rootId)!;

  List<JSObject> sitesNow() => all('.ppc-site', root());

  String styleOf(JSObject el, String prop) => (el['style']! as JSObject)
      .callMethod<JSString>('getPropertyValue'.toJS, prop.toJS)
      .toDart;

  double px(JSObject el, String prop) =>
      double.parse(styleOf(el, prop).replaceAll('px', ''));

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// Where the Flutter view starts, as the stage reads it.
  Offset origin() {
    final host = first('flutter-view') ?? first('flt-glass-pane');
    if (host == null) return Offset.zero;
    final box = host.callMethod<JSObject>('getBoundingClientRect'.toJS);
    return Offset(
      (box['left']! as JSNumber).toDartDouble,
      (box['top']! as JSNumber).toDartDouble,
    );
  }

  setUp(() => stage = createConstructionStage());
  tearDown(() => stage.dispose());

  group('the root', () {
    test('is made once, fixed, over the page, and takes no pointer events', () {
      expect(stage.available, isTrue);
      expect(all('#${ConstructionMarkup.rootId}'), hasLength(1));
      expect(all('#${ConstructionMarkup.styleId}'), hasLength(1));
      final css =
          (first('#${ConstructionMarkup.styleId}')!['textContent']! as JSString)
              .toDart;
      expect(css, ConstructionMarkup.css);
      expect(css, isNot(contains('blur')));
      // The page's own computed style.
      final computed = globalContext.callMethod<JSObject>(
        'getComputedStyle'.toJS,
        root(),
      );
      String prop(String name) => computed
          .callMethod<JSString>('getPropertyValue'.toJS, name.toJS)
          .toDart;
      expect(prop('position'), 'fixed');
      expect(prop('pointer-events'), 'none');
      expect(int.parse(prop('z-index')), greaterThan(1000000));
    });

    test('a stale root from a hot restart is removed at the start', () {
      stage.dispose();
      final stale = document().callMethod<JSObject>(
        'createElement'.toJS,
        'div'.toJS,
      );
      stale['id'] = ConstructionMarkup.rootId.toJS;
      stale['innerHTML'] = '<i class="stale"></i>'.toJS;
      (document()['body']! as JSObject).callMethod<JSAny?>(
        'appendChild'.toJS,
        stale,
      );
      final staleStyle = document().callMethod<JSObject>(
        'createElement'.toJS,
        'style'.toJS,
      );
      staleStyle['id'] = ConstructionMarkup.styleId.toJS;
      (document()['head']! as JSObject).callMethod<JSAny?>(
        'appendChild'.toJS,
        staleStyle,
      );

      stage = createConstructionStage();
      expect(all('#${ConstructionMarkup.rootId}'), hasLength(1));
      expect(all('.stale'), isEmpty);
      expect(all('#${ConstructionMarkup.styleId}'), hasLength(1));
    });

    test('a second stage replaces the first: still one root', () {
      final second = createConstructionStage();
      expect(all('#${ConstructionMarkup.rootId}'), hasLength(1));
      second.dispose();
    });

    test('dispose takes the root and the style away', () {
      stage.add('a', const Rect.fromLTWH(10, 10, 100, 50), sample);
      stage.dispose();
      expect(byId(ConstructionMarkup.rootId), isNull);
      expect(byId(ConstructionMarkup.styleId), isNull);
    });

    test('the palette becomes CSS custom properties', () {
      final colors = ConstructionColors.of(PinPointTokens.ember);
      stage.setColors(colors);
      expect(styleOf(root(), '--ppc-paper'), colors.paper);
      expect(styleOf(root(), '--ppc-ink'), colors.ink);
      expect(styleOf(root(), '--ppc-accent'), colors.accent);
      expect(styleOf(root(), '--ppc-rule'), colors.rule);
      expect(styleOf(root(), '--ppc-shadow'), colors.shadow);
      expect(styleOf(root(), '--ppc-hatch'), colors.hatch);
      final cobalt = ConstructionColors.of(PinPointTokens.cobalt);
      stage.setColors(cobalt);
      expect(styleOf(root(), '--ppc-paper'), cobalt.paper);
      expect(cobalt.paper, isNot(colors.paper));
    });
  });

  group('a site', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);

    test('is put over the widget\'s rect, plus 1 px on each side', () {
      stage.add('a', rect, sample);
      final site = sitesNow().single;
      final o = origin();
      expect(px(site, 'left'), closeTo(o.dx + 39, 0.01));
      expect(px(site, 'top'), closeTo(o.dy + 59, 0.01));
      expect(px(site, 'width'), 362);
      expect(px(site, 'height'), 72);
      // And the page agrees.
      final box = site.callMethod<JSObject>('getBoundingClientRect'.toJS);
      expect((box['width']! as JSNumber).toDartDouble, closeTo(362, 0.5));
      expect((box['height']! as JSNumber).toDartDouble, closeTo(72, 0.5));
      expect((box['left']! as JSNumber).toDartDouble, closeTo(o.dx + 39, 0.5));
    });

    test('has the tape, the cover and the parts, with the asset URLs', () {
      stage.add('a', rect, sample);
      final site = sitesNow().single;
      expect(all('.ppc-cover', site), hasLength(1));
      expect(all('.ppc-label', site), hasLength(2), reason: 'two halves');
      expect(
        text(all('.ppc-label', site).first, 'textContent'),
        'UNDER PROGRESS',
      );
      final sources = {for (final img in all('img', site)) text(img, 'src')};
      for (final name in ConstructionMarkup.assetNames) {
        final file = ConstructionAssets.of(name).file;
        final path = ConstructionMarkup.assetPath(file);
        expect(
          sources.any((src) => src.contains(path)),
          isTrue,
          reason: '$name is at $path',
        );
      }
      // The URL is made by the asset manager, under the app's base.
      for (final name in ConstructionMarkup.assetNames) {
        expect(
          sources,
          contains(
            endsWith(
              'assets/packages/pinpoint/assets/construction/'
              '${ConstructionAssets.of(name).file}.webp',
            ),
          ),
        );
      }
    });

    test('has the classes for its size', () {
      stage.add('wide', const Rect.fromLTWH(0, 0, 900, 180), sample);
      stage.add('tiny', const Rect.fromLTWH(0, 300, 220, 18), sample);
      final byIdAttr = {
        for (final site in sitesNow()) text(site, 'className'): site,
      };
      expect(
        byIdAttr.keys.any(
          (c) =>
              c.contains('ppc-plan2') &&
              c.contains('ppc-hammer-on') &&
              c.contains('ppc-cones') &&
              c.contains('ppc-barrow-on') &&
              c.contains('ppc-painter-on'),
        ),
        isTrue,
        reason: '${byIdAttr.keys}',
      );
      expect(byIdAttr.keys.any((c) => c.contains('ppc-bare')), isTrue);
    });

    test('moves, and changes layout when its size changes', () {
      stage.add('a', rect, sample);
      stage.move('a', const Rect.fromLTWH(40, 10, 360, 70));
      var site = sitesNow().single;
      expect(px(site, 'top'), closeTo(origin().dy + 9, 0.01));
      stage.move('a', const Rect.fromLTWH(40, 10, 360, 20));
      site = sitesNow().single;
      expect(px(site, 'height'), 22);
      expect(text(site, 'className'), contains('ppc-bare'));
      expect(sitesNow(), hasLength(1));
    });

    test('keeps the tape in front of the widget, both halves', () {
      stage.add('a', rect, sample);
      final halves = all('.ppc-half', sitesNow().single);
      expect(halves, hasLength(2));
    });

    test('is not clickable: no pointer events on any part', () {
      stage.add('a', rect, sample);
      final site = sitesNow().single;
      final computed = globalContext.callMethod<JSObject>(
        'getComputedStyle'.toJS,
        first('.ppc-cover', site)!,
      );
      expect(
        computed
            .callMethod<JSString>(
              'getPropertyValue'.toJS,
              'pointer-events'.toJS,
            )
            .toDart,
        'none',
      );
    });

    test('is removed with a fade, or at once', () async {
      stage.add('a', rect, sample);
      stage.add('b', const Rect.fromLTWH(0, 200, 100, 40), sample);
      stage.remove('a');
      // Fading: still there, with the class.
      expect(
        sitesNow().where((s) => text(s, 'className').contains('ppc-out')),
        hasLength(1),
      );
      stage.remove('b', fade: false);
      expect(sitesNow(), hasLength(1));
      await wait(ConstructionMarkup.fadeMillis + 200);
      expect(sitesNow(), isEmpty);
    });

    test('adding an id again replaces the site', () {
      stage.add('a', rect, sample);
      stage.add('a', const Rect.fromLTWH(0, 0, 100, 40), sample);
      expect(sitesNow(), hasLength(1));
      expect(px(sitesNow().single, 'width'), 102);
    });
  });

  group('the reveal', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

    test('marks the site and adds the picture of the widget', () {
      stage.add('a', rect, sample);
      stage.reveal('a', png);
      final site = sitesNow().single;
      expect(text(site, 'className'), contains('ppc-reveal'));
      final shot = first('.ppc-shotbox img', site)!;
      expect(text(shot, 'src'), startsWith('data:image/png;base64,iVBORw'));
      // It does not move any more while it plays.
      stage.move('a', const Rect.fromLTWH(0, 0, 10, 10));
      expect(px(sitesNow().single, 'width'), 362);
    });

    test('without a picture there is no bounce', () {
      stage.add('a', rect, sample);
      stage.reveal('a', null);
      final site = sitesNow().single;
      expect(text(site, 'className'), contains('ppc-reveal'));
      expect(first('.ppc-shotbox', site), isNull);
    });

    test('the finish plays CSS animations: they are computed on the parts', () {
      stage.add('a', rect, sample);
      stage.reveal('a', png);
      final site = sitesNow().single;
      String animation(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-name'.toJS)
          .toDart;
      expect(animation('.ppc-cover'), 'ppc-peel');
      expect(animation('.ppc-half-l'), 'ppc-fall-l');
      expect(animation('.ppc-half-r'), 'ppc-fall-r');
      expect(animation('.ppc-shotbox'), 'ppc-bounce');
      expect(animation('.ppc-done'), 'ppc-pop');
      expect(animation('.ppc-w-hammer'), 'ppc-hop');
      // The finishing part: the boxes snap, the painter rolls across.
      expect(animation('.ppc-box'), 'ppc-snap');
      expect(animation('.ppc-fix'), 'none');
      expect(animation('.ppc-painter'), 'ppc-prun');
      expect(animation('.ppc-paint'), 'ppc-paint');
    });

    test(
      'the finish comes in this order: boxes, painter, tape, peel, bounce',
      () {
        stage.add('a', rect, sample);
        stage.reveal('a', png);
        final site = sitesNow().single;
        double delay(String selector) {
          final value = globalContext
              .callMethod<JSObject>(
                'getComputedStyle'.toJS,
                first(selector, site)!,
              )
              .callMethod<JSString>(
                'getPropertyValue'.toJS,
                'animation-delay'.toJS,
              )
              .toDart;
          return double.parse(value.split(',').first.replaceAll('s', ''));
        }

        expect(delay('.ppc-box'), 0);
        expect(delay('.ppc-painter'), 0);
        expect(delay('.ppc-done'), closeTo(0.7, 0.001));
        expect(delay('.ppc-half-l'), closeTo(0.8, 0.001));
        expect(delay('.ppc-cover'), closeTo(1.2, 0.001));
        expect(delay('.ppc-shotbox'), closeTo(1.5, 0.001));
      },
    );

    test('while at work, the parts animate in CSS', () {
      stage.add('a', const Rect.fromLTWH(40, 60, 900, 180), sample);
      final site = sitesNow().single;
      String animation(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-name'.toJS)
          .toDart;
      expect(animation('.ppc-ha'), 'ppc-ha');
      expect(animation('.ppc-hin'), 'ppc-hin');
      expect(animation('.ppc-barrow'), 'ppc-bin');
      expect(animation('.ppc-dust'), 'ppc-dust');
      // The stacker's site has its own keyframes for him and the barrow.
      expect(animation('.ppc-bwalk'), startsWith('ppc-k'));
      expect(animation('.ppc-bwalk'), endsWith('-bx, ppc-k1-bx-l'));
      expect(animation('.ppc-stk'), 'ppc-k1-sf, ppc-k1-sf-l');
      expect(animation('.ppc-thrown'), 'ppc-k1-thr, ppc-k1-thr-l');
      expect(animation('.ppc-sbob'), 'ppc-sbob');
      expect(animation('.ppc-box'), 'ppc-break');
      expect(animation('.ppc-fix'), 'ppc-fix');
      expect(animation('.ppc-measure'), 'ppc-sweep');
      expect(animation('.ppc-pl-b'), 'ppc-pleave');
    });

    test('the phases are CSS delays: 2.5 s, then 3.6 s, then 4.1 s', () {
      stage.add('a', const Rect.fromLTWH(40, 60, 900, 180), sample);
      final site = sitesNow().single;
      String delay(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-delay'.toJS)
          .toDart;
      // Building starts after planning: the planners leave, the builder
      // walks in, the boxes break.
      expect(delay('.ppc-pl-b'), '2.5s');
      expect(delay('.ppc-hin'), '2.5s');
      expect(delay('.ppc-barrow'), '2.5s');
      expect(delay('.ppc-box'), '2.5s');
      // The hammer starts when the builder is in; the wheelbarrow walks
      // its lane when it is in.
      expect(delay('.ppc-ha'), '3.6s');
      // The wheelbarrow's loop (no stacker here: only a box in the lower
      // half) starts when it is in.
      stage.add('low', const Rect.fromLTWH(40, 300, 900, 180), const [
        ConstructionBox(20, 110, 300, 40),
      ]);
      final low = sitesNow().last;
      String delayOf(String selector, JSObject within) => globalContext
          .callMethod<JSObject>(
            'getComputedStyle'.toJS,
            first(selector, within)!,
          )
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-delay'.toJS)
          .toDart;
      expect(delayOf('.ppc-bwalk', low), '4.1s');
      // With the stacker, his keyframes start at once and loop when the
      // building trips end.
      final crew = ConstructionCrew.of(
        ConstructionLayout.of(900, 180, boxes: sample),
        sample,
      )!;
      final delays = [
        for (final d in delay('.ppc-bwalk').split(','))
          double.parse(d.trim().replaceAll('s', '')),
      ];
      expect(delays.first, 0);
      expect(delays.last, closeTo(crew.buildEnd, 0.001));
      // Planning draws the outlines at once, then ticks and the measure.
      expect(delay('.ppc-measure'), '0.25s');
      String animationCount(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>(
            'getPropertyValue'.toJS,
            'animation-iteration-count'.toJS,
          )
          .toDart;
      // The loops never end.
      expect(animationCount('.ppc-ha'), 'infinite');
      expect(animationCount('.ppc-bwalk'), '1, infinite');
      expect(animationCount('.ppc-measure'), '1');
    });
  });

  group('the stacker and the block', () {
    const wide = Rect.fromLTWH(40, 60, 700, 190);
    const card = [
      ConstructionBox(12, 12, 150, 166),
      ConstructionBox(178, 14, 260, 18),
      ConstructionBox(178, 44, 500, 10),
      ConstructionBox(178, 138, 96, 36),
    ];

    String computed(JSObject el, String prop) => globalContext
        .callMethod<JSObject>('getComputedStyle'.toJS, el)
        .callMethod<JSString>('getPropertyValue'.toJS, prop.toJS)
        .toDart;

    List<JSObject> siteStyles() =>
        all('style[id^="pinpoint-construction-style-"]');

    test('a site with room has the stacker, his keyframes in a style of '
        'its own', () {
      stage.add('a', wide, card);
      final site = sitesNow().single;
      expect(text(site, 'className'), contains('ppc-stacker-on'));
      expect(text(site, 'className'), contains('ppc-k1'));
      expect(computed(first('.ppc-w-stack', site)!, 'display'), 'block');
      final styles = siteStyles();
      expect(styles, hasLength(1));
      final css = text(styles.single, 'textContent');
      expect(css, contains('@keyframes ppc-k1-sf{'));
      expect(css, isNot(contains('blur')));
      final layout = ConstructionLayout.of(700, 190, boxes: card);
      expect(css, ConstructionMarkup.siteCss(layout, card, 'k1'));
    });

    test('the pieces are there: his poses, and the block that is thrown', () {
      stage.add('a', wide, card);
      final site = sitesNow().single;
      for (final sel in [
        '.ppc-sp-st',
        '.ppc-sfa',
        '.ppc-sfb',
        '.ppc-sp-pl',
        '.ppc-thrown img',
      ]) {
        expect(first(sel, site), isNotNull, reason: sel);
      }
      // His art has the flames and the carried block in it: no CSS parts.
      expect(first('.ppc-fl', site), isNull);
      expect(first('.ppc-scb', site), isNull);
      // At rest only the standing pose shows; the rest waits for its time.
      expect(computed(first('.ppc-sp-st', site)!, 'opacity'), '1');
      for (final sel in ['.ppc-sfly', '.ppc-sp-pl']) {
        expect(computed(first(sel, site)!, 'opacity'), '0', reason: sel);
      }
      expect(computed(first('.ppc-thrown', site)!, 'opacity'), '0');
      // The poses fill his canvas, which the layout scales.
      final layout = ConstructionLayout.of(700, 190, boxes: card);
      final canvas = first(
        '.ppc-lnd',
        site,
      )!.callMethod<JSObject>('getBoundingClientRect'.toJS);
      expect(
        (canvas['height']! as JSNumber).toDartDouble,
        closeTo(layout.stackerBoxHeight, 0.5),
      );
      expect(
        (canvas['width']! as JSNumber).toDartDouble,
        closeTo(layout.stackerBoxWidth, 0.5),
      );
      // The thrown block is as big as the one in his hands.
      final thrown = first(
        '.ppc-thrown',
        site,
      )!.callMethod<JSObject>('getBoundingClientRect'.toJS);
      expect(
        (thrown['width']! as JSNumber).toDartDouble,
        closeTo(ConstructionAssets.blockSize * layout.stackerScale, 0.5),
      );
    });

    test('a small site has no stacker and no style of its own', () {
      stage.add('a', const Rect.fromLTWH(40, 60, 230, 70), card);
      final site = sitesNow().single;
      expect(text(site, 'className'), isNot(contains('ppc-stacker-on')));
      expect(computed(first('.ppc-w-stack', site)!, 'display'), 'none');
      expect(siteStyles(), isEmpty);
    });

    test('each site has its own key; up to three, no clash', () {
      stage.add('a', wide, card);
      stage.add('b', const Rect.fromLTWH(40, 300, 700, 190), card);
      stage.add('c', const Rect.fromLTWH(40, 540, 700, 190), card);
      final ids = [for (final s in siteStyles()) text(s, 'id')];
      expect(ids, hasLength(3));
      expect(ids.toSet(), hasLength(3));
      final keys = [
        for (final s in sitesNow())
          RegExp(r'ppc-k\d+').firstMatch(text(s, 'className'))!.group(0),
      ];
      expect(keys.toSet(), hasLength(3));
    });

    test('the style goes with the site: removal, fade, dispose', () async {
      stage.add('a', wide, card);
      stage.add('b', const Rect.fromLTWH(40, 300, 700, 190), card);
      expect(siteStyles(), hasLength(2));
      stage.remove('a', fade: false);
      expect(siteStyles(), hasLength(1));
      stage.remove('b');
      // Still there while it fades, gone after.
      expect(siteStyles(), hasLength(1));
      await wait(ConstructionMarkup.fadeMillis + 200);
      expect(siteStyles(), isEmpty);
      stage.add('c', wide, card);
      stage.dispose();
      expect(siteStyles(), isEmpty);
    });

    test('a stale style from a hot restart is removed at the start', () {
      stage.dispose();
      final stale = document().callMethod<JSObject>(
        'createElement'.toJS,
        'style'.toJS,
      );
      stale['id'] = '${ConstructionMarkup.styleId}-k9'.toJS;
      (document()['head']! as JSObject).callMethod<JSAny?>(
        'appendChild'.toJS,
        stale,
      );
      stage = createConstructionStage();
      expect(siteStyles(), isEmpty);
      expect(all('#${ConstructionMarkup.styleId}'), hasLength(1));
    });

    test('the builder stands where the Dart layout aims him', () {
      stage.add('a', wide, card);
      final site = sitesNow().single;
      final layout = ConstructionLayout.of(700, 190, boxes: card);
      expect(layout.aimed, isTrue);
      expect(
        double.parse(styleOf(site, '--hl').replaceAll('px', '')),
        closeTo(layout.hammerLeft, 0.001),
      );
      // In the page, the picture's box is where the layout says.
      final hammer = first('.ppc-hammer', site)!;
      final box = hammer.callMethod<JSObject>('getBoundingClientRect'.toJS);
      final siteBox = site.callMethod<JSObject>('getBoundingClientRect'.toJS);
      double v(JSObject r, String k) => (r[k]! as JSNumber).toDartDouble;
      // Before building starts the builder is off to the left: check the
      // custom property of the CSS instead.
      expect(computed(hammer, 'left'), styleOf(site, '--hl'));
      expect(v(box, 'width'), closeTo(layout.hammerBoxWidth, 0.5));
      expect(v(siteBox, 'width'), closeTo(layout.width, 0.5));
    });

    test('the finish lands the stacker from where he is', () {
      stage.add('a', wide, card);
      stage.reveal('a', null);
      final site = sitesNow().single;
      expect(text(site, 'className'), contains(ConstructionMarkup.revealClass));
      // Planning: he is above the site, so he lands from above.
      expect(styleOf(site, '--ax'), isNotEmpty);
      expect(styleOf(site, '--ay'), endsWith('px'));
      expect(computed(first('.ppc-lnd', site)!, 'animation-name'), 'ppc-land');
      // His flight stops; the wheelbarrow is paused.
      expect(computed(first('.ppc-stk', site)!, 'animation-name'), 'none');
      expect(
        computed(first('.ppc-bwalk', site)!, 'animation-play-state'),
        'paused',
      );
      // A site without the stacker sets no landing.
      stage.add('b', const Rect.fromLTWH(40, 300, 230, 70), card);
      stage.reveal('b', null);
      expect(styleOf(sitesNow().last, '--ax'), isEmpty);
    });

    test('reduced motion: no part of the stacker animates', () {
      stage.setReducedMotion(true);
      stage.add('a', wide, card);
      final site = sitesNow().single;
      for (final sel in [
        '.ppc-stk',
        '.ppc-sp-st',
        '.ppc-sfly',
        '.ppc-thrown',
        '.ppc-tb',
        '.ppc-bwalk',
        '.ppc-flip',
        '.ppc-slip',
        '.ppc-sbob',
      ]) {
        expect(
          computed(first(sel, site)!, 'animation-name'),
          'none',
          reason: sel,
        );
      }
    });
  });

  group('the blueprint', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);

    test('has one outlined box for each, in its real place', () {
      stage.add('note-1', rect, sample);
      final site = sitesNow().single;
      final boxes = all('.ppc-box', site);
      expect(boxes, hasLength(sample.length));
      final o = origin();
      for (final (i, box) in boxes.indexed) {
        final r = box.callMethod<JSObject>('getBoundingClientRect'.toJS);
        double v(String k) => (r[k]! as JSNumber).toDartDouble;
        final want = sample[i];
        // Before building starts, a box is not moved.
        expect(v('left'), closeTo(o.dx + rect.left + want.left, 0.6));
        expect(v('top'), closeTo(o.dy + rect.top + want.top, 0.6));
        expect(v('width'), closeTo(want.width, 0.6));
        expect(v('height'), closeTo(want.height, 0.6));
      }
      // Thin ink outlines: 1 px.
      final line = globalContext.callMethod<JSObject>(
        'getComputedStyle'.toJS,
        first('.ppc-slip', site)!,
      );
      expect(
        line
            .callMethod<JSString>(
              'getPropertyValue'.toJS,
              'border-top-width'.toJS,
            )
            .toDart,
        '1px',
      );
    });

    test('is broken from the note id: the CSS variables match the plan', () {
      stage.add('note-1', rect, sample);
      final plans = ConstructionBoxes.plan(
        ConstructionBoxes.seedOf('note-1'),
        sample,
      );
      for (final (i, box) in all('.ppc-box', sitesNow().single).indexed) {
        expect(styleOf(box, '--dx'), '${plans[i].dx}px');
        expect(styleOf(box, '--dy'), '${plans[i].dy}px');
        expect(styleOf(box, '--dr'), '${plans[i].degrees}deg');
        expect(styleOf(box, '--bd'), '${plans[i].breakDelay}s');
      }
      // Another note breaks it another way.
      stage.add('note-2', const Rect.fromLTWH(40, 200, 360, 70), sample);
      final other = all('.ppc-box', sitesNow().last);
      expect(
        [for (final b in other) styleOf(b, '--dx')],
        isNot([
          for (final b in all('.ppc-box', sitesNow().first)) styleOf(b, '--dx'),
        ]),
      );
    });

    test('numbers are the same in the browser as in the VM', () {
      expect(ConstructionBoxes.seedOf('a'), 1014);
      expect(ConstructionBoxes.seedOf('note-1'), 802338714);
      final plans =
          ConstructionBoxes.plan(ConstructionBoxes.seedOf('note-1'), const [
            ConstructionBox(0, 0, 200, 100),
            ConstructionBox(10, 10, 40, 20),
            ConstructionBox(60, 10, 80, 30),
          ]);
      expect(
        [for (final p in plans) (p.dx, p.dy, p.degrees)],
        [(-23.87, -8.46, -3.66), (-3.99, -3.0, -3.46), (-3.72, -3.39, -3.06)],
      );
      expect([for (final p in plans) p.repairDelay], [4.62, 5.82, 7.02]);
    });

    test('has dimension ticks on the big boxes and a measure line', () {
      stage.add('a', rect, sample);
      final site = sitesNow().single;
      expect(all('.ppc-dx', site), hasLength(3));
      expect(all('.ppc-dy', site), isEmpty, reason: 'no box is 36 px tall');
      expect(all('.ppc-measure', site), hasLength(1));
      final measure = globalContext.callMethod<JSObject>(
        'getComputedStyle'.toJS,
        first('.ppc-measure', site)!,
      );
      expect(
        measure
            .callMethod<JSString>(
              'getPropertyValue'.toJS,
              'border-left-style'.toJS,
            )
            .toDart,
        'dashed',
      );
    });

    test('has the phase classes for its size, and the planners leave only '
        'for a builder', () {
      stage.add('wide', const Rect.fromLTWH(0, 0, 900, 180), sample);
      stage.add('small', const Rect.fromLTWH(0, 300, 120, 60), sample);
      final classes = [for (final s in sitesNow()) text(s, 'className')];
      expect(
        classes[0],
        allOf(contains('ppc-plan2'), contains('ppc-hammer-on')),
      );
      expect(classes[1], contains('ppc-plan2'));
      expect(classes[1], isNot(contains('ppc-hammer-on')));
      final small = sitesNow()[1];
      final name = globalContext
          .callMethod<JSObject>(
            'getComputedStyle'.toJS,
            first('.ppc-pl-b', small)!,
          )
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-name'.toJS)
          .toDart;
      expect(name, 'none', reason: 'planners alone stay');
    });

    test('shows only the planners at first: the builder is off the left', () {
      stage.add('a', const Rect.fromLTWH(40, 60, 900, 180), sample);
      final site = sitesNow().single;
      // The builder starts left of the site (walks in at 2.5 s), clipped
      // by its group.
      final siteBox = site.callMethod<JSObject>('getBoundingClientRect'.toJS);
      final hin = first(
        '.ppc-hin',
        site,
      )!.callMethod<JSObject>('getBoundingClientRect'.toJS);
      expect(
        (hin['right']! as JSNumber).toDartDouble,
        lessThanOrEqualTo((siteBox['left']! as JSNumber).toDartDouble + 1),
        reason: 'off the left edge before it walks in',
      );
    });

    test('the art is coloured: nothing is multiplied', () {
      stage.add('a', rect, sample);
      stage.reveal('a', Uint8List.fromList([0x89, 0x50]));
      final site = sitesNow().single;
      String blend(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>('getPropertyValue'.toJS, 'mix-blend-mode'.toJS)
          .toDart;
      expect(blend('.ppc-body'), 'normal');
      expect(blend('.ppc-cone'), 'normal');
      expect(blend('.ppc-shotbox img'), 'normal');
    });

    test(
      'a finish before 2.5 s leaves the builders out; later it does not',
      () async {
        stage.add('early', const Rect.fromLTWH(40, 60, 900, 180), sample);
        stage.reveal('early', null);
        expect(
          text(sitesNow().single, 'className'),
          contains(ConstructionMarkup.earlyClass),
        );
        final display = globalContext
            .callMethod<JSObject>(
              'getComputedStyle'.toJS,
              first('.ppc-w-hammer', sitesNow().single)!,
            )
            .callMethod<JSString>('getPropertyValue'.toJS, 'display'.toJS)
            .toDart;
        expect(display, 'none');

        stage.add('late', const Rect.fromLTWH(40, 300, 900, 180), sample);
        await wait(ConstructionMarkup.planMillis + 150);
        stage.reveal('late', null);
        final late = sitesNow().last;
        expect(
          text(late, 'className'),
          contains(ConstructionMarkup.revealClass),
        );
        expect(
          text(late, 'className'),
          isNot(contains(ConstructionMarkup.earlyClass)),
        );
      },
    );
  });

  group('reduced motion', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);

    test('puts a class on the root, and no part animates', () {
      stage.setReducedMotion(true);
      expect(text(root(), 'className'), ConstructionMarkup.reducedClass);
      stage.add('a', rect, sample);
      final site = sitesNow().single;
      for (final selector in [
        '.ppc-barrow',
        '.ppc-bwalk',
        '.ppc-hin',
        '.ppc-ha',
        '.ppc-stk',
        '.ppc-sbob',
        '.ppc-thrown',
        '.ppc-dust',
        '.ppc-box',
        '.ppc-fix',
        '.ppc-slip',
        '.ppc-measure',
        '.ppc-pl-b',
        '.ppc-dx',
      ]) {
        final name = globalContext
            .callMethod<JSObject>(
              'getComputedStyle'.toJS,
              first(selector, site)!,
            )
            .callMethod<JSString>(
              'getPropertyValue'.toJS,
              'animation-name'.toJS,
            )
            .toDart;
        expect(name, 'none', reason: selector);
      }
      stage.setReducedMotion(false);
      expect(text(root(), 'className'), '');
    });

    test('a reveal just removes the site', () {
      stage.setReducedMotion(true);
      stage.add('a', rect, sample);
      stage.reveal('a', Uint8List.fromList([1]));
      expect(sitesNow(), isEmpty);
    });

    test('a removal is at once', () {
      stage.setReducedMotion(true);
      stage.add('a', rect, sample);
      stage.remove('a');
      expect(sitesNow(), isEmpty);
    });
  });

  test('the layout in the page matches the layout in Dart', () {
    // The same class text and variables as the Dart side builds.
    stage.add('a', const Rect.fromLTWH(10, 10, 360, 70), sample);
    final layout = ConstructionLayout.of(360, 70, boxes: sample);
    final site = sitesNow().single;
    expect(styleOf(site, '--sh'), isNotEmpty);
    expect(
      double.parse(styleOf(site, '--sh')),
      closeTo(layout.hammerScale, 0.001),
    );
    expect(styleOf(site, '--run'), endsWith('px'));
  });
}
