import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The added constraints of a `RenderConstrainedBox`: `SizedBox`,
/// `ConstrainedBox`, `Container(width:, height:, constraints:)`.
InfoSection? constrainedBoxSection(RenderObject renderObject) {
  if (renderObject is! RenderConstrainedBox) return null;
  final constraints = renderObject.additionalConstraints;
  return InfoSection(
    title: 'Size',
    properties: [
      InfoProperty<BoxConstraints>(
        name: 'additionalConstraints',
        value: constraints,
        label: constraints.toString(),
        apply: (v) => renderObject.additionalConstraints = v,
        editor: const ConstraintsEditor(),
      ),
    ],
  );
}
