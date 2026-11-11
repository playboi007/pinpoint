import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The opacity of a `RenderOpacity`: `Opacity`.
InfoSection? opacitySection(RenderObject renderObject) {
  if (renderObject is! RenderOpacity) return null;
  final box = renderObject;
  return InfoSection(
    title: 'Opacity',
    properties: [
      InfoProperty<double>(
        name: 'opacity',
        value: box.opacity,
        label: formatPrecise(box.opacity),
        apply: (v) => box.opacity = v,
        editor: const NumberEditor(min: 0, max: 1, step: 0.1),
      ),
    ],
  );
}
