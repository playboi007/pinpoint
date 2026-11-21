import 'package:flutter/widgets.dart';

import '../model/annotation.dart' show clipText;

/// Names one instance of many (a list row's own notifier) by the nearest
/// `Key` (a `ValueKey` of a string, number or bool), else the list index
/// (an indexed slot, 12 ancestors up at most), else the first `Text` in the
/// element's subtree (30 elements at most).
String? instanceLabel(Element element) {
  String? found;
  var steps = 0;
  bool visit(Element e) {
    final key = e.widget.key;
    if (key is ValueKey) {
      final value = key.value;
      if (value is String || value is num || value is bool) {
        found = 'key ${clipText('$value', 24)}';
        return false;
      }
    }
    final slot = e.slot;
    if (slot is IndexedSlot) {
      found = 'index ${slot.index}';
      return false;
    }
    if (slot is int) {
      found = 'index $slot';
      return false;
    }
    return ++steps < 12;
  }

  if (visit(element)) element.visitAncestorElements(visit);
  if (found != null) return found;
  final text = shortTextOf(element);
  return text == null ? null : '"$text"';
}

/// The first non-empty `Text` in the subtree of [element] (30 elements at
/// most), cut to [max] characters. A `TextField` has no `Text` with its
/// value, so a typed secret is never read here.
///
/// With [small], the text counts only when the whole subtree has at most
/// [smallSubtree] elements: a button's label names a tap, the first title
/// of a whole screen does not.
String? shortTextOf(
  Element element, {
  int max = 20,
  bool small = false,
  int smallSubtree = 40,
}) {
  var visited = 0;
  String? text;
  final limit = small ? smallSubtree + 1 : 30;
  void walk(Element e) {
    if (++visited > limit) return;
    if (text == null) {
      final widget = e.widget;
      if (widget is Text && widget.data != null && widget.data!.isNotEmpty) {
        text = clipText(widget.data!, max);
        if (!small) return;
      }
    }
    if (!small && text != null) return;
    e.visitChildren(walk);
  }

  walk(element);
  return small && visited > smallSubtree ? null : text;
}
