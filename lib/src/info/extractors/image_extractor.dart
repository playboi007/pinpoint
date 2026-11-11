import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// How a `RenderImage` fits its box: `Image`, `RawImage`.
InfoSection? imageSection(RenderObject renderObject) {
  if (renderObject is! RenderImage) return null;
  final image = renderObject;
  return InfoSection(
    title: 'Image',
    properties: [
      InfoProperty<BoxFit?>(
        name: 'fit',
        value: image.fit,
        label: _fitLabel(image.fit),
        apply: (v) => image.fit = v,
        editor: const ChoiceEditor<BoxFit?>(_fits, _fitLabel),
      ),
    ],
  );
}

/// Null first: no fit, the image's own rules.
const List<BoxFit?> _fits = [null, ...BoxFit.values];

String _fitLabel(BoxFit? fit) => fit?.name ?? 'none';
