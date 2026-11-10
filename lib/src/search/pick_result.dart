import 'package:flutter/widgets.dart';

import 'element_lookup.dart';
import 'render_search.dart';

/// What is under the pointer: every candidate, which one is chosen, and the
/// chosen one's element and rect.
///
/// A value: [refreshed] returns a new result when the rect moves, and the
/// same instance when nothing changed, so listeners are only told about real
/// changes.
@immutable
class PickResult {
  const PickResult._({
    required this.position,
    required this.candidates,
    required this.index,
    required this.element,
    required this.globalRect,
    required this.ancestor,
    required this.ancestorRect,
  });

  /// A result built by hand, for tests that need no render tree.
  @visibleForTesting
  const PickResult.debug({
    required this.position,
    required this.candidates,
    required this.index,
    required this.element,
    required this.globalRect,
    this.ancestor,
    this.ancestorRect,
  });

  /// Builds a result from [search] at [position].
  ///
  /// When [previous] has the same candidates (the same spot clicked again),
  /// the next candidate is chosen, wrapping around. That reaches a small
  /// widget hidden under an opaque sibling. Otherwise the first is chosen.
  /// Candidates whose element cannot be found are passed over. Null when
  /// nothing is under [position].
  static PickResult? fromSearch(
    RenderSearchResult search, {
    required Offset position,
    required Element rootElement,
    PickResult? previous,
  }) {
    final candidates = search.candidates;
    if (candidates.isEmpty) return null;
    final start = previous != null && previous._sameCandidates(candidates)
        ? previous.index + 1
        : 0;
    for (var step = 0; step < candidates.length; step++) {
      final index = (start + step) % candidates.length;
      final candidate = candidates[index];
      final element = elementFor(candidate.renderObject, root: rootElement);
      if (element == null) continue;
      final ancestor = _ancestorOf(
        candidate.renderObject,
        candidate.globalRect,
        root: rootElement.renderObject,
      );
      return PickResult._(
        position: position,
        candidates: candidates,
        index: index,
        element: element,
        globalRect: candidate.globalRect,
        ancestor: ancestor?.$1,
        ancestorRect: ancestor?.$2,
      );
    }
    return null;
  }

  /// Where the pointer was, in global logical pixels.
  final Offset position;

  /// Everything under [position], in [RenderSearch.compare] order.
  final List<RenderCandidate> candidates;

  /// Which of [candidates] is chosen.
  final int index;

  /// The element that owns [renderObject].
  final Element element;

  /// [renderObject]'s paint bounds in global logical pixels, as of the last
  /// [refreshed].
  final Rect globalRect;

  /// The nearest render ancestor whose rect differs from [globalRect], below
  /// the app root. The rulers measure to it. Milestone 3 changes this to the
  /// nearest local-project ancestor.
  final RenderObject? ancestor;

  /// [ancestor]'s paint bounds in global logical pixels.
  final Rect? ancestorRect;

  RenderObject get renderObject => candidates[index].renderObject;

  /// This result with [globalRect] read again from the render tree.
  ///
  /// Null when the element is no longer mounted. The same instance when the
  /// rect has not changed, or cannot be read right now (for example a scale
  /// of 0 mid-animation).
  PickResult? refreshed() {
    if (!element.mounted) return null;
    final rect = RenderSearch.globalRectOf(renderObject) ?? globalRect;
    final parent = ancestor;
    final parentRect = parent == null
        ? null
        : RenderSearch.globalRectOf(parent) ?? ancestorRect;
    if (rect == globalRect && parentRect == ancestorRect) return this;
    return PickResult._(
      position: position,
      candidates: candidates,
      index: index,
      element: element,
      globalRect: rect,
      ancestor: parent,
      ancestorRect: parentRect,
    );
  }

  /// Steps up from [node] until a rect differs from [rect]. Wrappers often
  /// share one rect (`Padding` inside `Align`), and a ruler of 0 to each
  /// edge says nothing. Bounded like every walk.
  static (RenderObject, Rect)? _ancestorOf(
    RenderObject node,
    Rect rect, {
    required RenderObject? root,
  }) {
    var current = node.parent;
    for (var steps = 0; current != null && steps < 512; steps++) {
      if (identical(current, root)) return null;
      final parentRect = RenderSearch.globalRectOf(current);
      if (parentRect != null && parentRect != rect) {
        return (current, parentRect);
      }
      current = current.parent;
    }
    return null;
  }

  bool _sameCandidates(List<RenderCandidate> other) {
    if (other.length != candidates.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (!identical(other[i].renderObject, candidates[i].renderObject)) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() =>
      'PickResult(${element.widget.runtimeType}, $globalRect, '
      '${index + 1} of ${candidates.length})';
}
