@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
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
      stage.add('a', const Rect.fromLTWH(10, 10, 100, 50));
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
      stage.add('a', rect);
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
      stage.add('a', rect);
      final site = sitesNow().single;
      expect(all('.ppc-cover', site), hasLength(1));
      expect(all('.ppc-label', site), hasLength(2), reason: 'two halves');
      expect(
        text(all('.ppc-label', site).first, 'textContent'),
        'UNDER PROGRESS',
      );
      final sources = {for (final img in all('img', site)) text(img, 'src')};
      for (final name in ConstructionMarkup.assetNames) {
        final path = ConstructionMarkup.assetPath(name);
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
            endsWith('assets/packages/pinpoint/assets/construction/$name.webp'),
          ),
        );
      }
    });

    test('has the classes for its size', () {
      stage.add('wide', const Rect.fromLTWH(0, 0, 900, 180));
      stage.add('tiny', const Rect.fromLTWH(0, 300, 220, 18));
      final byIdAttr = {
        for (final site in sitesNow()) text(site, 'className'): site,
      };
      expect(
        byIdAttr.keys.any(
          (c) =>
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
      stage.add('a', rect);
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
      stage.add('a', rect);
      final halves = all('.ppc-half', sitesNow().single);
      expect(halves, hasLength(2));
    });

    test('is not clickable: no pointer events on any part', () {
      stage.add('a', rect);
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
      stage.add('a', rect);
      stage.add('b', const Rect.fromLTWH(0, 200, 100, 40));
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
      stage.add('a', rect);
      stage.add('a', const Rect.fromLTWH(0, 0, 100, 40));
      expect(sitesNow(), hasLength(1));
      expect(px(sitesNow().single, 'width'), 102);
    });
  });

  group('the reveal', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

    test('marks the site and adds the picture of the widget', () {
      stage.add('a', rect);
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
      stage.add('a', rect);
      stage.reveal('a', null);
      final site = sitesNow().single;
      expect(text(site, 'className'), contains('ppc-reveal'));
      expect(first('.ppc-shotbox', site), isNull);
    });

    test('the finish plays CSS animations: they are computed on the parts', () {
      stage.add('a', rect);
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
    });

    test('while at work, the parts animate in CSS', () {
      stage.add('a', const Rect.fromLTWH(40, 60, 900, 180));
      final site = sitesNow().single;
      String animation(String selector) => globalContext
          .callMethod<JSObject>('getComputedStyle'.toJS, first(selector, site)!)
          .callMethod<JSString>('getPropertyValue'.toJS, 'animation-name'.toJS)
          .toDart;
      expect(animation('.ppc-arm'), 'ppc-swing');
      expect(animation('.ppc-barrow'), 'ppc-walk');
      expect(animation('.ppc-roller'), 'ppc-roll');
      expect(animation('.ppc-dust'), 'ppc-dust');
    });
  });

  group('reduced motion', () {
    const rect = Rect.fromLTWH(40, 60, 360, 70);

    test('puts a class on the root, and no part animates', () {
      stage.setReducedMotion(true);
      expect(text(root(), 'className'), ConstructionMarkup.reducedClass);
      stage.add('a', rect);
      final site = sitesNow().single;
      for (final selector in [
        '.ppc-arm',
        '.ppc-barrow',
        '.ppc-roller',
        '.ppc-dust',
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
      stage.add('a', rect);
      stage.reveal('a', Uint8List.fromList([1]));
      expect(sitesNow(), isEmpty);
    });

    test('a removal is at once', () {
      stage.setReducedMotion(true);
      stage.add('a', rect);
      stage.remove('a');
      expect(sitesNow(), isEmpty);
    });
  });

  test('the layout in the page matches the layout in Dart', () {
    // The same class text and variables as the Dart side builds.
    stage.add('a', const Rect.fromLTWH(10, 10, 360, 70));
    final layout = ConstructionLayout.of(360, 70);
    final site = sitesNow().single;
    expect(styleOf(site, '--sh'), isNotEmpty);
    expect(
      double.parse(styleOf(site, '--sh')),
      closeTo(layout.hammerScale, 0.001),
    );
    expect(styleOf(site, '--run'), endsWith('px'));
  });
}
