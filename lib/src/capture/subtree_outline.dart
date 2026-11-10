import 'package:flutter/widgets.dart';

import '../model/annotation.dart';
import '../search/source_resolver.dart';

/// [root]'s subtree as indented text, depth first: two spaces per level,
/// and `file:line` after each local widget, for example
///
/// ```text
/// Text  lib/widgets/save_bar.dart:42
///   RichText
/// ```
///
/// At most [maxDepth] levels; a node on the last level that has children
/// ends in " …". At most [maxNodes] lines; when nodes are left out, a last
/// line "…" says so. A child list that throws is skipped (engineering rule
/// 4).
String subtreeOutline(
  Element root, {
  required SourceResolver resolver,
  int maxDepth = 4,
  int maxNodes = 40,
  int maxLabel = 80,
}) {
  final lines = <String>[];
  var cut = false;

  void visit(Element element, int depth) {
    if (lines.length >= maxNodes) {
      cut = true;
      return;
    }
    final children = <Element>[];
    try {
      element.visitChildren(children.add);
    } catch (_) {
      children.clear();
    }
    final line = StringBuffer('  ' * depth)
      ..write(clipText(shortLabel(element), maxLabel));
    final entry = resolver.entryOf(element);
    final location = entry.location;
    if (entry.isLocal && location != null) {
      line.write(
        '  ${resolver.paths.relativePath(location.uri)}:${location.line}',
      );
    }
    final deepest = depth == maxDepth - 1;
    if (deepest && children.isNotEmpty) line.write(' …');
    lines.add(line.toString());
    if (deepest) return;
    for (final child in children) {
      visit(child, depth + 1);
      if (cut) return;
    }
  }

  visit(root, 0);
  if (cut) lines.add('…');
  return lines.join('\n');
}

/// [element]'s `widget.toStringShort()`: the type name, with the key when
/// there is one. It runs code written by widget authors, which can throw;
/// then the type name, or "?".
String shortLabel(Element element) {
  try {
    return element.widget.toStringShort();
  } catch (_) {
    return typeName(element);
  }
}

/// [element]'s widget type name, or "?" once it is unmounted.
String typeName(Element element) {
  try {
    return element.widget.runtimeType.toString();
  } catch (_) {
    return '?';
  }
}
