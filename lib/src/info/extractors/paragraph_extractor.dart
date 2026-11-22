import 'package:flutter/rendering.dart';

import '../widget_info.dart';

/// Text content and style of a `RenderParagraph`.
///
/// The style values are editable through the root span: a new root
/// `TextSpan` with the same text and children and a changed style. A child
/// span that sets the value itself keeps it, so such a value is read-only
/// here: a change to the root would not show.
InfoSection? paragraphSection(RenderObject renderObject) {
  if (renderObject is! RenderParagraph) return null;
  final text = _ParagraphText(renderObject);
  final plain = renderObject.text.toPlainText();
  return InfoSection(
    title: 'Text',
    properties: [
      InfoProperty<String>(
        name: 'text',
        value: plain,
        label: truncateText(plain),
      ),
      text.fontSize(),
      text.fontWeight(),
      if (text.style?.color case final color?) text.color(color),
      text.height(),
      text.letterSpacing(),
      ..._layoutProperties(renderObject),
    ],
  );
}

const _fromChild = 'A child span sets this; change it in source.';

/// The style of a paragraph and the edits of it that reach the root span.
class _ParagraphText {
  _ParagraphText(this.paragraph)
    : root = switch (paragraph.text) {
        final TextSpan span => span,
        _ => null,
      },
      rootStyle = paragraph.text.style,
      style = _styleOfFirstText(paragraph.text, null) ?? paragraph.text.style;

  final RenderParagraph paragraph;
  final TextSpan? root;
  final TextStyle? rootStyle;

  /// The style the first visible text is drawn with.
  final TextStyle? style;

  /// Applies a change to the root span's style, or null when a child span
  /// sets [shown] itself or the root is not a `TextSpan`.
  void Function(T)? _styled<T>(
    Object? shown,
    Object? own,
    TextStyle Function(TextStyle style, T value) change,
  ) {
    final root = this.root;
    if (root == null) return null;
    final fromRoot = own == shown || (own == null && style == rootStyle);
    if (!fromRoot) return null;
    return (value) => paragraph.text = _withRootStyle(
      root,
      change(root.style ?? const TextStyle(), value),
    );
  }

  InfoProperty<double> fontSize() {
    final size = style?.fontSize ?? _defaultFontSize;
    final apply = _styled<double>(
      style?.fontSize,
      rootStyle?.fontSize,
      (s, v) => s.copyWith(fontSize: v),
    );
    return InfoProperty<double>(
      name: 'fontSize',
      value: size,
      label: size.toStringAsFixed(1),
      apply: apply,
      editor: const NumberEditor(min: 1, max: 400),
      note: apply == null ? _fromChild : null,
    );
  }

  InfoProperty<FontWeight> fontWeight() {
    final weight = style?.fontWeight ?? FontWeight.normal;
    final apply = _styled<FontWeight>(
      style?.fontWeight,
      rootStyle?.fontWeight,
      (s, v) => s.copyWith(fontWeight: v),
    );
    return InfoProperty<FontWeight>(
      name: 'fontWeight',
      value: weight,
      label: weightLabel(weight),
      apply: apply,
      editor: const ChoiceEditor<FontWeight>(FontWeight.values, weightLabel),
      note: apply == null ? _fromChild : null,
    );
  }

  InfoProperty<Color> color(Color color) {
    final apply = _styled<Color>(
      color,
      rootStyle?.color,
      (s, v) => s.copyWith(color: v),
    );
    return InfoProperty<Color>(
      name: 'color',
      value: color,
      label: formatColor(color),
      apply: apply,
      editor: const ColorEditor(),
      note: apply == null ? _fromChild : null,
    );
  }

  InfoProperty<double?> height() {
    final apply = _styled<double?>(
      style?.height,
      rootStyle?.height,
      (s, v) => v == null ? _withoutHeight(s) : s.copyWith(height: v),
    );
    return InfoProperty<double?>(
      name: 'height',
      value: style?.height,
      label: _orNormal(style?.height),
      apply: apply,
      editor: const NumberEditor(min: 0.1, max: 10, step: 0.1, nullable: true),
      note: apply == null ? _fromChild : null,
    );
  }

  InfoProperty<double?> letterSpacing() {
    final apply = _styled<double?>(
      style?.letterSpacing,
      rootStyle?.letterSpacing,
      (s, v) =>
          v == null ? _withoutLetterSpacing(s) : s.copyWith(letterSpacing: v),
    );
    return InfoProperty<double?>(
      name: 'letterSpacing',
      value: style?.letterSpacing,
      label: _orNormal(style?.letterSpacing),
      apply: apply,
      editor: const NumberEditor(step: 0.5, nullable: true),
      note: apply == null ? _fromChild : null,
    );
  }
}

/// Alignment, line limit and overflow: set on the render object itself.
List<InfoProperty<Object?>> _layoutProperties(RenderParagraph paragraph) => [
  InfoProperty<TextAlign>(
    name: 'textAlign',
    value: paragraph.textAlign,
    label: paragraph.textAlign.name,
    apply: (v) => paragraph.textAlign = v,
    editor: const ChoiceEditor<TextAlign>(TextAlign.values, _name),
  ),
  InfoProperty<int?>(
    name: 'maxLines',
    value: paragraph.maxLines,
    label: paragraph.maxLines?.toString() ?? 'none',
    apply: (v) => paragraph.maxLines = v,
    editor: const NumberEditor(min: 1, integer: true, nullable: true),
  ),
  InfoProperty<TextOverflow>(
    name: 'overflow',
    value: paragraph.overflow,
    label: paragraph.overflow.name,
    apply: (v) => paragraph.overflow = v,
    editor: const ChoiceEditor<TextOverflow>(TextOverflow.values, _name),
  ),
];

String _name(Enum value) => value.name;

String _orNormal(double? value) =>
    value == null ? 'normal' : formatPrecise(value);

/// [root] with [style], everything else kept: the text, the children and
/// their own styles, the recognizer and the semantics.
TextSpan _withRootStyle(TextSpan root, TextStyle style) => TextSpan(
  text: root.text,
  children: root.children,
  style: style,
  recognizer: root.recognizer,
  mouseCursor: root.mouseCursor,
  onEnter: root.onEnter,
  onExit: root.onExit,
  semanticsLabel: root.semanticsLabel,
  semanticsIdentifier: root.semanticsIdentifier,
  locale: root.locale,
  spellOut: root.spellOut,
);

TextStyle _withoutHeight(TextStyle s) => _copyWithout(s, height: true);

TextStyle _withoutLetterSpacing(TextStyle s) =>
    _copyWithout(s, letterSpacing: true);

/// [s] with [height] or [letterSpacing] back to null (inherited, or the
/// font's own). `copyWith` cannot set a field to null.
TextStyle _copyWithout(
  TextStyle s, {
  bool height = false,
  bool letterSpacing = false,
}) => TextStyle(
  inherit: s.inherit,
  color: s.color,
  backgroundColor: s.backgroundColor,
  fontSize: s.fontSize,
  fontWeight: s.fontWeight,
  fontStyle: s.fontStyle,
  letterSpacing: letterSpacing ? null : s.letterSpacing,
  wordSpacing: s.wordSpacing,
  textBaseline: s.textBaseline,
  height: height ? null : s.height,
  leadingDistribution: s.leadingDistribution,
  locale: s.locale,
  foreground: s.foreground,
  background: s.background,
  shadows: s.shadows,
  fontFeatures: s.fontFeatures,
  fontVariations: s.fontVariations,
  decoration: s.decoration,
  decorationColor: s.decorationColor,
  decorationStyle: s.decorationStyle,
  decorationThickness: s.decorationThickness,
  debugLabel: s.debugLabel,
  // Already prefixed with `packages/<name>/` when the style named a
  // package, so no package is passed again.
  fontFamily: s.fontFamily,
  fontFamilyFallback: s.fontFamilyFallback,
  overflow: s.overflow,
);

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
