import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The padding of a `RenderPadding`, which `Padding` and
/// `Container(padding:, margin:)` make. Both `Container` parameters become
/// a `RenderPadding`; the note's `createdBy` and `nearestLocal` say which
/// widget made it, and the agent reads the code for which parameter.
InfoSection? paddingSection(RenderObject renderObject) {
  if (renderObject is! RenderPadding) return null;
  final padding = renderObject.padding;
  final resolved = padding.resolve(
    renderObject.textDirection ?? TextDirection.ltr,
  );
  return InfoSection(
    title: 'Padding',
    properties: [
      InfoProperty<EdgeInsets>(
        name: 'padding',
        value: resolved,
        // As written, so `EdgeInsetsDirectional` stays directional in the
        // note's "from".
        label: padding.toString(),
        apply: (v) => renderObject.padding = v,
        editor: const InsetsEditor(),
      ),
    ],
  );
}
