import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/pinpoint_config.dart';
import '../model/source_location.dart';

/// Default cap on elements in one chain (engineering rule 4).
const int defaultMaxChain = 1000;

/// Reads where widgets were created in source.
///
/// With `source_index.dart`, the only file that touches
/// [WidgetInspectorService] (engineering rule 8). A Flutter upgrade that
/// changes the inspector should break here and nowhere else;
/// `test/source/source_resolver_test.dart` checks a known file and line.
class SourceResolver {
  const SourceResolver({this.tracked, this.paths = const SourcePaths()});

  /// A resolver with [config]'s project root and path hints.
  factory SourceResolver.forConfig(PinPointConfig config) => SourceResolver(
    paths: SourcePaths(
      projectRoot: config.projectRoot,
      localPathHints: config.localPathHints,
      // macOS and Windows file systems ignore case by default. On web this
      // is the browser's platform, which on localhost is the dev machine's.
      caseSensitive: defaultTargetPlatform == TargetPlatform.linux,
    ),
  );

  /// Whether creation locations exist. Null: ask the inspector.
  final bool? tracked;

  /// Which files are the project's own.
  final SourcePaths paths;

  /// Set to false in a test to act as profile mode, where creation locations
  /// do not exist.
  @visibleForTesting
  static bool? debugTrackedOverride;

  /// Whether creation locations exist in this build.
  ///
  /// They need `--track-widget-creation`, which is on in debug only. When
  /// false, no location work is done at all, and every pick is marked
  /// `sourceUnavailable`.
  bool get available =>
      tracked ??
      debugTrackedOverride ??
      WidgetInspectorService.instance.isWidgetCreationTracked();

  /// Locations keyed by the widget instance. A location belongs to the
  /// widget, not the element: a hot reload builds new widget instances, so
  /// edited lines are read again, and an old entry goes with its widget.
  static final Expando<Object> _cache = Expando<Object>(
    'pinpoint source locations',
  );

  /// Stored for a widget that has no location, so it is not read again.
  static const Object _none = Object();

  /// Where [element]'s widget was created, or null when unknown.
  ///
  /// Read through the inspector's serializer on the widget alone (no
  /// children, no properties). This does not set the inspector's global
  /// selection, so DevTools keeps showing what the user selected there.
  SourceLocation? locationOf(Element element) {
    if (!available) return null;
    final Widget widget;
    try {
      widget = element.widget; // throws once the element is unmounted
    } catch (_) {
      return null;
    }
    final cached = _cache[widget];
    if (cached != null) return cached is SourceLocation ? cached : null;
    final location = _read(widget);
    _cache[widget] = location ?? _none;
    return location;
  }

  /// [element] with its location and whether that is the project's own.
  ChainEntry entryOf(Element element) {
    final location = locationOf(element);
    var name = '?';
    Key? key;
    try {
      name = element.widget.runtimeType.toString();
      key = element.widget.key;
    } catch (_) {
      // Unmounted: keep the placeholders.
    }
    return ChainEntry(
      element: element,
      name: name,
      key: key,
      location: location,
      isLocal: location != null && paths.isLocal(location.uri),
    );
  }

  /// The chain from [picked] up to, not including, [boundary].
  ///
  /// [boundary] is the element just above the app's own widgets, so
  /// Pinpoint's wrappers never show up. Capped at [maxLength] elements; an
  /// element that cannot be walked ends the chain where it is.
  SourceChain chain(
    Element picked, {
    required Element boundary,
    int maxLength = defaultMaxChain,
  }) {
    final elements = <Element>[picked];
    try {
      picked.visitAncestorElements((ancestor) {
        if (identical(ancestor, boundary)) return false;
        if (elements.length >= maxLength) return false;
        elements.add(ancestor);
        return true;
      });
    } catch (_) {
      // An element that is no longer active asserts on ancestor lookup.
    }
    return SourceChain(elements, this);
  }

  static SourceLocation? _read(Widget widget) {
    try {
      // `toJsonMap` builds its map inside an assert, so outside debug it is
      // empty (docs/api-notes.md, item 1). `available` already covers that.
      final json = widget.toDiagnosticsNode().toJsonMap(
        InspectorSerializationDelegate(
          service: WidgetInspectorService.instance,
          subtreeDepth: 0,
          includeProperties: false,
        ),
      );
      final location = json['creationLocation'];
      if (location is! Map) return null;
      final file = location['file'];
      final line = location['line'];
      final column = location['column'];
      final name = location['name'];
      if (file is! String || line is! int || column is! int) return null;
      return SourceLocation(
        uri: file,
        line: line,
        column: column,
        name: name is String ? name : null,
      );
    } catch (_) {
      // Diagnostics run code written by widget authors; one that throws
      // must not stop a pick (engineering rule 4).
      return null;
    }
  }
}

/// One widget in a [SourceChain].
@immutable
class ChainEntry {
  const ChainEntry({
    required this.element,
    required this.name,
    required this.key,
    required this.location,
    required this.isLocal,
  });

  final Element element;

  /// The widget's type name, for example `Text`.
  final String name;

  final Key? key;

  /// Where the widget was created, or null outside debug.
  final SourceLocation? location;

  /// Whether [location] is in the project's own source.
  final bool isLocal;

  /// Whether [location] is a generated file. Such an entry is local but is
  /// passed over for the default selection.
  bool get isGenerated {
    final where = location;
    return where != null && isGeneratedSource(normalizeSourcePath(where.uri));
  }

  @override
  String toString() =>
      'ChainEntry($name, ${location ?? 'no location'}'
      '${isLocal ? ', local' : ''})';
}

/// The widgets from a picked element up to the app, nearest first.
///
/// Entries are resolved on first use: a hover only needs the first local
/// one, so most of a long chain is never read.
class SourceChain {
  SourceChain(List<Element> elements, this.resolver)
    : elements = List<Element>.unmodifiable(elements),
      _entries = List<ChainEntry?>.filled(elements.length, null);

  /// Index 0 is the picked element; the last is the app's top element.
  final List<Element> elements;

  final SourceResolver resolver;

  final List<ChainEntry?> _entries;

  int get length => elements.length;

  ChainEntry operator [](int index) =>
      _entries[index] ??= resolver.entryOf(elements[index]);

  /// The first local entry that is not in a generated file; else the first
  /// local entry; else null. Null too when creation locations do not exist.
  late final int? defaultIndex = _findDefault();

  int? _findDefault() {
    if (!resolver.available) return null;
    int? firstLocal;
    for (var i = 0; i < length; i++) {
      final entry = this[i];
      if (!entry.isLocal) continue;
      if (!entry.isGenerated) return i;
      firstLocal ??= i;
    }
    return firstLocal;
  }

  /// The next local entry above [from] (toward the app) when [up], else
  /// below it (toward the picked widget). Null when there is none.
  int? nextLocal(int from, {required bool up}) {
    if (!resolver.available) return null;
    for (
      var i = up ? from + 1 : from - 1;
      i >= 0 && i < length;
      i += up ? 1 : -1
    ) {
      if (this[i].isLocal) return i;
    }
    return null;
  }

  /// The entry at [index] and up to `max - 1` local entries above it,
  /// outermost first, for example `Row > ElevatedButton > Text`.
  List<ChainEntry> breadcrumb(int index, {int max = 3}) {
    final crumbs = <ChainEntry>[this[index]];
    for (
      var i = nextLocal(index, up: true);
      i != null && crumbs.length < max;
      i = nextLocal(i, up: true)
    ) {
      crumbs.add(this[i]);
    }
    return crumbs.reversed.toList();
  }

  /// Every local entry, nearest first. Reads the whole chain.
  List<ChainEntry> get localEntries => [
    for (var i = 0; i < length; i++)
      if (this[i].isLocal) this[i],
  ];
}
