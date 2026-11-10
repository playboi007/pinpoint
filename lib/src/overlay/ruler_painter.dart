import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../info/widget_info.dart';
import '../search/pick_result.dart';

/// Which edge a ruler measures from.
enum RulerSide { left, top, right, bottom }

/// One measured distance, as a line from [start] to [end] in global logical
/// pixels.
@immutable
class RulerSegment {
  const RulerSegment({
    required this.side,
    required this.start,
    required this.end,
    required this.distance,
  });

  final RulerSide side;
  final Offset start;
  final Offset end;

  /// Signed: negative when the inner rect sticks out past the outer edge.
  final double distance;

  String get label => formatNumber(distance);

  @override
  String toString() => 'RulerSegment($side, $distance)';
}

/// The four distances from [inner]'s edges to [outer]'s edges.
///
/// Left gap plus width plus right gap is [outer]'s width; the same holds
/// for the height.
List<RulerSegment> ancestorRulers(Rect inner, Rect outer) {
  final cx = inner.center.dx;
  final cy = inner.center.dy;
  return [
    RulerSegment(
      side: RulerSide.left,
      start: Offset(outer.left, cy),
      end: Offset(inner.left, cy),
      distance: inner.left - outer.left,
    ),
    RulerSegment(
      side: RulerSide.top,
      start: Offset(cx, outer.top),
      end: Offset(cx, inner.top),
      distance: inner.top - outer.top,
    ),
    RulerSegment(
      side: RulerSide.right,
      start: Offset(inner.right, cy),
      end: Offset(outer.right, cy),
      distance: outer.right - inner.right,
    ),
    RulerSegment(
      side: RulerSide.bottom,
      start: Offset(cx, inner.bottom),
      end: Offset(cx, outer.bottom),
      distance: outer.bottom - inner.bottom,
    ),
  ];
}

/// The gaps between two rects, for measuring with Alt held.
///
/// When one rect holds the other, the four edge distances. Otherwise one
/// segment for each axis on which they are apart; none for an axis on which
/// they overlap.
List<RulerSegment> gapRulers(Rect a, Rect b) {
  if (_holds(b, a)) return ancestorRulers(a, b);
  if (_holds(a, b)) return ancestorRulers(b, a);

  final segments = <RulerSegment>[];
  // Draw across the middle of the overlap when there is one.
  final y = a.top < b.bottom && b.top < a.bottom
      ? (_max(a.top, b.top) + _min(a.bottom, b.bottom)) / 2
      : a.center.dy;
  final x = a.left < b.right && b.left < a.right
      ? (_max(a.left, b.left) + _min(a.right, b.right)) / 2
      : a.center.dx;
  if (a.right <= b.left) {
    segments.add(_gap(RulerSide.right, Offset(a.right, y), Offset(b.left, y)));
  } else if (b.right <= a.left) {
    segments.add(_gap(RulerSide.left, Offset(b.right, y), Offset(a.left, y)));
  }
  if (a.bottom <= b.top) {
    segments.add(_gap(RulerSide.bottom, Offset(x, a.bottom), Offset(x, b.top)));
  } else if (b.bottom <= a.top) {
    segments.add(_gap(RulerSide.top, Offset(x, b.bottom), Offset(x, a.top)));
  }
  return segments;
}

bool _holds(Rect outer, Rect inner) =>
    outer.left <= inner.left &&
    outer.top <= inner.top &&
    outer.right >= inner.right &&
    outer.bottom >= inner.bottom;

double _max(double a, double b) => a > b ? a : b;
double _min(double a, double b) => a < b ? a : b;

RulerSegment _gap(RulerSide side, Offset start, Offset end) => RulerSegment(
  side: side,
  start: start,
  end: end,
  distance: (end - start).distance,
);

/// Draws dashed rulers from the selection to its ancestor, or, with Alt
/// held and another widget hovered, the gaps between the two.
///
/// Must sit inside an `IgnorePointer`, like the highlight.
class RulerPainter extends CustomPainter {
  RulerPainter({
    required this.selected,
    required this.hovered,
    required this.measuring,
    required this.origin,
  }) : super(repaint: Listenable.merge([selected, hovered, measuring]));

  final ValueListenable<PickResult?> selected;
  final ValueListenable<PickResult?> hovered;
  final ValueListenable<bool> measuring;

  /// This layer's top-left in global logical pixels; see `HighlightPainter`.
  final ValueGetter<Offset> origin;

  static const Color color = Color(0xFFD50000);
  static const double dash = 4;
  static const double gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final selection = selected.value;
    if (selection == null) return;
    final hover = hovered.value;
    final List<RulerSegment> segments;
    if (measuring.value &&
        hover != null &&
        !identical(hover.renderObject, selection.renderObject)) {
      segments = gapRulers(selection.globalRect, hover.globalRect);
    } else if (selection.ancestorRect case final ancestor?) {
      segments = ancestorRulers(selection.globalRect, ancestor);
    } else {
      return;
    }

    canvas.save();
    canvas.translate(-origin().dx, -origin().dy);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final segment in segments) {
      if ((segment.end - segment.start).distance < 0.5) continue;
      _dashed(canvas, segment.start, segment.end, line);
      _label(canvas, segment);
    }
    canvas.restore();
  }

  // Canvas has no dashed stroke, so draw short segments in a loop.
  static void _dashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    final total = (to - from).distance;
    final step = (to - from) / total;
    for (var at = 0.0; at < total; at += dash + gap) {
      final end = at + dash < total ? at + dash : total;
      canvas.drawLine(from + step * at, from + step * end, paint);
    }
  }

  static void _label(Canvas canvas, RulerSegment segment) {
    final text = TextPainter(
      text: TextSpan(
        text: segment.label,
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final mid = Offset.lerp(segment.start, segment.end, 0.5)!;
    final pill = Rect.fromCenter(
      center: mid,
      width: text.width + 6,
      height: text.height + 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, const Radius.circular(3)),
      Paint()..color = color,
    );
    text
      ..paint(canvas, pill.topLeft + const Offset(3, 1))
      ..dispose();
  }

  @override
  bool shouldRepaint(RulerPainter oldDelegate) =>
      oldDelegate.selected != selected ||
      oldDelegate.hovered != hovered ||
      oldDelegate.measuring != measuring;
}
