import 'package:flutter/widgets.dart';

import '../capture/context_collector.dart';
import '../model/source_location.dart';
import '../search/element_lookup.dart';
import '../search/render_search.dart';
import '../search/source_resolver.dart';

/// How bad a [Finding] is.
enum Severity { info, warning, error }

/// One problem a detector found on the current screen.
///
/// Every detector produces this same value, so the findings list, the notes
/// and the stress matrix (Milestone 12) treat them alike.
@immutable
class Finding {
  const Finding({
    required this.kind,
    required this.severity,
    required this.summary,
    this.element,
    this.rect,
    this.source,
    this.route,
    this.data = const <String, Object?>{},
  });

  /// For example `overflow`, `truncated_text`, `oversized_image`.
  final String kind;

  final Severity severity;

  /// The element that owns the problem's render object, or null when it
  /// cannot be located (an error outside the widget tree).
  final Element? element;

  /// Where it is, in global logical pixels, when it was found.
  final Rect? rect;

  /// One line, for example `Row overflows by 23 px on the right`.
  final String summary;

  /// The nearest local widget's constructor call, or null when unknown.
  final SourceLocation? source;

  /// The name of the route it is in, or null.
  final String? route;

  /// Measured values, for example `{'overflow': 23.0, 'side': 'right'}`.
  /// Only JSON values: it goes into the note.
  final Map<String, Object?> data;

  /// What deduplicates findings: kind, source location and route. Without
  /// a source location the summary stands in for it.
  String get key => '$kind|${source ?? summary}|${route ?? ''}';

  /// The finding as it goes into a note: no element and no rect.
  Map<String, Object?> toJson() => {
    'kind': kind,
    'severity': severity.name,
    'summary': summary,
    'key': key,
    if (data.isNotEmpty) 'data': data,
  };

  @override
  String toString() => 'Finding($kind, ${severity.name}, $summary)';
}

/// The checks Milestone 12's `verify_note` runs for a note made from
/// [finding]: the measurement that found it, which must pass after the fix.
/// Empty when no check measures that kind.
List<Map<String, Object?>> checksFor(Finding finding) => switch (finding.kind) {
  'overflow' => const [
    {'type': 'no_overflow'},
  ],
  'truncated_text' => const [
    {'type': 'not_truncated'},
  ],
  'small_tap_target' => const [
    {'type': 'tap_target_min', 'min': 48},
  ],
  'low_contrast' => [
    {'type': 'contrast_min', 'min': finding.data['required'] ?? 4.5},
  ],
  _ => const <Map<String, Object?>>[],
};

/// A detector that runs over the render tree on demand ("Scan this
/// screen").
///
/// The scan runner walks the visible tree once and hands each render
/// object to every detector, so each one adds no walk of its own.
abstract class Detector {
  const Detector();

  /// The [Finding.kind] this detector produces.
  String get kind;

  /// The findings for one render object of the walk; usually none.
  Iterable<Finding> scan(RenderObject renderObject, ScanContext context);
}

/// What a [Detector] knows about the render object it is given.
class ScanContext {
  ScanContext._(this._locator);

  final FindingLocator _locator;

  /// The render object's rect, in global logical pixels.
  Rect rect = Rect.zero;

  /// The part of [rect] no clip hides.
  Rect visible = Rect.zero;

  /// A finding on [renderObject], located: its element, the nearest local
  /// widget's source and its route are filled in.
  Finding finding(
    RenderObject renderObject, {
    required String kind,
    required Severity severity,
    required String summary,
    Map<String, Object?> data = const <String, Object?>{},
    Rect? rect,
  }) {
    final place = _locator.locate(renderObject);
    return Finding(
      kind: kind,
      severity: severity,
      summary: summary,
      element: place.element,
      rect: rect ?? this.rect,
      source: place.source,
      route: place.route,
      data: data,
    );
  }

  /// The element that owns [renderObject], or null.
  Element? elementOf(RenderObject renderObject) =>
      _locator.locate(renderObject).element;
}

/// Finds the element, the source and the route of a render object.
class FindingLocator {
  FindingLocator({this.resolver = const SourceResolver(), this.boundary});

  final SourceResolver resolver;

  /// The element directly above the app's own widgets: chains stop here,
  /// and outside debug the element index is built from here.
  final Element? boundary;

  Map<RenderObject, Element>? _index;

  /// The element that owns [renderObject], or null.
  Element? elementOf(RenderObject renderObject) => _elementOf(renderObject);

  /// Where [renderObject] is. Every part is null when unknown.
  ({Element? element, SourceLocation? source, String? route}) locate(
    RenderObject renderObject,
  ) {
    final element = _elementOf(renderObject);
    if (element == null) return (element: null, source: null, route: null);
    return (
      element: element,
      source: sourceOf(element),
      route: element is RenderObjectElement
          ? ContextCollector.routeNameOf(element)
          : null,
    );
  }

  /// The location of the nearest local widget at or above [element].
  SourceLocation? sourceOf(Element element) => localEntryOf(element)?.location;

  /// The nearest local widget at or above [element], or null.
  ChainEntry? localEntryOf(Element element) {
    try {
      final top = boundary;
      final chain = top == null
          ? resolver.chain(element, boundary: element)
          : resolver.chain(element, boundary: top);
      final index = chain.defaultIndex;
      return index == null ? null : chain[index];
    } catch (_) {
      return null;
    }
  }

  /// The type name of the nearest local widget at or above [element], else
  /// of [element]'s own widget: `IconButton`, not the `Semantics` inside it.
  String? widgetNameOf(Element element) {
    final local = localEntryOf(element);
    if (local != null) return local.name;
    try {
      return element.widget.runtimeType.toString();
    } catch (_) {
      return null;
    }
  }

  /// Whether [element] is the app's, not Pinpoint's own UI: at or below
  /// [boundary]. Always true without a boundary.
  bool isInApp(Element element, {int maxDepth = 2000}) {
    final top = boundary;
    if (top == null || identical(element, top)) return true;
    var found = false;
    var steps = 0;
    try {
      element.visitAncestorElements((ancestor) {
        found = identical(ancestor, top);
        return !found && ++steps < maxDepth;
      });
    } catch (_) {
      // An inactive element asserts on ancestor lookup.
    }
    return found;
  }

  Element? _elementOf(RenderObject renderObject) {
    final creator = renderObject.debugCreator;
    if (creator is DebugCreator) return creator.element;
    // Profile mode: no debugCreator. Index the app once per scan.
    final top = boundary;
    if (top == null) return null;
    return (_index ??= indexRenderObjects(top))[renderObject];
  }
}

/// What one scan found, with the cost of finding it.
@immutable
class FindingScan {
  const FindingScan({
    required this.findings,
    required this.visited,
    required this.truncated,
    required this.errors,
    required this.elapsed,
  });

  /// Deduplicated, in walk order.
  final List<Finding> findings;

  /// Render objects visited.
  final int visited;

  /// Whether the walk stopped at its cap.
  final bool truncated;

  /// Render objects or detector calls that threw and were skipped.
  final int errors;

  final Duration elapsed;
}

/// Walks the visible render tree under [root] once and hands each render
/// object to every detector in [detectors].
///
/// [root] is the app's boundary, so Pinpoint's own UI is never scanned.
/// Offstage and clipped content is skipped (the Milestone 2 walk). A
/// detector that throws on one render object loses that one only
/// (engineering rule 4).
FindingScan scanTree(
  RenderObject root,
  List<Detector> detectors, {
  FindingLocator? locator,
  int maxNodes = RenderSearch.defaultMaxNodes,
  bool includeRoot = false,
}) {
  final context = ScanContext._(locator ?? FindingLocator());
  final found = <Finding>[];
  var errors = 0;
  final walk = RenderSearch.visitVisible(
    root,
    (node, rect, visible) {
      context
        ..rect = rect
        ..visible = visible;
      for (final detector in detectors) {
        try {
          found.addAll(detector.scan(node, context));
        } catch (_) {
          errors++;
        }
      }
    },
    maxNodes: maxNodes,
    includeRoot: includeRoot,
  );
  assert(() {
    if (walk.elapsed.inMilliseconds > 16 || walk.truncated) {
      debugPrint(
        'pinpoint: scan of ${walk.visited} render objects took '
        '${walk.elapsed.inMilliseconds} ms'
        '${walk.truncated ? ' and stopped at its cap' : ''}.',
      );
    }
    return true;
  }());
  return FindingScan(
    findings: dedupeFindings(found),
    visited: walk.visited,
    truncated: walk.truncated,
    errors: errors + walk.errors,
    elapsed: walk.elapsed,
  );
}

/// [findings] with one finding per [Finding.key], the first one kept, so a
/// re-scan never piles up copies.
List<Finding> dedupeFindings(Iterable<Finding> findings) {
  final seen = <String>{};
  return [
    for (final finding in findings)
      if (seen.add(finding.key)) finding,
  ];
}
