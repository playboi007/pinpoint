import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../info/widget_info.dart';
import '../model/annotation.dart';
import '../model/source_location.dart';
import '../search/pick_result.dart';
import '../search/source_index.dart';
import '../state/dependencies.dart';
import '../trace/redact.dart';
import 'lean_text.dart';
import 'subtree_outline.dart';

/// Builds the [Annotation] for a selection: everything an agent needs to
/// act on the comment without seeing the app.
///
/// Each payload field has its own collector. One that throws records the
/// field's name in [Annotation.errors] and leaves the field empty, so the
/// note is still sent. Each field is capped as it is read, and the whole
/// note is then cut to [maxPayloadBytes].
///
/// Nothing here subscribes an app element to an inherited widget: reads go
/// through `getInheritedWidgetOfExactType`
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

  /// Widgets above the target in [Annotation.ancestors], after the
  /// wrappers in [skippedAncestors] are left out.
  static const int maxAncestors = 8;

  /// State owners in [Annotation.stateOwners].
  static const int maxStateOwners = 4;

  /// Wrappers that never explain a layout or the code: they hold no
  /// layout of their own and the agent has nothing to change in them.
  /// Left out of [Annotation.ancestors] by type name (a generic one by its
  /// name before the `<`), even when the project made them (an app's own
  /// `Semantics` call is a local widget to the inspector).
  static const Set<String> skippedAncestors = {
    'Semantics',
    'MergeSemantics',
    'ExcludeSemantics',
    'BlockSemantics',
    'Builder',
    'StatefulBuilder',
    'KeyedSubtree',
    'Directionality',
    'MediaQuery',
    'DefaultTextStyle',
    'IconTheme',
    'Theme',
    'Actions',
    'Shortcuts',
    'Focus',
    'FocusScope',
    'FocusTraversalGroup',
    'NotificationListener',
    'RepaintBoundary',
    'Material',
  };

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

  /// How long the last [collect] took. Logged in debug when over a frame.
  Duration? lastElapsed;

  /// The note for [selection], with [comment] and [intent].
  ///
  /// [context] is Pinpoint's own: the page is described from there, so the
  /// app's elements are not touched for it. [environment] is the active
  /// what-if overrides (`EnvironmentController.toJson`). [trace] is what
  /// happened before the pick (`traceForNote`).
  Annotation collect(
    PickResult selection,
    String comment,
    AnnotationIntent intent, {
    required BuildContext context,
    Map<String, Object?>? environment,
    Map<String, Object?>? trace,
  }) {
    final watch = Stopwatch()..start();
    final note = _noteFor(
      selection,
      comment,
      intent,
      context: context,
      environment: environment,
      trace: trace,
    );
    lastElapsed = watch.elapsed;
    assert(_logIfSlow(note, watch));
    return note;
  }

  Annotation _noteFor(
    PickResult selection,
    String comment,
    AnnotationIntent intent, {
    required BuildContext context,
    Map<String, Object?>? environment,
    Map<String, Object?>? trace,
  }) {
    final fields = _Fields();
    final field = fields.read;
    final paths = selection.chain.resolver.paths;
    final now = _clock();
    final page =
        field('page', () => _page(context, selection)) ?? const PageInfo();
    return Annotation(
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
      stateOwners:
          field('stateOwners', () => _stateOwners(selection, paths)) ??
          const <StateOwnerInfo>[],
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
      trace: trace,
      errors: fields.errors,
    ).fitToBudget();
  }

  static bool _logIfSlow(Annotation note, Stopwatch watch) {
    if (watch.elapsedMilliseconds > 16) {
      debugPrint(
        'pinpoint: collecting ${note.id} took '
        '${watch.elapsedMilliseconds} ms.',
      );
    }
    return true;
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
      // Every query value is masked: the page URL often carries a session
      // token: no secret leaves the app.
      url: url == null
          ? null
          : clipText(const TraceRedact().pageUrl(url.toString()), maxShortText),
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
  /// The one exception to "never subscribe an app element": no public lookup
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
      return owner is RenderObjectElement ? routeNameOf(owner) : null;
    } catch (_) {
      return null;
    }
  }

  /// The name of the route [owner] is in, or null. [owner] owns a render
  /// object, so it is never an inherited element (see [_routeOf] for why
  /// that matters, and for the exception this is).
  static String? routeNameOf(RenderObjectElement owner) {
    try {
      if (!owner.mounted) return null;
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
  /// and any other value that contains it is masked whole. Masking cannot fail on its own; if the scan for obscured
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
                          if (leanText(p.label) case final label?)
                            p.name: mask(clipText(label, maxPropertyText)),
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
      // A framework default has level `fine` and is dropped above. What is
      // left is cleaned of hash codes and of parts that have no value.
      final lean = leanText(property.toDescription());
      return lean == null ? null : clipText(lean, maxPropertyText);
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
      if (!entry.isLocal || skippedAncestors.contains(_baseName(entry.name))) {
        continue;
      }
      ancestors.add(
        AncestorInfo(widget: entry.name, source: _ref(entry.location, paths)),
      );
    }
    return ancestors;
  }

  /// A type name without its type arguments: `Foo<Bar>` is `Foo`.
  static String _baseName(String name) {
    final open = name.indexOf('<');
    return open < 0 ? name : name.substring(0, open);
  }

  /// The objects that hold state for the target, nearest first, at most
  /// [maxStateOwners]:
  ///
  /// - a `StatefulElement` whose widget the project made, and whose `State`
  ///   the project wrote: `state`, typed by its `State` class. The first
  ///   is not enough: a `Scaffold` or a `ListView` in the app's `build` is
  ///   made by the project too, but its `State` is the framework's. What
  ///   tells them apart is what `State.build` returns: widgets created in
  ///   the project's source for an app `State` (and for `StatefulBuilder`,
  ///   which holds app state), widgets created in the framework for a
  ///   framework one;
  /// - a provider-like scope: `_InheritedProviderScope<Foo?>` (the
  ///   `provider` package) is `provider` of `Foo`, and an `InheritedNotifier`
  ///   is `notifier`, of its generic argument. An `InheritedModel` is a
  ///   `provider`, named by its argument.
  ///
  /// The scope's source is the nearest local widget at or just above it:
  /// the scope itself is made inside the package, by the app's
  /// `ChangeNotifierProvider(...)` call.
  static List<StateOwnerInfo> _stateOwners(
    PickResult selection,
    SourcePaths paths,
  ) {
    final chain = selection.chain;
    final resolver = chain.resolver;
    final owners = <StateOwnerInfo>[];
    for (
      var i = selection.chainIndex;
      i < chain.length && owners.length < maxStateOwners;
      i++
    ) {
      final element = chain.elements[i];
      if (element is StatefulElement || element is StatelessElement) {
        // A `State` the project wrote (`state`), or a stateless widget the
        // project wrote that reads a state object (`reader`), with what
        // it reads.
        final entry = chain[i];
        if (!entry.isLocal) continue;
        final reader = readerOf(element, resolver);
        if (reader != null) owners.add(reader.toInfo(paths));
      } else if (element is InheritedElement) {
        final scope = scopeOf(element.widget.runtimeType.toString());
        if (scope == null) continue;
        final (kind, type) = scope;
        SourceLocation? where;
        for (var j = i; j < chain.length && j <= i + 3; j++) {
          if (chain[j].isLocal) {
            where = chain[j].location;
            break;
          }
        }
        owners.add(
          StateOwnerInfo(
            kind: kind,
            type: clipText(type, maxLabel),
            source: _ref(where, paths),
          ),
        );
      }
    }
    return owners;
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
