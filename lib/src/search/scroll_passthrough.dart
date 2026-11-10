import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'element_lookup.dart';
import 'render_search.dart';

/// How many candidates under the cursor are tried, smallest first.
const int _maxCandidates = 32;

/// Forwards a wheel [event] that landed on the pointer trap to the app.
///
/// Finds what is under the cursor, walks up to the nearest `Scrollable`
/// whose axis matches the larger delta and that can still move that way,
/// and calls `position.pointerScroll`. An inner list at its end passes the
/// wheel on to the one around it, as without Pinpoint. Returns whether a
/// scrollable took the event.
bool scrollPassthrough(
  PointerScrollEvent event, {
  required RenderObject root,
  required Element rootElement,
}) {
  final delta = event.scrollDelta;
  final axis = delta.dy.abs() >= delta.dx.abs()
      ? Axis.vertical
      : Axis.horizontal;
  final amount = axis == Axis.vertical ? delta.dy : delta.dx;
  if (amount == 0) return false;
  if (!RenderSearch.isOnApp(root, event.position)) return false;

  final candidates = RenderSearch.find(root, event.position).candidates;
  final tried = <ScrollableState>{};
  for (final candidate in candidates.take(_maxCandidates)) {
    final element = elementFor(candidate.renderObject, root: rootElement);
    if (element == null) continue;
    // A lookup, not a dependency: the app element is not subscribed to
    // anything (engineering rule 3).
    var state = element.findAncestorStateOfType<ScrollableState>();
    while (state != null && tried.add(state)) {
      if (_scroll(state, axis, amount)) {
        // On web, keeps the browser from also scrolling the page.
        event.respond(allowPlatformDefault: false);
        return true;
      }
      state = state.context.findAncestorStateOfType<ScrollableState>();
    }
  }
  return false;
}

bool _scroll(ScrollableState state, Axis axis, double amount) {
  try {
    final position = state.position;
    if (position.axis != axis) return false;
    if (!position.physics.shouldAcceptUserOffset(position)) return false;
    // A reversed list (a chat) moves the other way, as `Scrollable` does.
    final delta = axisDirectionIsReversed(position.axisDirection)
        ? -amount
        : amount;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return false;
    position.pointerScroll(delta);
    return true;
  } catch (_) {
    return false;
  }
}
