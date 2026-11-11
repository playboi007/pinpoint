import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../model/annotation.dart';
import '../model/source_location.dart';
import 'source_resolver.dart';

/// Finds live elements from a [NoteAnchor]: the reverse of a pick.
///
/// With `source_resolver.dart`, the only file that may touch the inspector
/// (engineering rule 8). It reads locations only through
/// [SourceResolver.locationOf], which caches them per widget instance.
class SourceIndex {
  SourceIndex({required this.resolver, this.maxNodes = defaultMaxNodes});

  /// Default cap on elements visited per walk (engineering rule 4).
  static const int defaultMaxNodes = 50000;

  /// Reads locations and decides which files are local.
  final SourceResolver resolver;

  /// Cap on elements visited per walk.
  final int maxNodes;

  /// Location reads made by walks, for tests.
  @visibleForTesting
  static int debugLocationReads = 0;

  /// Walks made, for tests.
  @visibleForTesting
  static int debugWalks = 0;

  // The slow-walk log's rate limit.
  static Stopwatch? _lastSlowLog;
  static int _slowWalks = 0;

  /// [element] as an anchor, with its [NoteAnchor.ordinal] among the
  /// elements under [root] that match the rest of it.
  ///
  /// Null when [element] is gone. Without a creation location (outside
  /// debug) the anchor has no file and never resolves.
  NoteAnchor? anchorFor(
    Element element, {
    required Element root,
    String? route,
  }) {
    final anchor = _baseAnchor(element, route);
    if (anchor == null || !anchor.resolvable) return anchor;
    final ordinal = find(anchor, root: root).indexOf(element);
    return anchor.withOrdinal(ordinal < 0 ? 0 : ordinal);
  }

  /// [anchorFor] for every element of [elements], in one walk. Elements
  /// that are gone are left out.
  Map<Element, NoteAnchor> anchorsFor(
    Iterable<Element> elements, {
    required Element root,
  }) {
    final bases = Map<Element, NoteAnchor>.identity();
    for (final element in elements) {
      final anchor = _baseAnchor(element, null);
      if (anchor != null) bases[element] = anchor;
    }
    final found = _walk(
      {
        for (final a in bases.values)
          if (a.resolvable) a,
      }.toList(),
      root,
    );
    return {
      for (final MapEntry(key: element, value: anchor) in bases.entries)
        element: anchor.resolvable
            ? anchor.withOrdinal(
                math.max(0, found[anchor]?.indexOf(element) ?? 0),
              )
            : anchor,
    };
  }

  /// [element] as an anchor with ordinal 0, or null when it is gone.
  NoteAnchor? _baseAnchor(Element element, String? route) {
    final Widget widget;
    try {
      widget = element.widget;
    } catch (_) {
      return null;
    }
    final location = resolver.locationOf(element);
    final key = widget.key;
    return NoteAnchor(
      file: location == null ? null : resolver.paths.relativePath(location.uri),
      line: location?.line,
      column: location?.column,
      widget: widget.runtimeType.toString(),
      key: key?.toString(),
      itemIndex: itemIndexOf(element),
      route: route,
    );
  }

  /// Every element under [root] that matches [anchor], in tree order.
  ///
  /// Same file and same widget type, then the best of: the same line and
  /// column, the same line, or (when the anchor names a type) the nearest
  /// line. Edits above a widget move its line; after a hot reload or a
  /// restart the nearest line of the same type is still the widget. Within
  /// that, an anchor with a key keeps the elements with that key, and one
  /// with an [NoteAnchor.itemIndex] only those in that list item.
  List<Element> find(NoteAnchor anchor, {required Element root}) =>
      _walk([anchor], root)[anchor] ?? const <Element>[];

  /// The element for [anchor]: entry [NoteAnchor.ordinal] of [find], or
  /// null when there is none.
  Element? resolve(NoteAnchor anchor, {required Element root}) =>
      _pick(anchor, find(anchor, root: root));

  /// [resolve] for every anchor, in one walk.
  Map<NoteAnchor, Element?> resolveAll(
    Iterable<NoteAnchor> anchors, {
    required Element root,
  }) {
    final list = anchors.toList();
    final found = _walk(list, root);
    return {for (final a in list) a: _pick(a, found[a] ?? const <Element>[])};
  }

  static Element? _pick(NoteAnchor anchor, List<Element> matches) =>
      anchor.ordinal < matches.length ? matches[anchor.ordinal] : null;

  /// Whether [element] still is what [anchor] names: mounted, the same
  /// type, and created in the same file. Cheap: the location is cached per
  /// widget instance. A pin checks this each frame before a new [find].
  bool stillMatches(Element element, NoteAnchor anchor) {
    try {
      if (!element.mounted) return false;
      final widget = element.widget;
      if (anchor.widget != null &&
          widget.runtimeType.toString() != anchor.widget) {
        return false;
      }
      final file = anchor.file;
      final location = resolver.locationOf(element);
      return file != null &&
          location != null &&
          fileMatches(location.uri, file);
    } catch (_) {
      return false;
    }
  }

  /// Whether [element] is the very constructor call [anchor] names:
  /// [stillMatches], and the same line and column. Handles use this:
  /// within one run a widget does not move, so another line is another
  /// widget.
  bool matchesExactly(Element element, NoteAnchor anchor) {
    if (!stillMatches(element, anchor)) return false;
    final location = resolver.locationOf(element);
    return location != null &&
        location.line == anchor.line &&
        location.column == anchor.column;
  }

  /// The element for [anchor] with no nearest-line fallback: entry
  /// [NoteAnchor.ordinal] of the elements at its exact line and column, or
  /// null.
  Element? resolveExact(NoteAnchor anchor, {required Element root}) {
    final exact = [
      for (final element in find(anchor, root: root))
        if (resolver.locationOf(element) case final location?
            when location.line == anchor.line &&
                location.column == anchor.column)
          element,
    ];
    return _pick(anchor, exact);
  }

  /// Every element under [root] that fits the query, in tree order: of
  /// [type] (a type name), passing [where], created in [file] and at
  /// [line]. Only the filters given apply.
  ///
  /// [file] is a path as [SourcePaths.relativePath] gives it, an absolute
  /// path, or its tail (`lib/home.dart`): an agent names files from the
  /// project folder even when no project root is set. With a [line] and a
  /// [type], an edit that moved the widget is followed to the nearest line
  /// of that type, as for a note's anchor.
  List<Element> query({
    required Element root,
    String? file,
    int? line,
    String? type,
    bool Function(Element element)? where,
  }) {
    debugWalks++;
    final found = <(Element, int?)>[];
    var visited = 0;
    final stack = <Element>[root];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      if (++visited > maxNodes) break;
      // Each element's read is guarded (engineering rule 4).
      try {
        final children = <Element>[];
        element.visitChildren(children.add);
        stack.addAll(children.reversed);
        if (type != null && element.widget.runtimeType.toString() != type) {
          continue;
        }
        if (where != null && !where(element)) continue;
        if (file == null && line == null) {
          found.add((element, null));
          continue;
        }
        debugLocationReads++;
        final location = resolver.locationOf(element);
        if (location == null) continue;
        if (file != null && !fileMatches(location.uri, file)) continue;
        found.add((element, location.line));
      } catch (_) {
        continue;
      }
    }
    if (line == null) return [for (final f in found) f.$1];
    var tier = found.where((f) => f.$2 == line);
    if (tier.isEmpty && type != null && file != null && found.isNotEmpty) {
      var nearest = (found.first.$2! - line).abs();
      for (final f in found) {
        nearest = math.min(nearest, (f.$2! - line).abs());
      }
      tier = found.where((f) => (f.$2! - line).abs() == nearest);
    }
    return [for (final f in tier) f.$1];
  }

  /// Whether the creation [location] is [file]: the same file as
  /// [SourcePaths.sameFile] says, or a relative [file] that is its tail.
  bool fileMatches(String location, String file) {
    if (resolver.paths.sameFile(location, file)) return true;
    final want = normalizeSourcePath(file);
    if (want.startsWith('/') || want.isEmpty) return false;
    final path = normalizeSourcePath(location);
    return resolver.paths.caseSensitive
        ? path.endsWith('/$want')
        : path.toLowerCase().endsWith('/${want.toLowerCase()}');
  }

  /// The index of the lazy-list item [element] is in: the nearest render
  /// ancestor that is a child of a sliver list or grid. Null outside one.
  static int? itemIndexOf(Element element) {
    try {
      RenderObject? node = element.renderObject;
      for (var steps = 0; node != null && steps < 512; steps++) {
        final data = node.parentData;
        if (data is SliverMultiBoxAdaptorParentData) return data.index;
        node = node.parent;
      }
    } catch (_) {
      // Unmounted or not laid out: no index.
    }
    return null;
  }

  Map<NoteAnchor, List<Element>> _walk(List<NoteAnchor> anchors, Element root) {
    debugWalks++;
    final watch = Stopwatch()..start();
    final searches = [
      for (final anchor in anchors)
        if (anchor.resolvable) _Search(anchor),
    ];
    if (searches.isEmpty) return const {};
    // Resolving a location costs a diagnostics serialization per element
    // the first time a widget instance is seen. That makes a cold walk the
    // slowest thing in the package, so filter by the widget type (a plain
    // runtimeType read) before any location is resolved.
    final byType = <String, List<_Search>>{};
    final untyped = <_Search>[];
    for (final search in searches) {
      final type = search.anchor.widget;
      if (type == null) {
        untyped.add(search);
      } else {
        (byType[type] ??= <_Search>[]).add(search);
      }
    }

    var visited = 0;
    final stack = <Element>[root];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      if (++visited > maxNodes) {
        assert(() {
          debugPrint(
            'pinpoint: source index walk stopped at $maxNodes elements.',
          );
          return true;
        }());
        break;
      }
      // Each element's read is guarded (engineering rule 4).
      try {
        final type = element.widget.runtimeType.toString();
        final typed = byType[type];
        if (typed != null || untyped.isNotEmpty) {
          debugLocationReads++;
          final location = resolver.locationOf(element);
          if (location != null) {
            for (final search in [...?typed, ...untyped]) {
              search.offer(element, location, this);
            }
          }
        }
        final children = <Element>[];
        element.visitChildren(children.add);
        // Reversed onto the stack, so they come off in tree order.
        stack.addAll(children.reversed);
      } catch (_) {
        continue;
      }
    }

    final result = {for (final s in searches) s.anchor: s.matches()};
    assert(() {
      if (watch.elapsedMilliseconds > 16) {
        _slowWalks++;
        // One line per 10 s at most: hovering draws frames, and the log
        // must not flood the console.
        final last = _lastSlowLog;
        if (last == null || last.elapsed >= const Duration(seconds: 10)) {
          final more = _slowWalks > 1 ? ', ${_slowWalks - 1} more since' : '';
          debugPrint(
            'pinpoint: source index walk took ${watch.elapsedMilliseconds} '
            'ms ($visited elements$more).',
          );
          _lastSlowLog = Stopwatch()..start();
          _slowWalks = 0;
        }
      }
      return true;
    }());
    return result;
  }
}

/// One anchor's matches during a walk.
class _Search {
  _Search(this.anchor);

  final NoteAnchor anchor;

  /// Candidates in the same file: element, line, column.
  final List<(Element, int, int?)> _found = <(Element, int, int?)>[];

  void offer(Element element, SourceLocation location, SourceIndex index) {
    // A relative anchor file (written by hand, or with no project root)
    // matches by the path's tail.
    if (!index.fileMatches(location.uri, anchor.file!)) return;
    _found.add((element, location.line, location.column));
  }

  List<Element> matches() {
    final line = anchor.line!;
    var tier = _found.where((f) => f.$2 == line && f.$3 == anchor.column);
    if (tier.isEmpty) tier = _found.where((f) => f.$2 == line);
    if (tier.isEmpty && anchor.widget != null && _found.isNotEmpty) {
      var nearest = (_found.first.$2 - line).abs();
      for (final f in _found) {
        final d = (f.$2 - line).abs();
        if (d < nearest) nearest = d;
      }
      tier = _found.where((f) => (f.$2 - line).abs() == nearest);
    }
    var elements = [for (final f in tier) f.$1];
    final item = anchor.itemIndex;
    if (item != null) {
      elements = [
        for (final e in elements)
          if (SourceIndex.itemIndexOf(e) == item) e,
      ];
    }
    final key = anchor.key;
    if (key != null) {
      final keyed = [
        for (final e in elements)
          if (e.widget.key?.toString() == key) e,
      ];
      if (keyed.isNotEmpty) elements = keyed;
    }
    return elements;
  }
}
