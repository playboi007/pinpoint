import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'dart:ui_web' as ui_web;

import '../../theme/pinpoint_tokens.dart';
import 'construction_assets.dart';
import 'construction_boxes.dart';
import 'construction_crew.dart';
import 'construction_layout.dart';
import 'construction_markup.dart';
import 'construction_stage.dart';

/// The page's own DOM, over the Flutter canvas. No `package:web`: only the
/// few members used here are declared.
ConstructionStage createConstructionStage() => _WebStage();

extension type _Style._(JSObject _) implements JSObject {
  external void setProperty(String name, String value);
  external set cssText(String value);
}

extension type _Box._(JSObject _) implements JSObject {
  external double get left;
  external double get top;
}

extension type _Node._(JSObject _) implements JSObject {
  external void remove();
  external void appendChild(_Node child);
  external void insertAdjacentHTML(String where, String html);
  external set id(String value);
  external set className(String value);
  external set innerHTML(String value);
  external set textContent(String? value);
  external _Style get style;
  external _Box getBoundingClientRect();
}

extension type _Doc._(JSObject _) implements JSObject {
  external _Node createElement(String tag);
  external _Node? getElementById(String id);
  external _Node? querySelector(String selector);
  external _Node? get body;
  external _Node? get head;
}

/// One site in the page.
class _Site {
  _Site(this.element, this.layout, this.boxes, this.key, this.crew);

  final _Node element;

  /// The blueprint, the class `ppc-$key` of the site's own keyframes and
  /// the stacker's schedule: fixed when the site goes up.
  final List<ConstructionBox> boxes;
  final String key;
  final ConstructionCrew? crew;

  /// The `<style>` element with the site's own keyframes, if it has any.
  _Node? styleElement;

  /// Where the stacker is when the finish begins (from his spot).
  (double, double)? landing;

  /// Time since the site went up: a finish before the builders walked in
  /// leaves them out.
  final Stopwatch age = Stopwatch()..start();
  ConstructionLayout layout;
  Rect rect = Rect.zero;
  String klass = '';
  String style = '';
  bool revealing = false;
  bool early = false;
}

class _WebStage implements ConstructionStage {
  _WebStage() {
    try {
      _start();
    } catch (_) {
      _root = null;
    }
  }

  late final _Doc _doc = _Doc._(globalContext['document']! as JSObject);
  _Node? _root;
  _Node? _style;
  int _keys = 0;
  bool _reduced = false;
  final Map<String, _Site> _sites = <String, _Site>{};
  final Set<Timer> _fades = <Timer>{};
  late final Map<String, String> _urls = {
    for (final name in ConstructionMarkup.assetNames)
      name: _assetUrl(ConstructionAssets.of(name).file),
  };

  /// The `<style>` elements of single sites (see [ConstructionMarkup.siteCss]).
  static const String _siteStyles =
      'style[id^="${ConstructionMarkup.styleId}-"]';

  static String _assetUrl(String file) {
    final path = ConstructionMarkup.assetPath(file);
    try {
      return ui_web.assetManager.getAssetUrl(path);
    } catch (_) {
      return 'assets/$path';
    }
  }

  void _start() {
    // A hot restart leaves the old page's elements behind: take them away
    // first.
    _doc.getElementById(ConstructionMarkup.rootId)?.remove();
    _doc.getElementById(ConstructionMarkup.styleId)?.remove();
    for (
      var old = _doc.querySelector(_siteStyles);
      old != null;
      old = _doc.querySelector(_siteStyles)
    ) {
      old.remove();
    }
    final body = _doc.body;
    final head = _doc.head ?? body;
    if (body == null || head == null) return;
    final style = _doc.createElement('style')
      ..id = ConstructionMarkup.styleId
      ..textContent = ConstructionMarkup.css;
    head.appendChild(style);
    final root = _doc.createElement('div')..id = ConstructionMarkup.rootId;
    body.appendChild(root);
    _style = style;
    _root = root;
    setColors(ConstructionColors.of(PinPointTokens.redline));
  }

  @override
  bool get available => _root != null;

  /// The system asks for reduced motion in CSS too: a page whose Flutter
  /// view did not pass it on still gets no motion.
  bool get _motionReduced => _reduced || _prefersReducedMotion();

  static bool _prefersReducedMotion() {
    try {
      final query = globalContext.callMethod<JSObject>(
        'matchMedia'.toJS,
        '(prefers-reduced-motion: reduce)'.toJS,
      );
      return (query['matches']! as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  void setColors(ConstructionColors colors) {
    final style = _root?.style;
    if (style == null) return;
    style
      ..setProperty('--ppc-paper', colors.paper)
      ..setProperty('--ppc-ink', colors.ink)
      ..setProperty('--ppc-accent', colors.accent)
      ..setProperty('--ppc-rule', colors.rule)
      ..setProperty('--ppc-shadow', colors.shadow)
      ..setProperty('--ppc-hatch', colors.hatch);
  }

  @override
  void setReducedMotion(bool reduced) {
    _reduced = reduced;
    _root?.className = reduced ? ConstructionMarkup.reducedClass : '';
  }

  /// Where the Flutter view starts in the page.
  (double, double) _origin() {
    try {
      final host =
          _doc.querySelector('flutter-view') ??
          _doc.querySelector('flt-glass-pane');
      if (host != null) {
        final box = host.getBoundingClientRect();
        return (box.left, box.top);
      }
    } catch (_) {}
    return (0, 0);
  }

  void _place(_Site site, Rect rect) {
    site.rect = rect;
    final layout = ConstructionLayout.of(
      rect.width,
      rect.height,
      boxes: site.boxes,
    );
    site.layout = layout;
    final (ox, oy) = _origin();
    final klass = ConstructionMarkup.siteClass(
      layout,
      revealing: site.revealing,
      early: site.early,
      key: site.key,
    );
    final style = ConstructionMarkup.siteStyle(
      layout,
      left: ox + rect.left - ConstructionLayout.overscan,
      top: oy + rect.top - ConstructionLayout.overscan,
      landing: site.revealing ? site.landing : null,
    );
    if (klass != site.klass) {
      site.klass = klass;
      site.element.className = klass;
    }
    if (style != site.style) {
      site.style = style;
      site.element.style.cssText = style;
    }
  }

  @override
  void add(String id, Rect rect, List<ConstructionBox> boxes) {
    final root = _root;
    if (root == null) return;
    remove(id, fade: false);
    final layout = ConstructionLayout.of(rect.width, rect.height, boxes: boxes);
    final element = _doc.createElement('div')
      ..innerHTML = ConstructionMarkup.siteHtml(
        _urls,
        id: id,
        boxes: boxes,
        layout: layout,
      );
    final key = 'k${++_keys}';
    final site = _Site(
      element,
      layout,
      boxes,
      key,
      ConstructionCrew.of(layout, boxes),
    );
    _sites[id] = site;
    // The site's own keyframes (the stacker's flights), when it has any.
    final css = ConstructionMarkup.siteCss(layout, boxes, key);
    final head = _doc.head ?? _doc.body;
    if (css.isNotEmpty && head != null) {
      final style = _doc.createElement('style')
        ..id = '${ConstructionMarkup.styleId}-$key'
        ..textContent = css;
      head.appendChild(style);
      site.styleElement = style;
    }
    _place(site, rect);
    root.appendChild(element);
  }

  @override
  void move(String id, Rect rect) {
    final site = _sites[id];
    if (site == null || site.revealing) return;
    _place(site, rect);
  }

  @override
  void reveal(String id, Uint8List? png) {
    final site = _sites[id];
    if (site == null || site.revealing) return;
    if (_motionReduced) {
      remove(id, fade: false);
      return;
    }
    site.revealing = true;
    site.early = site.age.elapsedMilliseconds < ConstructionMarkup.planMillis;
    // The stacker lands from where he is now.
    site.landing = site.crew?.offsetAt(site.age.elapsedMilliseconds / 1000);
    _place(site, site.rect);
    if (png != null) {
      site.element.insertAdjacentHTML(
        'beforeend',
        ConstructionMarkup.shotHtml(
          'data:image/png;base64,${base64Encode(png)}',
        ),
      );
    }
  }

  @override
  void remove(String id, {bool fade = true}) {
    final site = _sites.remove(id);
    if (site == null) return;
    if (!fade || _motionReduced) {
      site.element.remove();
      site.styleElement?.remove();
      return;
    }
    site.element.className = '${site.klass} ${ConstructionMarkup.outClass}';
    late final Timer timer;
    timer = Timer(
      const Duration(milliseconds: ConstructionMarkup.fadeMillis + 40),
      () {
        _fades.remove(timer);
        site.element.remove();
        site.styleElement?.remove();
      },
    );
    _fades.add(timer);
  }

  @override
  void dispose() {
    for (final timer in _fades) {
      timer.cancel();
    }
    _fades.clear();
    for (final site in _sites.values) {
      site.styleElement?.remove();
    }
    _sites.clear();
    _root?.remove();
    _style?.remove();
    _root = null;
    _style = null;
  }
}
