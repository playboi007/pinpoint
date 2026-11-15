import 'package:flutter/rendering.dart';

import '../../search/render_search.dart';
import 'construction_boxes.dart';

/// Reads the layout of a widget once, from the render tree, for the
/// blueprint of its construction site.
///
/// It uses the same walk as the pick and the pin: [RenderSearch.visitVisible]
/// (bounded, skips offstage and clipped parts). Nothing is read again while
/// the site stands, and nothing here draws or schedules a frame.
abstract final class ConstructionBlueprint {
  /// The most render objects the walk looks at, and its depth.
  static const int maxNodes = 800;
  static const int maxDepth = 24;

  /// Two rects this near are the same box.
  static const double _same = 0.5;

  /// The boxes under [root] (a note's widget), relative to [widget], the
  /// widget's visible rect in global logical pixels.
  ///
  /// Skipped: boxes under [ConstructionBoxes.minSide] px, boxes with the
  /// same rect as their parent (wrappers like `Padding` around nothing)
  /// or as the widget, boxes of render objects that are not boxes.
  ///
  /// Then a readable outline, not every box: a box over
  /// [ConstructionBoxes.maxShare] of the widget only frames everything and
  /// is left out; the rest are taken biggest first, and a near copy of a box
  /// already taken (over [ConstructionBoxes.maxOverlap] of it inside that
  /// box, and at least half its size) is skipped, so nested wrappers drop
  /// out; at most [ConstructionBoxes.maxBoxes], so small thin parts give way
  /// to the main ones. A busy card (seen live: a "Run details"
  /// card gave 40 boxes that, broken, filled it) becomes its main parts.
  /// The result is in paint order, so the same tree gives the same boxes.
  static List<ConstructionBox> read(RenderObject root, Rect widget) {
    final found = <_Found>[];
    final byNode = <RenderObject, Rect>{};
    try {
      RenderSearch.visitVisible(
        root,
        (node, rect, visible) {
          if (node is! RenderBox) return;
          final shown = visible.intersect(widget);
          if (shown.isEmpty) return;
          // The parent's rect, from the nearest box above that was seen.
          Rect? parent;
          for (RenderObject? up = node.parent; up != null; up = up.parent) {
            parent = byNode[up];
            if (parent != null || identical(up, root)) break;
          }
          byNode[node] = shown;
          if (shown.width < ConstructionBoxes.minSide ||
              shown.height < ConstructionBoxes.minSide) {
            return;
          }
          if (_alike(shown, widget)) return;
          if (parent != null && _alike(shown, parent)) return;
          found.add(_Found(node, shown, found.length));
        },
        maxNodes: maxNodes,
        maxDepth: maxDepth,
      );
    } catch (_) {
      // A custom render object that throws: use what was read.
    }

    final whole = widget.width * widget.height;
    double area(Rect r) => r.width * r.height;
    final candidates =
        [
          for (final f in found)
            if (area(f.rect) <= ConstructionBoxes.maxShare * whole) f,
        ]..sort((a, b) {
          final byArea = area(b.rect).compareTo(area(a.rect));
          return byArea != 0 ? byArea : a.order.compareTo(b.order);
        });
    final picked = <_Found>[];
    for (final f in candidates) {
      if (picked.length == ConstructionBoxes.maxBoxes) break;
      final covered = picked.any((p) {
        final overlap = p.rect.intersect(f.rect);
        // A near copy: mostly inside a box taken, and at least half its
        // size. A button inside a row is much smaller: it stays.
        return !overlap.isEmpty &&
            area(overlap) > ConstructionBoxes.maxOverlap * area(f.rect) &&
            area(f.rect) > 0.5 * area(p.rect);
      });
      if (!covered) picked.add(f);
    }
    picked.sort((a, b) => a.order.compareTo(b.order));

    double r1(double v) => (v * 10).roundToDouble() / 10;
    return [
      for (final f in picked)
        ConstructionBox(
          r1(f.rect.left - widget.left),
          r1(f.rect.top - widget.top),
          r1(f.rect.width),
          r1(f.rect.height),
        ),
    ];
  }

  static bool _alike(Rect a, Rect b) =>
      (a.left - b.left).abs() <= _same &&
      (a.top - b.top).abs() <= _same &&
      (a.right - b.right).abs() <= _same &&
      (a.bottom - b.bottom).abs() <= _same;
}

class _Found {
  _Found(this.node, this.rect, this.order);

  final RenderObject node;
  final Rect rect;
  final int order;
}
