import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The ratio of a `RenderAspectRatio`: `AspectRatio`.
InfoSection? aspectRatioSection(RenderObject renderObject) {
  if (renderObject is! RenderAspectRatio) return null;
  final box = renderObject;
  return InfoSection(
    title: 'Aspect ratio',
    properties: [
      InfoProperty<double>(
        name: 'aspectRatio',
        value: box.aspectRatio,
        label: formatPrecise(box.aspectRatio),
        apply: (v) => box.aspectRatio = v,
        // The setter asserts a finite ratio above zero.
        editor: const NumberEditor(min: 0.01, max: 100, step: 0.1),
      ),
    ],
  );
}
