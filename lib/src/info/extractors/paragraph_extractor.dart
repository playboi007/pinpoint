import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// Text content, font size, weight and color of a `RenderParagraph`.
InfoSection? paragraphSection(RenderObject renderObject) {
  if (renderObject is! RenderParagraph) return null;
  final span = renderObject.text;
  final style = _styleOfFirstText(span, null) ?? span.style;
  final fontSize = style?.fontSize ?? _defaultFontSize;
  final weight = style?.fontWeight ?? FontWeight.normal;
  final color = style?.color;
  return InfoSection(
    title: 'Text',
    properties: [
      InfoProperty<String>(
        name: 'text',
        value: span.toPlainText(),
        label: truncateText(span.toPlainText()),
      ),
      InfoProperty<double>(
        name: 'fontSize',
        value: fontSize,
        label: fontSize.toStringAsFixed(1),
      ),
      InfoProperty<FontWeight>(
        name: 'fontWeight',
        value: weight,
        label: weightLabel(weight),
      ),
      if (color != null)
        InfoProperty<Color>(
          name: 'color',
          value: color,
          label: formatColor(color),
        ),
    ],
  );
}

/// The engine's font size when no style sets one.
const double _defaultFontSize = 14;

/// For example `w700 (Bold)`.
String weightLabel(FontWeight weight) {
  final name = switch (weight.value) {
    100 => 'Thin',
    200 => 'ExtraLight',
    300 => 'Light',
    400 => 'Regular',
    500 => 'Medium',
    600 => 'SemiBold',
    700 => 'Bold',
    800 => 'ExtraBold',
    900 => 'Black',
    _ => null,
  };
  return name == null ? 'w${weight.value}' : 'w${weight.value} ($name)';
}

/// The style the first visible text is drawn with: every style on the way
/// down to the first span with text, merged.
///
/// The root span's style can be null (a bare `RichText`), and a span's style
/// can set only some fields, so taking the first non-null style alone could
/// miss an inherited font size.
TextStyle? _styleOfFirstText(InlineSpan span, TextStyle? inherited) {
  final own = span.style;
  final style = inherited == null
      ? own
      : (own == null ? inherited : inherited.merge(own));
  if (span is! TextSpan) return null;
  if (span.text?.isNotEmpty ?? false) return style;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final found = _styleOfFirstText(child, style);
    if (found != null) return found;
  }
  return null;
}
