import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../model/annotation.dart';
import '../model/source_location.dart';
import '../search/pick_result.dart';
import 'subtree_outline.dart';

/// Builds the [Annotation] for a selection: everything an agent needs to
/// act on the comment without seeing the app.
///
/// Each payload field has its own collector. One that throws records the
/// field's name in [Annotation.errors] and leaves the field empty, so the
/// note is still sent.
///
/// Nothing here subscribes an app element to an inherited widget
/// (engineering rule 3): reads go through `getInheritedWidgetOfExactType`
/// and `findAncestorWidgetOfExactType`, never `.of(element)`. The route
/// name is the one exception; see [_routeOf].
class ContextCollector {
  ContextCollector({
    DateTime Function()? clock,
    math.Random? random,
    Uri? Function()? pageUrl,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? math.Random(),
       _pageUrl = pageUrl ?? _browserUrl;

  final DateTime Function() _clock;
  final math.Random _random;
  final Uri? Function() _pageUrl;

  static Uri? _browserUrl() => kIsWeb ? Uri.base : null;

  /// Local widgets above the target in [Annotation.ancestors].
  static const int maxAncestors = 12;

  /// Type names in [Annotation.frameworkChain].
  static const int maxFrameworkChain = 40;

  /// Children named in [SiblingsInfo.children].
  static const int maxSiblings = 12;

  /// Longest widget label in the siblings and the subtree.
  static const int maxLabel = 80;

  /// Longest key, URL or route.
  static const int maxShortText = 300;

  /// Field names whose collector throws, to test the error path.
  @visibleForTesting
  static Set<String> debugFailFields = const <String>{};

  /// How long the last [collect] took. Logged in debug when over a frame
  /// (engineering rule 4).
  Duration? lastElapsed;

  /// The note for [selection], with [comment] and [intent].
  ///
  /// [context] is Pinpoint's own: the page is described from there, so the
  /// app's elements are not touched for it.
  Annotation collect(
    PickResult selection,
    String comment,
    AnnotationIntent intent, {
    required BuildContext context,
  }) {
    final watch = Stopwatch()..start();
    final errors = <String>[];
    T? field<T extends Object>(String name, T? Function() read) {
      try {
        if (debugFailFields.contains(name)) {
          throw StateError('pinpoint: $name failed on purpose');
        }
        return read();
      } catch (_) {
        errors.add(name);
        return null;
      }
    }

    final paths = selection.chain.resolver.paths;
    final now = _clock();
    final note = Annotation(
      id: annotationId(now, _random),
      createdAt: now,
      intent: intent,
      comment: comment,
      app: _app(paths),
      page: field('page', () => _page(context, selection)) ?? const PageInfo(),
      target:
          field('target', () => _target(selection, paths)) ??
          TargetInfo(
            widget: typeName(selection.element),
            sourceUnavailable: selection.sourceUnavailable,
          ),
      ancestors:
          field('ancestors', () => _ancestors(selection, paths)) ??
          const <AncestorInfo>[],
      frameworkChain:
          field('frameworkChain', () => _frameworkChain(selection)) ??
          const <String>[],
      siblings: field('siblings', () => _siblings(selection)),
      subtree: field(
        'subtree',
        () => subtreeOutline(
          selection.element,
          resolver: selection.chain.resolver,
          maxLabel: maxLabel,
        ),
      ),
      inherited: field('inherited', () => _inherited(selection.element)),
      errors: errors,
    );
    lastElapsed = watch.elapsed;
    assert(() {
      if (watch.elapsedMilliseconds > 16) {
        debugPrint(
          'pinpoint: collecting ${note.id} took '
          '${watch.elapsedMilliseconds} ms.',
        );
      }
      return true;
    }());
    return note;
  }

  static AppInfo _app(SourcePaths paths) => AppInfo(
    buildMode: kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
    projectRoot: paths.projectRoot,
  );

  PageInfo _page(BuildContext context, PickResult selection) {
    // The real view, read above the app. Milestone 9: with a what-if
    // environment active, the app sees an overridden MediaQuery; record
    // that one too (from inside the EnvironmentHost) beside this one.
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    final locale = context.findAncestorWidgetOfExactType<Localizations>();
    final url = _pageUrl();
    return PageInfo(
      url: url == null ? null : clipText(url.toString(), maxShortText),
      // A widget above the Navigator, or in an overlay entry, has no
      // ModalRoute; the URL is then the best guess.
      route: _clip(_routeOf(selection.pickedElement) ?? routeFromUrl(url)),
      viewport: media == null
          ? null
          : PayloadSize(media.size.width, media.size.height),
      devicePixelRatio: media?.devicePixelRatio,
      textScale: media == null ? null : media.textScaler.scale(14) / 14,
      brightness: media?.platformBrightness.name,
      locale: locale?.locale.toString(),
    );
  }

  /// The name of the route [picked] is in, or null.
  ///
  /// The one accepted exception to engineering rule 3: no public lookup
  /// finds a route without depending on it. It is read on the picked
  /// element, which for a pick by position is the render object's own
  /// element, not a widget the app's author wrote a build method for, and
  /// through the settings aspect only, so it rebuilds only if the route's
  /// settings change.
  static String? _routeOf(Element picked) {
    try {
      return ModalRoute.settingsOf(picked)?.name;
    } catch (_) {
      return null;
    }
  }

  /// The route part of a page URL: the fragment for hash routing
  /// (`/#/orders/12`), else the path. Null for no URL.
  static String? routeFromUrl(Uri? url) {
    if (url == null) return null;
    final fragment = url.fragment;
    if (fragment.startsWith('/')) {
      return Uri.tryParse(fragment)?.path ?? fragment;
    }
    return url.path.isEmpty ? null : url.path;
  }

  static TargetInfo _target(PickResult selection, SourcePaths paths) {
    final entry = selection.entry;
    final key = entry.key;
    return TargetInfo(
      widget: entry.name,
      key: key == null ? null : clipText(key.toString(), maxShortText),
      source: _ref(entry.location, paths),
      sourceUnavailable: selection.sourceUnavailable,
    );
  }

  static List<AncestorInfo> _ancestors(
    PickResult selection,
    SourcePaths paths,
  ) {
    final chain = selection.chain;
    final ancestors = <AncestorInfo>[];
    for (
      var i = selection.chainIndex + 1;
      i < chain.length && ancestors.length < maxAncestors;
      i++
    ) {
      final entry = chain[i];
      if (!entry.isLocal) continue;
      ancestors.add(
        AncestorInfo(widget: entry.name, source: _ref(entry.location, paths)),
      );
    }
    return ancestors;
  }

  static List<String> _frameworkChain(PickResult selection) {
    final elements = selection.chain.elements;
    return [
      for (var i = 0; i < elements.length && i < maxFrameworkChain; i++)
        typeName(elements[i]),
    ];
  }

  /// The nearest ancestor of the target with more than one child, inside
  /// the app. Null when there is none.
  static SiblingsInfo? _siblings(PickResult selection) {
    final elements = selection.chain.elements;
    for (var i = selection.chainIndex + 1; i < elements.length; i++) {
      final parent = elements[i];
      final children = <Element>[];
      parent.visitChildren(children.add);
      if (children.length < 2) continue;
      final index = children.indexOf(elements[i - 1]);
      if (index < 0) return null;
      final first = math.max(
        0,
        math.min(index - maxSiblings ~/ 2, children.length - maxSiblings),
      );
      final last = math.min(children.length, first + maxSiblings);
      return SiblingsInfo(
        parent: clipText(shortLabel(parent), maxLabel),
        index: index,
        count: children.length,
        firstIndex: first,
        children: [
          for (final child in children.sublist(first, last))
            clipText(shortLabel(child), maxLabel),
        ],
      );
    }
    return null;
  }

  static InheritedInfo _inherited(Element target) {
    final theme = target.findAncestorWidgetOfExactType<Theme>()?.data;
    final direction = target
        .getInheritedWidgetOfExactType<Directionality>()
        ?.textDirection;
    return InheritedInfo(
      themeBrightness: theme?.brightness.name,
      useMaterial3: theme?.useMaterial3,
      textDirection: direction?.name,
    );
  }

  /// [location] for the payload: the file relative to the project root,
  /// with any `file://` prefix stripped.
  static SourceRef? _ref(SourceLocation? location, SourcePaths paths) =>
      location == null
      ? null
      : SourceRef(
          file: paths.relativePath(location.uri),
          line: location.line,
          column: location.column,
        );

  static String? _clip(String? text) =>
      text == null ? null : clipText(text, maxShortText);
}
