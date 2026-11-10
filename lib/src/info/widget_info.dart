import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../search/render_search.dart';
import 'extractors/decoration_extractor.dart';
import 'extractors/paragraph_extractor.dart';

/// Reads one section of [WidgetInfo] from a render object, or returns null
/// when the render object is not of its type.
typedef InfoExtractor = InfoSection? Function(RenderObject renderObject);

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
  });

  /// For example `fontSize`.
  final String name;

  final T value;

  /// For example `16.0`, `#FF3B30`, `w700 (Bold)`.
  final String label;

  /// Null means read-only. Milestone 11 sets it for editable properties.
  final void Function(T value)? apply;

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
  static const List<InfoExtractor> defaultExtractors = [
    paragraphSection,
    decorationSection,
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
  String get constraintsLabel => switch (constraints) {
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

  static String _n(double v) {
    if (v.isInfinite) return '∞';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  }
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
