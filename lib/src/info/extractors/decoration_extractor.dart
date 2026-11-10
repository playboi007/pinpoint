import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../widget_info.dart';

/// Background color, border radius and border of a `RenderDecoratedBox`
/// with a `BoxDecoration`. Each is editable: a copy of the decoration with
/// the new value.
///
/// `Container(color: ...)` builds a `ColoredBox`, not a `DecoratedBox`, so
/// it is not covered here; see [coloredBoxSection].
InfoSection? decorationSection(RenderObject renderObject) {
  if (renderObject is! RenderDecoratedBox) return null;
  final decoration = renderObject.decoration;
  if (decoration is! BoxDecoration) return null;
  final color = decoration.color;
  final radius = decoration.borderRadius?.resolve(
    renderObject.configuration.textDirection ?? TextDirection.ltr,
  );
  final border = decoration.border;
  void set(BoxDecoration Function(BoxDecoration d) change) {
    // Read again: another tweak may have changed it since this section was
    // read.
    final current = renderObject.decoration;
    if (current is BoxDecoration) renderObject.decoration = change(current);
  }

  // One radius for every corner only: an edit would flatten a radius that
  // differs per corner.
  final uniformRadius =
      radius != null &&
      radius.topLeft.x == radius.topLeft.y &&
      radiusLabel(radius) == _corner(radius.topLeft);
  final uniformBorder = border is Border && border.isUniform;
  return InfoSection(
    title: 'Decoration',
    properties: [
      if (color != null)
        InfoProperty<Color>(
          name: 'color',
          value: color,
          label: formatColor(color),
          apply: (v) => set((d) => d.copyWith(color: v)),
          editor: const ColorEditor(),
        ),
      if (radius != null)
        InfoProperty<BorderRadius>(
          name: 'borderRadius',
          value: radius,
          label: radiusLabel(radius),
          apply: uniformRadius
              ? (v) => set((d) => d.copyWith(borderRadius: v))
              : null,
          editor: uniformRadius ? const RadiusEditor() : null,
          note: uniformRadius ? null : 'Corners differ; change it in source.',
        ),
      if (border != null)
        InfoProperty<BoxBorder>(
          name: 'border',
          value: border,
          label: borderLabel(border),
          apply: uniformBorder
              ? (v) => set((d) => d.copyWith(border: v))
              : null,
          editor: uniformBorder ? const BorderEditor() : null,
          note: uniformBorder ? null : 'Sides differ; change it in source.',
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

/// The color of a `ColoredBox`, which `Container(color: ...)` builds,
/// read-only.
///
/// Its render object is private to the framework (`_RenderColoredBox`), so
/// there is no setter to call. The color is read from the widget that owns
/// it, in debug only. Read-only in v1, and the panel says so.
InfoSection? coloredBoxSection(RenderObject renderObject) {
  final creator = renderObject.debugCreator;
  if (creator is! DebugCreator) return null;
  final widget = creator.element.widget;
  if (widget is! ColoredBox) return null;
  return InfoSection(
    title: 'Color',
    properties: [
      InfoProperty<Color>(
        name: 'color',
        value: widget.color,
        label: formatColor(widget.color),
        note:
            'Container(color:) paints with a private render object, so '
            'its color cannot be tweaked. Use decoration: BoxDecoration(...) '
            'in source to make it editable.',
      ),
    ],
  );
}

/// `8.0` when every corner is the same circle, else each corner.
String radiusLabel(BorderRadius r) {
  final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
  if (corners.every((c) => c == r.topLeft)) return _corner(r.topLeft);
  return 'tl ${_corner(r.topLeft)}, tr ${_corner(r.topRight)}, '
      'br ${_corner(r.bottomRight)}, bl ${_corner(r.bottomLeft)}';
}

String _corner(Radius c) => c.x == c.y
    ? c.x.toStringAsFixed(1)
    : '${c.x.toStringAsFixed(1)}/${c.y.toStringAsFixed(1)}';

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
