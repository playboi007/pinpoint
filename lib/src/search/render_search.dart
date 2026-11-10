import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// One render object under the pointer.
@immutable
class RenderCandidate {
  const RenderCandidate({
    required this.renderObject,
    required this.globalRect,
    required this.depth,
    required this.order,
  });

  final RenderObject renderObject;

  /// Paint bounds in global logical pixels. For a rotated widget this is the
  /// axis-aligned bounding rect, so it is larger than the widget (accepted in
  /// v1).
  final Rect globalRect;

  /// Depth below the walk's root. The root's children have depth 1.
  final int depth;

  /// Position in the walk (pre-order). Later siblings paint on top and come
  /// later.
  final int order;

  double get area => globalRect.width * globalRect.height;

  @override
  String toString() =>
      'RenderCandidate(${renderObject.runtimeType}, $globalRect, '
      'depth $depth, order $order)';
}

/// What one walk found, with the cost of finding it.
@immutable
class RenderSearchResult {
  const RenderSearchResult({
    required this.candidates,
    required this.visited,
    required this.truncated,
    required this.errors,
    required this.elapsed,
  });

  /// Smallest area first, then deepest, then latest in paint order.
  final List<RenderCandidate> candidates;

  /// Render objects visited.
  final int visited;

  /// Whether the walk stopped at the node or depth cap.
  final bool truncated;

  /// Render objects whose geometry read threw and that were skipped.
  final int errors;

  final Duration elapsed;
}

/// Finds every render object whose bounds contain a point.
///
/// This is a bounds walk of the render tree, the same approach as Flutter's
/// own widget inspector (`_hitTestHelper` in `widget_inspector.dart`), not a
/// real hit test. A hit test misses anything that does not take pointer
/// events: padding, a bare `SizedBox`, `IgnorePointer` children, decorative
/// boxes. Those are what people want to comment on.
abstract final class RenderSearch {
  /// Default cap on render objects visited per walk (engineering rule 4).
  static const int defaultMaxNodes = 20000;

  /// Default cap on depth below the root.
  static const int defaultMaxDepth = 512;

  /// Walks the subtree under [root] and returns every render object that
  /// contains [globalPosition] (global logical pixels), sorted with
  /// [compare]. [root] itself is not a candidate.
  static RenderSearchResult find(
    RenderObject root,
    Offset globalPosition, {
    int maxNodes = defaultMaxNodes,
    int maxDepth = defaultMaxDepth,
  }) {
    final walk = _Walk(globalPosition, maxNodes: maxNodes, maxDepth: maxDepth);
    final stopwatch = Stopwatch()..start();
    try {
      if (root.attached) walk.visit(root, root.getTransformTo(null), 0);
    } catch (_) {
      walk.errors++;
    }
    walk.hits.sort(compare);
    stopwatch.stop();
    assert(() {
      if (walk.truncated) {
        debugPrint(
          'pinpoint: pick walk stopped at ${walk.visited} nodes '
          '(caps: $maxNodes nodes, depth $maxDepth).',
        );
      }
      return true;
    }());
    return RenderSearchResult(
      candidates: List<RenderCandidate>.unmodifiable(walk.hits),
      visited: walk.visited,
      truncated: walk.truncated,
      errors: walk.errors,
      elapsed: stopwatch.elapsed,
    );
  }

  /// Orders candidates: smallest area first, then deepest, then latest in
  /// paint order.
  ///
  /// Many wrappers share one rect (`Padding` inside `Align` inside
  /// `SizedBox`), so area ties are the norm and depth decides most picks.
  /// Deepest first also keeps every wrapper in the picked widget's ancestor
  /// chain for Milestone 3. Later siblings paint on top, so on an area and
  /// depth tie the later one wins. `List.sort` is not stable, so every key is
  /// in the comparator.
  static int compare(RenderCandidate a, RenderCandidate b) {
    final byArea = _areaKey(a).compareTo(_areaKey(b));
    if (byArea != 0) return byArea;
    final byDepth = b.depth.compareTo(a.depth);
    if (byDepth != 0) return byDepth;
    return b.order.compareTo(a.order);
  }

  // Rects of wrappers that share one layout rect can differ in the last bit
  // after the transform. Rounding to 1/1000 px² makes them tie, and stays a
  // consistent order.
  static int _areaKey(RenderCandidate c) => (c.area * 1000).round();

  /// Whether [globalPosition] is on the app: inside [root]'s on-screen
  /// rect, where [root] is the app's boundary.
  ///
  /// With a what-if viewport the boundary is smaller than the screen. A
  /// pointer outside the viewport frame is over nothing, even where an
  /// app widget overflows its boundary (the frame clips it): the picker
  /// and the wheel passthrough refuse it, and Milestone 12's synthetic
  /// taps must too.
  static bool isOnApp(RenderObject root, Offset globalPosition) =>
      globalRectOf(root)?.contains(globalPosition) ?? false;

  /// The paint bounds of [renderObject] in global logical pixels, or null
  /// when it is detached, not laid out, or under a singular transform.
  static Rect? globalRectOf(RenderObject renderObject) {
    try {
      if (!renderObject.attached) return null;
      final rect = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        renderObject.paintBounds,
      );
      return rect.isFinite ? rect : null;
    } catch (_) {
      return null;
    }
  }

  /// The part of [renderObject] that is on screen, in global logical
  /// pixels: its rect cut by every clip above it (a scroll view, a
  /// `ClipRect`). Null when nothing of it shows: it is offstage (a route
  /// beneath an opaque route, a hidden `IndexedStack` child, `Offstage`),
  /// clipped away, or not laid out.
  ///
  /// It walks up to the root once; bounded like every walk (engineering
  /// rule 4).
  static Rect? visibleRectOf(RenderObject renderObject, {int maxDepth = 512}) {
    var visible = globalRectOf(renderObject);
    if (visible == null) return null;
    try {
      var child = renderObject;
      var parent = child.parent;
      for (var steps = 0; parent != null && steps < maxDepth; steps++) {
        // The same offstage marks the pick walk skips. Their geometry is
        // stale, and they are not painted.
        for (final node in parent.debugDescribeChildren()) {
          if (identical(node.value, child)) {
            if (node.style == DiagnosticsTreeStyle.offstage) return null;
            break;
          }
        }
        final clip = parent.describeApproximatePaintClip(child);
        if (clip != null) {
          final global = MatrixUtils.transformRect(
            parent.getTransformTo(null),
            clip,
          );
          if (!global.overlaps(visible!)) return null;
          visible = visible.intersect(global);
        }
        child = parent;
        parent = child.parent;
      }
    } catch (_) {
      // A custom render object that throws: show what is known.
    }
    return visible;
  }
}

class _Walk {
  _Walk(this.position, {required this.maxNodes, required this.maxDepth});

  final Offset position;
  final int maxNodes;
  final int maxDepth;

  final List<RenderCandidate> hits = <RenderCandidate>[];
  int visited = 0;
  int errors = 0;
  int _order = 0;
  bool truncated = false;

  /// [transform] maps [node]'s paint space to global logical pixels. It is
  /// carried down with `applyPaintTransform`, not recomputed per node with
  /// `getTransformTo`, which would walk to the root every time.
  void visit(RenderObject node, Matrix4 transform, int depth) {
    if (truncated) return;
    if (visited >= maxNodes || depth > maxDepth) {
      truncated = true;
      return;
    }
    visited++;

    final Offset local;
    final List<DiagnosticsNode> children;
    // Each node's read is guarded (engineering rule 4). A render object not
    // laid out yet throws on `paintBounds`; a custom one may throw anywhere.
    try {
      if (!node.attached) return;
      // A singular transform (scale 0, mid-animation) does not throw in
      // `transformRect` (docs/api-notes.md, item 4): the rect can come out
      // non-finite. Nothing beneath it is on screen, so skip the subtree.
      final inverse = Matrix4.tryInvert(transform);
      if (inverse == null) return;
      // The point test runs in the node's own space, so a rotated widget is
      // hit only inside its real shape, not its whole bounding rect.
      local = MatrixUtils.transformPoint(inverse, position);
      if (depth > 0) {
        final bounds = node.paintBounds;
        if (bounds.contains(local)) {
          final rect = MatrixUtils.transformRect(transform, bounds);
          if (rect.isFinite && !rect.isEmpty) {
            hits.add(
              RenderCandidate(
                renderObject: node,
                globalRect: rect,
                depth: depth,
                order: _order++,
              ),
            );
          }
        }
      }
      // `debugDescribeChildren()` allocates a diagnostics node per child. If
      // the walk is over budget, replace this first, but the replacement
      // must still skip offstage children (see below).
      children = node.debugDescribeChildren();
    } catch (_) {
      errors++;
      return;
    }

    for (final child in children) {
      // Offstage children keep stale geometry: routes beneath an opaque
      // route, IndexedStack's hidden children, Offstage, kept-alive slivers.
      if (child.style == DiagnosticsTreeStyle.offstage) continue;
      final value = child.value;
      // The theater also lists plain messages ("no offstage children").
      if (value is! RenderObject) continue;

      final Matrix4 childTransform;
      try {
        // Prune only on clips, never on the parent's own bounds: children can
        // overflow or be translated outside their parent. A `Row` or `Stack`
        // reports a clip only while it overflows.
        final clip = node.describeApproximatePaintClip(value);
        if (clip != null && !clip.contains(local)) continue;
        childTransform = transform.clone();
        node.applyPaintTransform(value, childTransform);
      } catch (_) {
        errors++;
        continue;
      }
      visit(value, childTransform, depth + 1);
    }
  }
}
