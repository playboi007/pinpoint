import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// Direction, alignments, main axis size and spacing of a `RenderFlex`:
/// `Row`, `Column`, `Flex`.
InfoSection? flexSection(RenderObject renderObject) {
  if (renderObject is! RenderFlex) return null;
  final flex = renderObject;
  return InfoSection(
    title: 'Flex',
    properties: [
      InfoProperty<Axis>(
        name: 'direction',
        value: flex.direction,
        label: flex.direction.name,
        apply: (v) => flex.direction = v,
        editor: const ChoiceEditor<Axis>(Axis.values, _name),
      ),
      InfoProperty<MainAxisAlignment>(
        name: 'mainAxisAlignment',
        value: flex.mainAxisAlignment,
        label: flex.mainAxisAlignment.name,
        apply: (v) => flex.mainAxisAlignment = v,
        editor: const ChoiceEditor<MainAxisAlignment>(
          MainAxisAlignment.values,
          _name,
        ),
      ),
      InfoProperty<CrossAxisAlignment>(
        name: 'crossAxisAlignment',
        value: flex.crossAxisAlignment,
        label: flex.crossAxisAlignment.name,
        apply: (v) => flex.crossAxisAlignment = v,
        // Baseline asserts without a text baseline.
        editor: ChoiceEditor<CrossAxisAlignment>([
          for (final a in CrossAxisAlignment.values)
            if (a != CrossAxisAlignment.baseline || flex.textBaseline != null)
              a,
        ], _name),
      ),
      InfoProperty<MainAxisSize>(
        name: 'mainAxisSize',
        value: flex.mainAxisSize,
        label: flex.mainAxisSize.name,
        apply: (v) => flex.mainAxisSize = v,
        editor: const ChoiceEditor<MainAxisSize>(MainAxisSize.values, _name),
      ),
      InfoProperty<double>(
        name: 'spacing',
        value: flex.spacing,
        label: formatNumber(flex.spacing),
        apply: (v) => flex.spacing = v,
        editor: const NumberEditor(min: 0, spacing: true),
      ),
    ],
  );
}

/// Flex factor and fit of a child of a `RenderFlex`, which `Expanded` and
/// `Flexible` set. The parent keeps them on the child, so each change
/// relayouts the parent.
InfoSection? flexChildSection(RenderObject renderObject) {
  final data = renderObject.parentData;
  final parent = renderObject.parent;
  if (data is! FlexParentData || parent is! RenderFlex) return null;
  void set(void Function(FlexParentData data) change) {
    change(data);
    parent.markNeedsLayout();
  }

  final fit = data.fit ?? FlexFit.tight;
  return InfoSection(
    title: 'Flex child',
    properties: [
      InfoProperty<int?>(
        name: 'flex',
        value: data.flex,
        label: data.flex?.toString() ?? 'none',
        apply: (v) => set((d) => d.flex = v),
        editor: const NumberEditor(min: 0, integer: true, nullable: true),
      ),
      InfoProperty<FlexFit>(
        name: 'fit',
        value: fit,
        label: fit.name,
        apply: (v) => set((d) => d.fit = v),
        editor: const ChoiceEditor<FlexFit>(FlexFit.values, _name),
      ),
    ],
  );
}

String _name(Enum value) => value.name;
