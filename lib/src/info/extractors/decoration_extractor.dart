import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// Background color, border radius and border of a `RenderDecoratedBox`
/// with a `BoxDecoration`.
///
/// `Container(color: ...)` builds a `ColoredBox`, not a `DecoratedBox`, so
/// it is not covered here.
InfoSection? decorationSection(RenderObject renderObject) {
  if (renderObject is! RenderDecoratedBox) return null;
  final decoration = renderObject.decoration;
  if (decoration is! BoxDecoration) return null;
  final color = decoration.color;
  final radius = decoration.borderRadius?.resolve(
    renderObject.configuration.textDirection ?? TextDirection.ltr,
  );
  final border = decoration.border;
  return InfoSection(
    title: 'Decoration',
    properties: [
      if (color != null)
        InfoProperty<Color>(
          name: 'color',
          value: color,
          label: formatColor(color),
        ),
      if (radius != null)
        InfoProperty<BorderRadius>(
          name: 'borderRadius',
          value: radius,
          label: radiusLabel(radius),
        ),
      if (border != null)
        InfoProperty<BoxBorder>(
          name: 'border',
          value: border,
          label: borderLabel(border),
        ),
      if (decoration.shape == BoxShape.circle)
        const InfoProperty<BoxShape>(
          name: 'shape',
          value: BoxShape.circle,
          label: 'circle',
        ),
    ],
  );
}

/// `8.0` when every corner is the same circle, else each corner.
String radiusLabel(BorderRadius r) {
  String corner(Radius c) => c.x == c.y
      ? c.x.toStringAsFixed(1)
      : '${c.x.toStringAsFixed(1)}/${c.y.toStringAsFixed(1)}';
  final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
  if (corners.every((c) => c == r.topLeft)) return corner(r.topLeft);
  return 'tl ${corner(r.topLeft)}, tr ${corner(r.topRight)}, '
      'br ${corner(r.bottomRight)}, bl ${corner(r.bottomLeft)}';
}

/// `2.0 #0000FF` when every side is the same, else each visible side.
String borderLabel(BoxBorder border) {
  String side(BorderSide s) =>
      '${s.width.toStringAsFixed(1)} ${formatColor(s.color)}';
  final sides = switch (border) {
    final Border b => {
      'top': b.top,
      'right': b.right,
      'bottom': b.bottom,
      'left': b.left,
    },
    final BorderDirectional b => {
      'top': b.top,
      'end': b.end,
      'bottom': b.bottom,
      'start': b.start,
    },
    _ => null,
  };
  if (sides == null) return border.toString();
  if (border.isUniform) {
    return border.top.style == BorderStyle.none ? 'none' : side(border.top);
  }
  return [
    for (final MapEntry(key: name, value: s) in sides.entries)
      if (s.style != BorderStyle.none) '$name ${side(s)}',
  ].join(', ');
}
