import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../info/widget_info.dart';
import '../model/annotation.dart';
import '../model/source_location.dart';
import '../search/pick_result.dart';
import '../search/source_index.dart';
import 'subtree_outline.dart';

/// Builds the [Annotation] for a selection: everything an agent needs to
/// act on the comment without seeing the app.
///
/// Each payload field has its own collector. One that throws records the
/// field's name in [Annotation.errors] and leaves the field empty, so the
/// note is still sent. Each field is capped as it is read, and the whole
/// note is then cut to [maxPayloadBytes] (engineering rule 9).
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

  /// Longest key, URL, route, constraints or parent data.
  static const int maxShortText = 300;

  /// Entries in [TargetInfo.properties].
  static const int maxProperties = 20;

  /// Longest description, property value or section label.
  static const int maxPropertyText = 200;

  /// Field names whose collector throws, to test the error path.
  @visibleForTesting
  static Set<String> debugFailFields = const <String>{};

  /// How long the last [collect] took. Logged in debug when over a frame
  /// (engineering rule 4).
  Duration? lastElapsed;

  /// The note for [selection], with [comment] and [intent].
  ///
  /// [context] is Pinpoint's own: the page is described from there, so the
  /// app's elements are not touched for it. [environment] is the active
  /// what-if overrides (`EnvironmentController.toJson`).
  Annotation collect(
    PickResult selection,
    String comment,
    AnnotationIntent intent, {
    required BuildContext context,
    Map<String, Object?>? environment,
  }) {
    final watch = Stopwatch()..start();
    final fields = _Fields();
    final field = fields.read;
    final paths = selection.chain.resolver.paths;
    final now = _clock();
    final page =
        field('page', () => _page(context, selection)) ?? const PageInfo();
    final note = Annotation(
      id: annotationId(now, _random),
      createdAt: now,
      intent: intent,
      comment: comment,
      app:
          field('app.origin', () => _app(paths, origin: _origin())) ??
          _app(paths),
      page: page,
      environment: environment == null || environment.isEmpty
          ? null
          : environment,
      target:
          field('target', () => _target(selection, paths, fields)) ??
          TargetInfo(
            widget: typeName(selection.element),
            sourceUnavailable: selection.sourceUnavailable,
          ),
      anchor: field('anchor', () => _anchor(selection, page.route)),
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
      errors: fields.errors,
    ).fitToBudget();
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

  /// The page's origin on web, for example `http://localhost:5000`.
  String? _origin() {
    final url = _pageUrl();
    if (url == null || !(url.isScheme('http') || url.isScheme('https'))) {
      return null;
    }
    return url.origin;
  }

  /// Where the note's pin belongs: the selected widget's constructor call,
  /// and which of its matches it is. The walk for the ordinal is bounded,
  /// and runs once per note.
  static NoteAnchor? _anchor(PickResult selection, String? route) {
    final elements = selection.chain.elements;
    return SourceIndex(resolver: selection.chain.resolver).anchorFor(
      selection.element,
      // The chain's last element is the app's top widget, below Pinpoint's
      // wrappers.
      root: elements.last,
      route: route,
    );
  }

  static AppInfo _app(SourcePaths paths, {String? origin}) => AppInfo(
    buildMode: kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
    projectRoot: paths.projectRoot,
    origin: origin,
  );

  PageInfo _page(BuildContext context, PickResult selection) {
    // The real view, read above the app. With a what-if environment active
    // the app sees an overridden MediaQuery; the note's `environment`
    // records the overrides beside this.
    final media = context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    final locale = context.findAncestorWidgetOfExactType<Localizations>();
    final url = _pageUrl();
    return PageInfo(
      url: url == null ? null : clipText(url.toString(), maxShortText),
      // A widget above the Navigator, or in an overlay entry, has no
      // ModalRoute; the URL is then the best guess.
      route: _clip(_routeOf(selection) ?? routeFromUrl(url)),
      viewport: media == null
          ? null
          : PayloadSize(media.size.width, media.size.height),
      devicePixelRatio: media?.devicePixelRatio,
      textScale: media == null ? null : media.textScaler.scale(14) / 14,
      brightness: media?.platformBrightness.name,
      locale: locale?.locale.toString(),
    );
  }

  /// The name of the route the selection is in, or null.
  ///
  /// The one accepted exception to engineering rule 3: no public lookup
  /// finds a route without depending on it. It is read on the element that
  /// owns the picked render object, which is not a widget the app's author
  /// wrote a build method for, and through the settings aspect only, so it
  /// rebuilds only if the route's settings change.
  ///
  /// Never on the picked element as such: [PickResult.forElement] can pick
  /// any element, the route's own `_ModalScopeStatus` included. That
  /// element would then depend on itself, and the framework asserts when
  /// the route's status next changes. A render object's element is never an
  /// inherited element.
  static String? _routeOf(PickResult selection) {
    try {
      final picked = selection.pickedElement;
      final creator = selection.pickedRenderObject.debugCreator;
      final owner = picked is RenderObjectElement
          ? picked
          : creator is DebugCreator
          ? creator.element
          : null;
      if (owner == null || !owner.mounted) return null;
      return ModalRoute.settingsOf(owner)?.name;
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

  /// The selected widget, from the same [WidgetInfo] the info panel
  /// shows, so the panel and the note never disagree.
  ///
  /// Text from an obscured field never leaves: its own text is replaced,
  /// and any other value that contains it is masked whole (engineering
  /// rule 9). Masking cannot fail on its own; if the scan for obscured
  /// fields throws, the whole target is left empty.
  static TargetInfo _target(
    PickResult selection,
    SourcePaths paths,
    _Fields fields,
  ) {
    final field = fields.read;
    final entry = selection.entry;
    final element = selection.element;
    final widget = element.widget;
    final scan = _TextScan.of(element);
    final mask = scan.mask;
    final info = field(
      'target.info',
      () => WidgetInfo.fromRenderObject(selection.renderObject),
    );
    final key = entry.key;
    return TargetInfo(
      widget: entry.name,
      description: field('target.description', () => mask(_describe(widget))),
      key: key == null ? null : mask(clipText(key.toString(), maxShortText)),
      source: _ref(entry.location, paths),
      sourceUnavailable: selection.sourceUnavailable,
      rect: info == null
          ? null
          : PayloadRect(
              info.globalPosition.dx,
              info.globalPosition.dy,
              info.size.width,
              info.size.height,
            ),
      renderObject: info?.renderType,
      // Strings, so unbounded constraints (`Infinity`) stay valid JSON.
      constraints: field(
        'target.constraints',
        () => _clip(info?.constraints?.toString()),
      ),
      // Flex factor, fit and offset live here.
      parentData: field(
        'target.parentData',
        () => _clip(selection.renderObject.parentData?.toString(), mask),
      ),
      text: field('target.text', () => scan.text),
      properties:
          field('target.properties', () => _properties(widget, mask)) ??
          const <String, String>{},
      sections: info == null
          ? const <String, Map<String, String>>{}
          : field(
                  'target.sections',
                  () => {
                    for (final section in info.sections)
                      section.title: {
                        for (final p in section.properties)
                          p.name: mask(clipText(p.label, maxPropertyText)),
                      },
                  },
                ) ??
                const <String, Map<String, String>>{},
    );
  }

  /// `toStringShort()` plus the values shown without a name, for example
  /// `Text("Save changes")` or `Icon(IconData(U+0E161))`.
  static String _describe(Widget widget) {
    String short;
    try {
      short = widget.toStringShort();
    } catch (_) {
      short = widget.runtimeType.toString();
    }
    final unnamed = <String>[];
    try {
      for (final property in widget.toDiagnosticsNode().getProperties()) {
        if (property.showName) continue;
        final description = _describeProperty(property);
        if (description != null) unnamed.add(description);
      }
    } catch (_) {
      // Author code; the short form alone is still useful.
    }
    final text = unnamed.isEmpty ? short : '$short(${unnamed.join(', ')})';
    return clipText(text, maxPropertyText);
  }

  /// The widget's own named diagnostics at info level or above with a
  /// value, as `name: description`. At most [maxProperties].
  static Map<String, String> _properties(
    Widget widget,
    String Function(String) mask,
  ) {
    final properties = <String, String>{};
    for (final property in widget.toDiagnosticsNode().getProperties()) {
      if (properties.length >= maxProperties) break;
      final name = property.name;
      if (name == null || !property.showName) continue;
      final description = _describeProperty(property);
      if (description == null) continue;
      properties[clipText(name, maxLabel)] = mask(description);
    }
    return properties;
  }

  /// [property]'s description, or null when it is below info level, has no
  /// value, or its author code throws. Colors are hex: `Color.toString()`
  /// changed format across Flutter releases.
  static String? _describeProperty(DiagnosticsNode property) {
    try {
      final level = property.level;
      if (level.index < DiagnosticLevel.info.index ||
          level == DiagnosticLevel.off) {
        return null;
      }
      final value = property.value;
      if (value == null) return null;
      if (value is Color) return formatColor(value);
      return clipText(property.toDescription(), maxPropertyText);
    } catch (_) {
      return null;
    }
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

  static String? _clip(String? text, [String Function(String)? mask]) {
    if (text == null) return null;
    final clipped = clipText(text, maxShortText);
    return mask == null ? clipped : mask(clipped);
  }
}

/// Runs each payload field's collector and records the ones that fail.
class _Fields {
  final List<String> errors = <String>[];

  T? read<T extends Object>(String name, T? Function() collect) {
    try {
      if (ContextCollector.debugFailFields.contains(name)) {
        throw StateError('pinpoint: $name failed on purpose');
      }
      return collect();
    } catch (_) {
      errors.add(name);
      return null;
    }
  }
}

/// The text under an element, and the text of every obscured field in it
/// or around it, which must never leave the app.
class _TextScan {
  _TextScan._(this._parts, this._secrets);

  /// Scans at most [maxNodes] elements under [element], depth first. An
  /// obscured field beyond that is not read either, so its text cannot
  /// leak through [text].
  factory _TextScan.of(Element element, {int maxNodes = 5000}) {
    final secrets = <String>{};
    final parts = <String>[];
    void field(EditableText editable) {
      final value = editable.controller.text;
      if (editable.obscureText && value.isNotEmpty) secrets.add(value);
    }

    // The target can be inside the field, for example its EditableText's
    // own render widget.
    final around = element.findAncestorWidgetOfExactType<EditableText>();
    if (around != null) field(around);
    final stack = <Element>[element];
    var length = 0;
    for (var visited = 0; stack.isNotEmpty && visited < maxNodes; visited++) {
      final current = stack.removeLast();
      final widget = current.widget;
      String? part;
      if (widget is RichText) {
        part = widget.text.toPlainText();
      } else if (widget is EditableText) {
        field(widget);
        part = widget.obscureText ? masked : widget.controller.text;
      }
      if (part != null && part.isNotEmpty && length <= maxText) {
        parts.add(part);
        length += part.length + 1;
      }
      final children = <Element>[];
      current.visitChildren(children.add);
      stack.addAll(children.reversed);
    }
    return _TextScan._(parts, secrets);
  }

  static const String masked = '[masked]';

  /// Longest [text].
  static const int maxText = 300;

  final List<String> _parts;
  final Set<String> _secrets;

  /// Text shown under the element, joined with spaces and cut to
  /// [maxText]. Null when there is none.
  late final String? text = _parts.isEmpty
      ? null
      : mask(clipText(_parts.join(' '), maxText));

  /// [value], or [masked] when it holds an obscured field's text.
  String mask(String value) => _secrets.any(value.contains) ? masked : value;
}
