import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/render_search.dart';

/// A pick with no render tree behind it, for plain controller tests.
///
/// Its element is never mounted, so a `PickTracker` would clear it after the
/// next frame. Widget tests select for real instead.
PickResult fakePick([Offset position = Offset.zero]) {
  final rect = position & const Size(10, 10);
  return PickResult.debug(
    position: position,
    candidates: [
      RenderCandidate(
        renderObject: RenderConstrainedBox(
          additionalConstraints: const BoxConstraints(),
        ),
        globalRect: rect,
        depth: 1,
        order: 0,
      ),
    ],
    index: 0,
    element: const SizedBox().createElement(),
    globalRect: rect,
  );
}
