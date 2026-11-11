import 'package:flutter/rendering.dart';

import '../widget_info.dart';
import 'align_extractor.dart';

/// Alignment and fit of a `RenderStack`: `Stack`, `IndexedStack`.
InfoSection? stackSection(RenderObject renderObject) {
  if (renderObject is! RenderStack) return null;
  final stack = renderObject;
  final alignment = stack.alignment.resolve(
    stack.textDirection ?? TextDirection.ltr,
  );
  return InfoSection(
    title: 'Stack',
    properties: [
      InfoProperty<Alignment>(
        name: 'alignment',
        value: alignment,
        label: stack.alignment.toString(),
        apply: (v) => stack.alignment = v,
        editor: const ChoiceEditor<Alignment>(namedAlignments, alignmentLabel),
      ),
      InfoProperty<StackFit>(
        name: 'fit',
        value: stack.fit,
        label: stack.fit.name,
        apply: (v) => stack.fit = v,
        editor: const ChoiceEditor<StackFit>(StackFit.values, _name),
      ),
    ],
  );
}

/// The offsets and size a `Positioned` sets on a child of a `RenderStack`.
/// The parent keeps them on the child, so each change relayouts the
/// parent.
InfoSection? positionedSection(RenderObject renderObject) {
  final data = renderObject.parentData;
  final parent = renderObject.parent;
  if (data is! StackParentData || parent is! RenderStack) return null;
  InfoProperty<double?> edge(
    String name,
    double? value,
    void Function(double? v) set,
  ) => InfoProperty<double?>(
    name: name,
    value: value,
    label: value == null ? 'none' : formatPrecise(value),
    apply: (v) {
      set(v);
      parent.markNeedsLayout();
    },
    editor: const NumberEditor(nullable: true, spacing: true),
  );
  return InfoSection(
    title: 'Positioned',
    properties: [
      edge('left', data.left, (v) => data.left = v),
      edge('top', data.top, (v) => data.top = v),
      edge('right', data.right, (v) => data.right = v),
      edge('bottom', data.bottom, (v) => data.bottom = v),
      edge('width', data.width, (v) => data.width = v),
      edge('height', data.height, (v) => data.height = v),
    ],
  );
}

String _name(Enum value) => value.name;
