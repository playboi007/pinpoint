import 'package:flutter/material.dart';

/// Supported HTML element types that can be added to the [HtmlElementView] canvas.
enum HtmlElementKind {
  heading,
  paragraph,
  button,
  input,
  card,
  badge,
  link,
  checkbox,
  image,
  divider,
}

/// Metadata describing a component in the Add palette.
class HtmlElementTemplate {
  const HtmlElementTemplate({
    required this.kind,
    required this.label,
    required this.tag,
    required this.description,
    required this.defaultText,
    required this.defaultAccentHex,
    required this.defaultFontSize,
    required this.defaultWidth,
    required this.defaultHeight,
    required this.icon,
  });

  final HtmlElementKind kind;
  final String label;
  final String tag;
  final String description;
  final String defaultText;
  final String defaultAccentHex;
  final double defaultFontSize;
  final double defaultWidth;
  final double defaultHeight;
  final IconData icon;
}

/// Accent swatches available in the element inspector.
const List<({String name, String hex, Color color})> htmlAccentSwatches = [
  (name: 'Indigo', hex: '#6366f1', color: Color(0xFF6366F1)),
  (name: 'Sky', hex: '#0ea5e9', color: Color(0xFF0EA5E9)),
  (name: 'Emerald', hex: '#10b981', color: Color(0xFF10B981)),
  (name: 'Amber', hex: '#f59e0b', color: Color(0xFFF59E0B)),
  (name: 'Rose', hex: '#f43f5e', color: Color(0xFFF43F5E)),
  (name: 'Slate', hex: '#64748b', color: Color(0xFF64748B)),
];

/// Catalog of HTML components shown when the user opens the Add palette.
const List<HtmlElementTemplate> htmlElementTemplates = [
  HtmlElementTemplate(
    kind: HtmlElementKind.heading,
    label: 'Heading',
    tag: '<h1>',
    description: 'Large section title',
    defaultText: 'HTML Heading',
    defaultAccentHex: '#6366f1',
    defaultFontSize: 22,
    defaultWidth: 220,
    defaultHeight: 58,
    icon: Icons.title,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.paragraph,
    label: 'Paragraph',
    tag: '<p>',
    description: 'Body text block',
    defaultText: 'Plain HTML paragraph inside HtmlElementView.',
    defaultAccentHex: '#64748b',
    defaultFontSize: 13,
    defaultWidth: 240,
    defaultHeight: 74,
    icon: Icons.notes,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.button,
    label: 'Button',
    tag: '<button>',
    description: 'Interactive HTML button',
    defaultText: 'HTML Button',
    defaultAccentHex: '#6366f1',
    defaultFontSize: 13,
    defaultWidth: 164,
    defaultHeight: 54,
    icon: Icons.smart_button,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.input,
    label: 'Text Input',
    tag: '<input>',
    description: 'Editable HTML field',
    defaultText: 'Type HTML input...',
    defaultAccentHex: '#0ea5e9',
    defaultFontSize: 13,
    defaultWidth: 220,
    defaultHeight: 58,
    icon: Icons.input,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.card,
    label: 'Card',
    tag: '<div>',
    description: 'Styled container box',
    defaultText: 'Plain HTML element',
    defaultAccentHex: '#f59e0b',
    defaultFontSize: 14,
    defaultWidth: 230,
    defaultHeight: 108,
    icon: Icons.crop_landscape,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.badge,
    label: 'Badge',
    tag: '<span>',
    description: 'Compact pill tag',
    defaultText: 'HTML5 BADGE',
    defaultAccentHex: '#0ea5e9',
    defaultFontSize: 11,
    defaultWidth: 136,
    defaultHeight: 46,
    icon: Icons.label_outline,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.link,
    label: 'Link',
    tag: '<a>',
    description: 'Styled anchor link',
    defaultText: 'Explore HTML element',
    defaultAccentHex: '#0ea5e9',
    defaultFontSize: 13,
    defaultWidth: 180,
    defaultHeight: 46,
    icon: Icons.link,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.checkbox,
    label: 'Checkbox',
    tag: '<input type="checkbox">',
    description: 'Toggleable HTML check',
    defaultText: 'Enable DOM feature',
    defaultAccentHex: '#10b981',
    defaultFontSize: 13,
    defaultWidth: 196,
    defaultHeight: 48,
    icon: Icons.check_box_outlined,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.image,
    label: 'Graphic',
    tag: '<img>',
    description: 'Inline SVG image',
    defaultText: '<img> SVG',
    defaultAccentHex: '#6366f1',
    defaultFontSize: 12,
    defaultWidth: 186,
    defaultHeight: 116,
    icon: Icons.image_outlined,
  ),
  HtmlElementTemplate(
    kind: HtmlElementKind.divider,
    label: 'Divider',
    tag: '<hr>',
    description: 'Horizontal rule',
    defaultText: 'Divider',
    defaultAccentHex: '#64748b',
    defaultFontSize: 12,
    defaultWidth: 236,
    defaultHeight: 36,
    icon: Icons.horizontal_rule,
  ),
];

HtmlElementTemplate templateForKind(HtmlElementKind kind) {
  return htmlElementTemplates.firstWhere((t) => t.kind == kind);
}

/// An instance of an HTML element placed on the canvas.
class PlacedHtmlElement {
  const PlacedHtmlElement({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.zIndex,
    required this.text,
    required this.accentHex,
    required this.fontSize,
    required this.width,
    this.checked = true,
    this.clickCount = 0,
    this.inputValue = '',
  });

  factory PlacedHtmlElement.fromTemplate({
    required String id,
    required HtmlElementTemplate template,
    required double x,
    required double y,
    required int zIndex,
  }) {
    return PlacedHtmlElement(
      id: id,
      kind: template.kind,
      x: x,
      y: y,
      zIndex: zIndex,
      text: template.defaultText,
      accentHex: template.defaultAccentHex,
      fontSize: template.defaultFontSize,
      width: template.defaultWidth,
    );
  }

  final String id;
  final HtmlElementKind kind;
  final double x;
  final double y;
  final int zIndex;
  final String text;
  final String accentHex;
  final double fontSize;
  final double width;
  final bool checked;
  final int clickCount;
  final String inputValue;

  PlacedHtmlElement copyWith({
    double? x,
    double? y,
    int? zIndex,
    String? text,
    String? accentHex,
    double? fontSize,
    double? width,
    bool? checked,
    int? clickCount,
    String? inputValue,
  }) {
    return PlacedHtmlElement(
      id: id,
      kind: kind,
      x: x ?? this.x,
      y: y ?? this.y,
      zIndex: zIndex ?? this.zIndex,
      text: text ?? this.text,
      accentHex: accentHex ?? this.accentHex,
      fontSize: fontSize ?? this.fontSize,
      width: width ?? this.width,
      checked: checked ?? this.checked,
      clickCount: clickCount ?? this.clickCount,
      inputValue: inputValue ?? this.inputValue,
    );
  }

  /// Generates clean HTML markup representing this placed element.
  String toHtmlSnippet() {
    final escaped = _escapeHtml(text);
    final left = x.round();
    final top = y.round();
    final pos = 'position:absolute;left:${left}px;top:${top}px;';
    switch (kind) {
      case HtmlElementKind.heading:
        return '<h1 style="${pos}font-size:${fontSize.round()}px;color:$accentHex;">$escaped</h1>';
      case HtmlElementKind.paragraph:
        return '<p style="${pos}width:${width.round()}px;font-size:${fontSize.round()}px;">$escaped</p>';
      case HtmlElementKind.button:
        return '<button type="button" style="${pos}background:$accentHex;font-size:${fontSize.round()}px;">$escaped</button>';
      case HtmlElementKind.input:
        final val = inputValue.isEmpty
            ? ''
            : ' value="${_escapeHtml(inputValue)}"';
        return '<input type="text" placeholder="$escaped"$val style="${pos}width:${width.round()}px;border-color:$accentHex;" />';
      case HtmlElementKind.card:
        return '<div style="${pos}width:${width.round()}px;border:1px solid $accentHex;padding:12px;border-radius:8px;">$escaped</div>';
      case HtmlElementKind.badge:
        return '<span style="${pos}background:$accentHex;font-size:${fontSize.round()}px;border-radius:999px;padding:4px 10px;">$escaped</span>';
      case HtmlElementKind.link:
        return '<a href="#$id" style="${pos}color:$accentHex;font-size:${fontSize.round()}px;">$escaped</a>';
      case HtmlElementKind.checkbox:
        final checkedAttr = checked ? ' checked' : '';
        return '<label style="${pos}font-size:${fontSize.round()}px;"><input type="checkbox"$checkedAttr /> $escaped</label>';
      case HtmlElementKind.image:
        return '<img alt="$escaped" style="${pos}width:${width.round()}px;" src="data:image/svg+xml,..." />';
      case HtmlElementKind.divider:
        return '<hr style="${pos}width:${width.round()}px;background:$accentHex;height:2px;border:none;" />';
    }
  }

  static String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}
