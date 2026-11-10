import 'package:flutter/widgets.dart';

/// Default cap on elements visited by [indexRenderObjects] (engineering rule
/// 4).
const int defaultMaxElements = 100000;

/// The element that owns [renderObject], or null when it cannot be found.
///
/// In debug, `RenderObject.debugCreator` holds a `DebugCreator` with the
/// owning `RenderObjectElement` (docs/api-notes.md, item 5). It is null in
/// profile and release, so there the subtree under [root] is indexed.
Element? elementFor(RenderObject renderObject, {required Element root}) {
  final creator = renderObject.debugCreator;
  if (creator is DebugCreator) return creator.element;
  return indexRenderObjects(root)[renderObject];
}

/// Maps each render object under [root] to the `RenderObjectElement` that
/// owns it, for build modes without `debugCreator`.
///
/// Bounded and guarded like every tree walk: at most [maxElements] elements,
/// iterative so a deep tree cannot overflow the stack, and a child list that
/// throws only skips that element's children.
Map<RenderObject, Element> indexRenderObjects(
  Element root, {
  int maxElements = defaultMaxElements,
}) {
  final index = Map<RenderObject, Element>.identity();
  final stack = <Element>[root];
  var visited = 0;
  while (stack.isNotEmpty && visited < maxElements) {
    final element = stack.removeLast();
    visited++;
    try {
      // Only a RenderObjectElement owns its render object. A component
      // element's `renderObject` is the nearest one beneath it.
      if (element is RenderObjectElement) {
        index[element.renderObject] = element;
      }
      element.visitChildren(stack.add);
    } catch (_) {
      // Skip this element's subtree; the rest of the index still helps.
    }
  }
  assert(() {
    if (stack.isNotEmpty) {
      debugPrint('pinpoint: element index stopped at $maxElements elements.');
    }
    return true;
  }());
  return index;
}
