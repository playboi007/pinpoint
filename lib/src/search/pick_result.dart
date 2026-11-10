import 'package:flutter/widgets.dart';

import 'element_lookup.dart';
import 'render_search.dart';
import 'source_resolver.dart';

/// What is under the pointer: every candidate, which one is chosen, the
/// chain of widgets above it, and which of those is selected.
///
/// The picked render object almost always belongs to a framework widget
/// (`RichText`, `DecoratedBox`). The selection is the nearest widget in the
/// chain written in the project's own source, so the outline and the
/// location name the widget the user wrote.
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
    required this.chain,
    required this.chainIndex,
    required this.renderObject,
    required this.globalRect,
    required this.ancestor,
    required this.ancestorRect,
    required this.sourceUnavailable,
    required this._root,
  });

  /// A result built by hand, for tests that need no render tree. The chain
  /// holds [element] alone, with no location.
  @visibleForTesting
  factory PickResult.debug({
    required Offset position,
    required List<RenderCandidate> candidates,
    required int index,
    required Element element,
    required Rect globalRect,
    RenderObject? ancestor,
    Rect? ancestorRect,
  }) => PickResult._(
    position: position,
    candidates: candidates,
    index: index,
    chain: SourceChain([element], const SourceResolver(tracked: false)),
    chainIndex: 0,
    renderObject: candidates[index].renderObject,
    globalRect: globalRect,
    ancestor: ancestor,
    ancestorRect: ancestorRect,
    sourceUnavailable: true,
    root: null,
  );

  /// Builds a result from [search] at [position].
  ///
  /// Each candidate's element starts a chain up to [chainBoundary] (by
  /// default [rootElement]), and the chain's default entry is selected.
  ///
  /// When [previous] has the same candidates (the same spot clicked again),
  /// the next candidate whose selection differs from [previous]'s is chosen,
  /// wrapping around. Several candidates inside one button all refine to the
  /// button, so this climbs instead of selecting the button again. It also
  /// reaches a small widget hidden under an opaque sibling. Otherwise the
  /// first is chosen. Candidates whose element cannot be found are passed
  /// over. Null when nothing is under [position].
  static PickResult? fromSearch(
    RenderSearchResult search, {
    required Offset position,
    required Element rootElement,
    Element? chainBoundary,
    SourceResolver resolver = const SourceResolver(),
    PickResult? previous,
  }) {
    final candidates = search.candidates;
    if (candidates.isEmpty) return null;
    final cycling = previous != null && previous._sameCandidates(candidates);
    final start = cycling ? previous.index + 1 : 0;
    PickResult? fallback;
    for (var step = 0; step < candidates.length; step++) {
      final index = (start + step) % candidates.length;
      final candidate = candidates[index];
      final picked = elementFor(candidate.renderObject, root: rootElement);
      if (picked == null) continue;
      final chain = resolver.chain(
        picked,
        boundary: chainBoundary ?? rootElement,
      );
      final chosen = chain.defaultIndex;
      final result = _build(
        position: position,
        candidates: candidates,
        index: index,
        chain: chain,
        chainIndex: chosen ?? 0,
        sourceUnavailable: chosen == null,
        root: rootElement.renderObject,
      );
      if (!cycling || !identical(result.element, previous.element)) {
        return result;
      }
      fallback ??= result;
    }
    return fallback;
  }

  static PickResult _build({
    required Offset position,
    required List<RenderCandidate> candidates,
    required int index,
    required SourceChain chain,
    required int chainIndex,
    required bool sourceUnavailable,
    required RenderObject? root,
  }) {
    final picked = candidates[index];
    final renderObject =
        _renderObjectOf(chain.elements[chainIndex]) ?? picked.renderObject;
    final rect = identical(renderObject, picked.renderObject)
        ? picked.globalRect
        : RenderSearch.globalRectOf(renderObject) ?? picked.globalRect;
    final ancestor =
        _localAncestorOf(chain, chainIndex, rect) ??
        _renderAncestorOf(renderObject, rect, root: root);
    return PickResult._(
      position: position,
      candidates: candidates,
      index: index,
      chain: chain,
      chainIndex: chainIndex,
      renderObject: renderObject,
      globalRect: rect,
      ancestor: ancestor?.$1,
      ancestorRect: ancestor?.$2,
      sourceUnavailable: sourceUnavailable,
      root: root,
    );
  }

  /// Where the pointer was, in global logical pixels.
  final Offset position;

  /// Everything under [position], in [RenderSearch.compare] order.
  final List<RenderCandidate> candidates;

  /// Which of [candidates] is chosen.
  final int index;

  /// The widgets from [pickedElement] up to the app.
  final SourceChain chain;

  /// Which entry of [chain] is selected.
  final int chainIndex;

  /// The render object of the selected element: its own, or for a
  /// component element the nearest one beneath it. The outline and the
  /// info panel describe this.
  final RenderObject renderObject;

  /// [renderObject]'s paint bounds in global logical pixels, as of the last
  /// [refreshed].
  final Rect globalRect;

  /// What the rulers measure to: the nearest local ancestor in [chain]
  /// whose rect differs from [globalRect]; without one, the nearest render
  /// ancestor whose rect differs.
  final RenderObject? ancestor;

  /// [ancestor]'s paint bounds in global logical pixels.
  final Rect? ancestorRect;

  /// True when no entry in [chain] has a local source location: outside
  /// debug, or for a widget built entirely by the framework. The selection
  /// is then the picked element itself.
  final bool sourceUnavailable;

  /// The app's root render object, where the rulers' render-ancestor walk
  /// stops.
  final RenderObject? _root;

  /// The selected entry of [chain].
  ChainEntry get entry => chain[chainIndex];

  /// The selected element.
  Element get element => chain.elements[chainIndex];

  /// The element that owns the picked render object.
  Element get pickedElement => chain.elements.first;

  /// The render object the search found under the pointer.
  RenderObject get pickedRenderObject => candidates[index].renderObject;

  /// This result with [globalRect] read again from the render tree.
  ///
  /// Null when the picked or the selected element is no longer mounted. The
  /// same instance when nothing has changed, or the rect cannot be read
  /// right now (for example a scale of 0 mid-animation).
  PickResult? refreshed() {
    if (!pickedElement.mounted || !element.mounted) return null;
    // A component's nearest render object changes when its child is
    // replaced.
    final current = _renderObjectOf(element) ?? renderObject;
    final rect = RenderSearch.globalRectOf(current) ?? globalRect;
    final parent = ancestor;
    final parentRect = parent == null
        ? null
        : RenderSearch.globalRectOf(parent) ?? ancestorRect;
    if (identical(current, renderObject) &&
        rect == globalRect &&
        parentRect == ancestorRect) {
      return this;
    }
    return PickResult._(
      position: position,
      candidates: candidates,
      index: index,
      chain: chain,
      chainIndex: chainIndex,
      renderObject: current,
      globalRect: rect,
      ancestor: parent,
      ancestorRect: parentRect,
      sourceUnavailable: sourceUnavailable,
      root: _root,
    );
  }

  /// This result with another entry of [chain] selected: the next local
  /// one above when [up], else the next local one below. With [localOnly]
  /// false, the next entry either way, framework widgets included.
  ///
  /// The same instance when there is none, or its element is gone.
  PickResult stepped({required bool up, bool localOnly = true}) {
    final target = localOnly
        ? chain.nextLocal(chainIndex, up: up)
        : chainIndex + (up ? 1 : -1);
    if (target == null || target < 0 || target >= chain.length) return this;
    if (!chain.elements[target].mounted) return this;
    return _build(
      position: position,
      candidates: candidates,
      index: index,
      chain: chain,
      chainIndex: target,
      sourceUnavailable: sourceUnavailable,
      root: _root,
    );
  }

  static RenderObject? _renderObjectOf(Element element) {
    try {
      return element.renderObject;
    } catch (_) {
      return null;
    }
  }

  /// The nearest local entry above [index] whose render object's rect
  /// differs from [rect]. A custom widget shares its rect with the root of
  /// its build, and a ruler of 0 to each edge says nothing.
  static (RenderObject, Rect)? _localAncestorOf(
    SourceChain chain,
    int index,
    Rect rect,
  ) {
    for (
      int? i = chain.nextLocal(index, up: true);
      i != null;
      i = chain.nextLocal(i, up: true)
    ) {
      final renderObject = _renderObjectOf(chain.elements[i]);
      if (renderObject == null) continue;
      final ancestorRect = RenderSearch.globalRectOf(renderObject);
      if (ancestorRect != null && ancestorRect != rect) {
        return (renderObject, ancestorRect);
      }
    }
    return null;
  }

  /// Steps up from [node] until a rect differs from [rect]. Wrappers often
  /// share one rect (`Padding` inside `Align`). Bounded like every walk.
  static (RenderObject, Rect)? _renderAncestorOf(
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
      'PickResult(${entry.name}, $globalRect, '
      '${index + 1} of ${candidates.length})';
}
