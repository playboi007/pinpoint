import 'package:flutter/rendering.dart';

import 'pinpoint_tokens.dart';

// Canvas helpers for Pinpoint's `CustomPainter`s: the Drafting marks.
//
// Every mark is painted over a halo in the palette's `paper`, so it stays
// visible on white, saturated and near-black hosts. The rect helpers take the
// widget's bounds and draw the rings around and inside that edge, the way
// the design's CSS box-shadow stacks do.

/// The dashes of [source], as one path.
///
/// [pattern] lists lengths along the path: on, off, on, off, and so on. It
/// repeats, and starts again at each contour, so a closed rectangle starts
/// its first dash at its first corner. An empty pattern, a negative length, or
/// a pattern that adds up to zero returns [source] unchanged.
Path dashPath(Path source, List<double> pattern) {
  if (pattern.any((length) => length < 0) ||
      pattern.fold<double>(0, (sum, length) => sum + length) <= 0) {
    return source;
  }
  final dashed = Path();
  for (final metric in source.computeMetrics()) {
    var distance = 0.0;
    var index = 0;
    var on = true;
    while (distance < metric.length) {
      final length = pattern[index % pattern.length];
      if (on && length > 0) {
        final end = distance + length < metric.length
            ? distance + length
            : metric.length;
        dashed.addPath(metric.extractPath(distance, end), Offset.zero);
      }
      distance += length;
      index++;
      on = !on;
    }
  }
  return dashed;
}

/// Strokes [path] with [mark] over a solid halo.
///
/// The halo is the same path in `tokens.paper`, 2 px wider than [mark]: 1 px
/// each side. With [dash] (see [dashPath]), only the mark is dashed; the halo
/// stays solid, as the design's box-shadow halos run around a dashed border.
/// The gaps of a dashed ruler therefore read as paper.
///
/// [mark] must be a stroke paint; its width, cap and join are copied to the
/// halo.
void strokeHalo(
  Canvas canvas,
  Path path,
  Paint mark,
  PinPointTokens tokens, {
  List<double>? dash,
}) {
  final halo = Paint()
    ..style = PaintingStyle.stroke
    ..color = tokens.paper
    ..strokeWidth = mark.strokeWidth + 2
    ..strokeCap = mark.strokeCap
    ..strokeJoin = mark.strokeJoin
    ..strokeMiterLimit = mark.strokeMiterLimit;
  canvas.drawPath(path, halo);
  canvas.drawPath(dash == null ? path : dashPath(path, dash), mark);
}

/// A [width] px ring whose outer edge is [outer]. Rings are drawn from the
/// inside out, each one starting where the last one ended.
void _ring(Canvas canvas, Rect outer, double width, Color color) {
  canvas.drawRect(
    outer.deflate(width / 2),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color,
  );
}

/// The hover outline: 1 px dashed `ink` (4 on, 3 off) on the edge of
/// [rect], with a 1 px solid `paper` halo outside and inside. No fill.
void paintHover(Canvas canvas, Rect rect, PinPointTokens tokens) {
  strokeHalo(
    canvas,
    Path()..addRect(rect.deflate(0.5)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = tokens.ink,
    tokens,
    dash: const [4, 3],
  );
}

/// The selected outline: 2 px solid `accent` inside the edge of [rect], then
/// a 1 px `paper` ring and a 1 px `ink` ring outside it. No fill.
void paintSelected(Canvas canvas, Rect rect, PinPointTokens tokens) {
  _ring(canvas, rect.inflate(2), 1, tokens.ink);
  _ring(canvas, rect.inflate(1), 1, tokens.paper);
  _ring(canvas, rect, 2, tokens.accent);
}

/// The outline of a tweaked widget: 1.5 px dotted `edit` inside the edge of
/// [rect], with a 1 px solid `paper` halo outside. No fill.
void paintTweaked(Canvas canvas, Rect rect, PinPointTokens tokens) {
  _ring(canvas, rect.inflate(1), 1, tokens.paper);
  final mark = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = tokens.edit;
  canvas.drawPath(
    dashPath(Path()..addRect(rect.deflate(0.75)), const [1.5, 1.5]),
    mark,
  );
}

/// The agent's flash: a double ring around [rect], 2 px `accent` inside the
/// edge, 1 px `paper`, 3 px `accent`, 1 px `paper`. [opacity] (0 to 1) fades
/// the whole mark; the rings never overlap, so it fades evenly.
void paintAgentFlash(
  Canvas canvas,
  Rect rect,
  PinPointTokens tokens,
  double opacity,
) {
  Color faded(Color color) => color.withValues(alpha: color.a * opacity);
  _ring(canvas, rect.inflate(5), 1, faded(tokens.paper));
  _ring(canvas, rect.inflate(4), 3, faded(tokens.accent));
  _ring(canvas, rect.inflate(1), 1, faded(tokens.paper));
  _ring(canvas, rect, 2, faded(tokens.accent));
}
