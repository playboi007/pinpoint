import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The gaps of a `RenderWrap`: `Wrap`.
InfoSection? wrapSection(RenderObject renderObject) {
  if (renderObject is! RenderWrap) return null;
  final wrap = renderObject;
  return InfoSection(
    title: 'Wrap',
    properties: [
      InfoProperty<double>(
        name: 'spacing',
        value: wrap.spacing,
        label: formatNumber(wrap.spacing),
        apply: (v) => wrap.spacing = v,
        editor: const NumberEditor(min: 0, spacing: true),
      ),
      InfoProperty<double>(
        name: 'runSpacing',
        value: wrap.runSpacing,
        label: formatNumber(wrap.runSpacing),
        apply: (v) => wrap.runSpacing = v,
        editor: const NumberEditor(min: 0, spacing: true),
      ),
    ],
  );
}
