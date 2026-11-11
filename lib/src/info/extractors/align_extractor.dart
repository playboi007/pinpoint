import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// The nine named alignments, for the Tweak tab's menu.
const List<Alignment> namedAlignments = [
  Alignment.topLeft,
  Alignment.topCenter,
  Alignment.topRight,
  Alignment.centerLeft,
  Alignment.center,
  Alignment.centerRight,
  Alignment.bottomLeft,
  Alignment.bottomCenter,
  Alignment.bottomRight,
];

/// `topLeft` for a named alignment, else `Alignment(0.3, 0.0)`.
String alignmentLabel(Alignment a) =>
    a.toString().replaceFirst(RegExp(r'^Alignment\.'), '');

/// Alignment and size factors of a `RenderPositionedBox`: `Align`,
/// `Center`, `Container(alignment:)`.
InfoSection? alignSection(RenderObject renderObject) {
  if (renderObject is! RenderPositionedBox) return null;
  final box = renderObject;
  final alignment = box.alignment.resolve(
    box.textDirection ?? TextDirection.ltr,
  );
  return InfoSection(
    title: 'Align',
    properties: [
      InfoProperty<Alignment>(
        name: 'alignment',
        value: alignment,
        // As written, so `AlignmentDirectional` stays directional.
        label: box.alignment.toString(),
        apply: (v) => box.alignment = v,
        editor: const ChoiceEditor<Alignment>(namedAlignments, alignmentLabel),
      ),
      InfoProperty<double?>(
        name: 'widthFactor',
        value: box.widthFactor,
        label: _orNone(box.widthFactor),
        apply: (v) => box.widthFactor = v,
        editor: const NumberEditor(min: 0, step: 0.1, nullable: true),
      ),
      InfoProperty<double?>(
        name: 'heightFactor',
        value: box.heightFactor,
        label: _orNone(box.heightFactor),
        apply: (v) => box.heightFactor = v,
        editor: const NumberEditor(min: 0, step: 0.1, nullable: true),
      ),
    ],
  );
}

String _orNone(double? v) => v == null ? 'none' : formatPrecise(v);
