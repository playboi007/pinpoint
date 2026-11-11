import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../search/render_search.dart';
import 'extractors/align_extractor.dart';
import 'extractors/constrained_box_extractor.dart';
import 'extractors/decoration_extractor.dart';
import 'extractors/flex_extractor.dart';
import 'extractors/padding_extractor.dart';
import 'extractors/paragraph_extractor.dart';

/// Reads one section of [WidgetInfo] from a render object, or returns null
/// when the render object is not of its type.
typedef InfoExtractor = InfoSection? Function(RenderObject renderObject);

/// How the Tweak tab edits a property (Milestone 11).
sealed class PropertyEditor {
  const PropertyEditor();
}

/// A number field with a stepper. Arrow keys nudge the focused field.
class NumberEditor extends PropertyEditor {
  const NumberEditor({
    this.min,
    this.max,
    this.step = 1,
    this.integer = false,
    this.nullable = false,
    this.spacing = false,
  });

  final double? min;
  final double? max;

  /// What one stepper click adds. [spacing] editors use the tab's step
  /// (1, 4 or 8) instead.
  final double step;

  /// Whole numbers only; the value is an `int`.
  final bool integer;

  /// An empty field means null, for example `maxLines` with no limit.
  final bool nullable;

  /// A length in logical pixels, stepped by the tab's 1, 4 or 8.
  final bool spacing;
}

/// A list of named values, for enums and named alignments.
class ChoiceEditor<T> extends PropertyEditor {
  const ChoiceEditor(this.choices, this._labelOf);

  final List<T> choices;
  final String Function(T value) _labelOf;

  /// [value]'s name in the list. Through a method, not the field: read as
  /// `ChoiceEditor<Object?>`, the field's function type would fail its
  /// runtime check.
  String labelOf(Object? value) => _labelOf(value as T);
}

/// A hex field with a swatch. The value is a `Color`.
class ColorEditor extends PropertyEditor {
  const ColorEditor();
}

/// Four linked fields. The value is an `EdgeInsets`.
class InsetsEditor extends PropertyEditor {
  const InsetsEditor();
}

/// Minimum and maximum width and height. The value is a `BoxConstraints`.
class ConstraintsEditor extends PropertyEditor {
  const ConstraintsEditor();
}

/// One radius for every corner. The value is a `BorderRadius`.
class RadiusEditor extends PropertyEditor {
  const RadiusEditor();
}

/// Width and color of a border that is the same on every side. The value is
/// a `Border`.
class BorderEditor extends PropertyEditor {
  const BorderEditor();
}

/// One named value of a picked widget.
///
/// [apply] closes over the render object, so a property is never
/// serialized; [toJson] emits [name] and [label] only.
@immutable
class InfoProperty<T> {
  const InfoProperty({
    required this.name,
    required this.value,
    required this.label,
    this.apply,
    this.editor,
    this.note,
  });

  /// For example `fontSize`.
  final String name;

  final T value;

  /// For example `16.0`, `#FF3B30`, `w700 (Bold)`.
  final String label;

  /// Null means read-only. Set for the properties the Tweak tab edits; it
  /// writes the render object's own setter, which relayouts or repaints.
  ///
  /// Call it from an input handler or a post-frame callback only: a render
  /// object asserts when it is changed during layout or paint.
  final void Function(T value)? apply;

  /// How the Tweak tab edits [value]. Null with [apply] null.
  final PropertyEditor? editor;

  /// Why the property is read-only, or what to know before editing it.
  final String? note;

  /// Whether the Tweak tab can edit this property.
  bool get editable => apply != null && editor != null;

  /// Calls [apply] with [newValue]. Through a method, not the field: read
  /// as `InfoProperty<Object?>`, the field's function type would fail its
  /// runtime check.
  void applyValue(Object? newValue) => apply!(newValue as T);

  Map<String, Object?> toJson() => {'name': name, 'label': label};
}

/// A titled group of properties, for example "Text" or "Decoration".
@immutable
class InfoSection {
  const InfoSection({required this.title, required this.properties});

  final String title;
  final List<InfoProperty<Object?>> properties;

  Map<String, Object?> toJson() => {
    'title': title,
    'properties': [for (final p in properties) p.toJson()],
  };
}

/// A live snapshot of a picked render object: geometry plus typed
/// properties in sections.
///
/// The per-type fields are sections, not nullable fields, so each new
/// render type adds an extractor instead of more fields.
@immutable
class WidgetInfo {
  const WidgetInfo({
    required this.renderType,
    required this.size,
    required this.globalPosition,
    required this.constraints,
    required this.depth,
    required this.sections,
  });

  /// Reads geometry from [renderObject], then runs every extractor in
  /// [extractors]. An extractor that throws is skipped.
  ///
  /// [renderObject] must be laid out.
  factory WidgetInfo.fromRenderObject(
    RenderObject renderObject, {
    List<InfoExtractor> extractors = defaultExtractors,
  }) {
    final rect = RenderSearch.globalRectOf(renderObject);
    // Slivers have no RenderBox size; their paint bounds give one.
    final size = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.size
        : renderObject.paintBounds.size;
    return WidgetInfo(
      renderType: renderObject.runtimeType.toString(),
      size: size,
      globalPosition: rect?.topLeft ?? Offset.zero,
      constraints: constraintsOf(renderObject),
      depth: renderObject.depth,
      sections: [
        for (final extract in extractors) ?_tryExtract(extract, renderObject),
      ],
    );
  }

  /// One extractor per render type.
  static const List<InfoExtractor> renderExtractors = [
    paragraphSection,
    paddingSection,
    constrainedBoxSection,
    decorationSection,
    coloredBoxSection,
    flexSection,
    alignSection,
  ];

  /// Values a parent keeps on its child, read from the child.
  static const List<InfoExtractor> parentDataExtractors = [flexChildSection];

  /// Every extractor: [renderExtractors], then [parentDataExtractors].
  static const List<InfoExtractor> defaultExtractors = [
    ...renderExtractors,
    ...parentDataExtractors,
  ];

  /// Longest text shown in a label. Longer text is cut and ends in "…".
  static const int maxTextLength = 200;

  /// For example `RenderParagraph`.
  final String renderType;

  /// Logical pixels, in the render object's own space (before any scale).
  final Size size;

  /// Top-left in global logical pixels.
  final Offset globalPosition;

  /// `BoxConstraints` for boxes, `SliverConstraints` for slivers, null for
  /// any other kind of render object.
  final Constraints? constraints;

  /// Depth in the render tree.
  final int depth;

  final List<InfoSection> sections;

  Rect get globalRect => globalPosition & size;

  /// For example `320.0 x 48.0`.
  String get sizeLabel => formatSize(size);

  /// For example `(12.0, 80.5)`.
  String get positionLabel =>
      '(${globalPosition.dx.toStringAsFixed(1)}, '
      '${globalPosition.dy.toStringAsFixed(1)})';

  /// For example `tight 320 x 48`, `w 0-320, h 48`, or
  /// `sliver down, offset 120, remaining 600, cross 400`.
  String get constraintsLabel => describeConstraints(constraints);

  /// [constraints] as [constraintsLabel] writes them.
  static String describeConstraints(Constraints? constraints) =>
      switch (constraints) {
        final BoxConstraints c when c.isTight =>
          'tight ${_n(c.maxWidth)} x ${_n(c.maxHeight)}',
        final BoxConstraints c =>
          'w ${_range(c.minWidth, c.maxWidth)}, '
              'h ${_range(c.minHeight, c.maxHeight)}',
        final SliverConstraints c =>
          'sliver ${c.axisDirection.name}, offset ${_n(c.scrollOffset)}, '
              'remaining ${_n(c.remainingPaintExtent)}, '
              'cross ${_n(c.crossAxisExtent)}',
        null => 'unknown',
        final other => other.toString(),
      };

  /// Names and labels only. Nothing that holds a render object.
  Map<String, Object?> toJson() => {
    'renderType': renderType,
    'size': sizeLabel,
    'position': positionLabel,
    'constraints': constraintsLabel,
    'depth': depth,
    'sections': [for (final s in sections) s.toJson()],
  };

  static InfoSection? _tryExtract(InfoExtractor extract, RenderObject ro) {
    try {
      return extract(ro);
    } catch (_) {
      return null;
    }
  }

  static String _range(double min, double max) =>
      min == max ? _n(min) : '${_n(min)}-${_n(max)}';

  static String _n(double v) => formatNumber(v);
}

/// The constraints [renderObject] was last laid out with, or null when it
/// is neither a box nor a sliver.
///
/// `RenderObject.constraints` is `@protected`; the `RenderBox` and
/// `RenderSliver` overrides are not.
Constraints? constraintsOf(RenderObject renderObject) => switch (renderObject) {
  final RenderBox box => box.constraints,
  final RenderSliver sliver => sliver.constraints,
  _ => null,
};

/// `320` for whole numbers, `12.5` otherwise, `∞` for infinity.
String formatNumber(double v) {
  if (v.isInfinite) return v.isNegative ? '-∞' : '∞';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Up to three decimals, without trailing zeros: `1.43`, `16`, `0.1`.
/// For values where one decimal would hide a difference (line height).
String formatPrecise(double v) {
  if (!v.isFinite) return formatNumber(v);
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// For example `320.0 x 48.0`.
String formatSize(Size size) =>
    '${size.width.toStringAsFixed(1)} x ${size.height.toStringAsFixed(1)}';

/// `#RRGGBB`, or `#AARRGGBB` when not opaque.
String formatColor(Color color) {
  final argb = color.toARGB32();
  final alpha = argb >> 24;
  final hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
  return alpha == 0xFF ? '#${hex.substring(2)}' : '#$hex';
}

/// [text] cut to [WidgetInfo.maxTextLength] characters, ending in "…" when
/// cut. Milestone 4 truncates again on the way out of the app (engineering
/// rule 9); this keeps the panel readable.
String truncateText(String text) => text.length <= WidgetInfo.maxTextLength
    ? text
    : '${text.substring(0, WidgetInfo.maxTextLength)}…';
