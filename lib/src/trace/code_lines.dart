// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge's
// `state_flow` text and the app's State tab both pick code lines with this.

/// The most code lines shown under one notify or `setState`.
const int maxCodeLines = 5;

/// The code lines to show for a notify at [line]: the last [max] lines of
/// [text] up to [line] (the text starts at line [start]), with blank lines,
/// comments and lone closing brackets left out, each trimmed.
List<String> codeLinesAt(
  String text,
  int start,
  int line, {
  int max = maxCodeLines,
}) {
  final lines = text.split('\n');
  if (lines.isEmpty || max < 1) return const <String>[];
  final at = (line - start).clamp(0, lines.length - 1);
  final from = at - (max - 1) < 0 ? 0 : at - (max - 1);
  return [
    for (final raw in lines.sublist(from, at + 1))
      if (isCodeLine(raw)) raw.trim(),
  ];
}

/// Whether [line] is worth showing: not blank, not a comment, not a lone
/// closing bracket.
bool isCodeLine(String line) {
  final t = line.trim();
  return t.isNotEmpty &&
      !t.startsWith('//') &&
      !t.startsWith('/*') &&
      !t.startsWith('*') &&
      t != '}' &&
      t != '});' &&
      t != ');';
}
