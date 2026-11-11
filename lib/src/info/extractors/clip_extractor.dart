import 'package:flutter/rendering.dart';

import '../widget_info.dart';
import 'decoration_extractor.dart' show radiusLabel;

/// The corner radius of a `RenderClipRRect`: `ClipRRect`. Editable when
/// every corner is the same circle.
InfoSection? clipSection(RenderObject renderObject) {
  if (renderObject is! RenderClipRRect) return null;
  final clip = renderObject;
  final radius = clip.borderRadius.resolve(
    clip.textDirection ?? TextDirection.ltr,
  );
  final corners = [
    radius.topLeft,
    radius.topRight,
    radius.bottomRight,
    radius.bottomLeft,
  ];
  final uniform =
      radius.topLeft.x == radius.topLeft.y &&
      corners.every((c) => c == radius.topLeft);
  return InfoSection(
    title: 'Clip',
    properties: [
      InfoProperty<BorderRadius>(
        name: 'borderRadius',
        value: radius,
        label: radiusLabel(radius),
        apply: uniform ? (v) => clip.borderRadius = v : null,
        editor: uniform ? const RadiusEditor() : null,
        note: uniform ? null : 'Corners differ; change it in source.',
      ),
    ],
  );
}
