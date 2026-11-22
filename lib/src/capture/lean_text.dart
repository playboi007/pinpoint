// Plain Dart: no `dart:ui` and no `package:flutter`.

/// [text] (a diagnostics description) without what says nothing to an
/// agent:
///
/// - the hash code after a type name: `ButtonStyle#d3507(...)` is
///   `ButtonStyle(...)`;
/// - a part with no value: `name: null` and `name: WidgetStatePropertyAll(null)`
///   (also `MaterialStatePropertyAll`), at any depth.
///
/// Returns null when the text had only such parts and nothing is left of
/// it: `ButtonStyle#d3507(textStyle: WidgetStatePropertyAll(null))` says
/// nothing at all. A text that was not changed comes back as it is.
String? leanText(String text) {
  var lean = text.replaceAllMapped(
    RegExp(r'(?<=[A-Za-z0-9_>?])#[0-9a-f]{5}(?![0-9a-f])'),
    (_) => '',
  );
  final empty = RegExp(
    r'\b[A-Za-z_]\w*: (?:null|(?:Widget|Material)StatePropertyAll\(null\))'
    r'(?=,|\)|$)',
  );
  var changed = lean != text;
  for (var pass = 0; pass < 6; pass++) {
    final next = lean
        .replaceAll(empty, '')
        // The separators a removed part leaves behind.
        .replaceAll(RegExp(r'\(\s*,\s*'), '(')
        .replaceAll(RegExp(r',\s*,'), ',')
        .replaceAll(RegExp(r',\s*\)'), ')');
    if (next == lean) break;
    changed = true;
    lean = next;
  }
  // A value that held only empty parts, `WidgetStatePropertyAll(null)`
  // and `Foo()` left after the removal.
  if (changed && RegExp(r'^[A-Za-z_][\w<>?, ]*\(\)$').hasMatch(lean)) {
    return null;
  }
  return lean;
}
