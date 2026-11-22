part of 'commands.dart';

/// Tap, enter text, scroll and navigate.
extension AgentInput on AgentCommands {
  /// `wait_idle`: whether the app settled within `timeout_ms` (default
  /// 2000).
  Future<Map<String, Object?>> waitIdleTool(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final ms = args['timeout_ms'];
    final timeout = ms is num ? ms.round().clamp(0, 60000) : 2000;
    final idle = await waitIdle(Duration(milliseconds: timeout), cancel);
    return {'idle': idle, 'timeout_ms': timeout};
  }

  /// A synthetic tap (or long press) at the center of the handle's
  /// visible part, after checking that nothing covers it.
  Future<Map<String, Object?>> tap(
    Map<String, Object?> args,
    AgentCancel cancel, {
    bool long = false,
  }) async {
    final target = element(args);
    await prepareToDrive();
    cancel.check();
    final renderObject = AgentCommands.renderObjectOf(target);
    if (renderObject == null) {
      throw const AgentNotReady('the widget is not laid out');
    }
    final visible = RenderSearch.visibleRectOf(renderObject);
    if (visible == null || visible.width <= 0 || visible.height <= 0) {
      throw const AgentNotReady('not on screen; call scroll_to first');
    }
    final point = visible.center;
    // A what-if viewport leaves screen around the app: a point there is
    // over nothing (Milestone 9, RenderSearch.isOnApp).
    if (!RenderSearch.isOnApp(appRoot, point)) {
      throw const AgentError('outside the app viewport');
    }
    final viewId = SyntheticInput.viewIdOf(renderObject);
    final blocker = SyntheticInput.obscuredBy(
      renderObject,
      point,
      viewId: viewId,
      describe: describeObscurer,
    );
    if (blocker != null) throw AgentError('obscured by $blocker');
    controller.agent.mark(point, longPress: long);
    await SyntheticInput.press(
      point,
      viewId: viewId,
      cancel: cancel,
      hold: long ? SyntheticInput.longPressHold : SyntheticInput.tapHold,
    );
    await AgentDrive._frame();
    return {
      'handle': args['handle'],
      'tapped': [AgentScreen._round(point.dx), AgentScreen._round(point.dy)],
    };
  }

  /// Focuses the text field under the handle and sets its text as typing
  /// would: `userUpdateTextEditingValue` runs the input formatters and
  /// `onChanged` (docs/api-notes.md, item 13: it takes a cause too).
  Future<Map<String, Object?>> enterText(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    final text = args['text'];
    if (text is! String) throw const AgentError('text is required');
    final target = element(args);
    final field = _editableIn(target);
    if (field == null) {
      throw const AgentError('no text field at or under the handle');
    }
    if (field.widget.readOnly) {
      throw const AgentError('the field is read only or disabled');
    }
    await prepareToDrive();
    cancel.check();
    field.widget.focusNode.requestFocus();
    await AgentDrive._frame();
    cancel.check();
    if (!field.mounted) throw const AgentError('the field went away');
    field.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
    await AgentDrive._frame();
    final value = field.mounted ? field.textEditingValue.text : text;
    return {
      'handle': args['handle'],
      // Never echo a password back (engineering rule 9).
      'text': field.widget.obscureText ? '[masked]' : limits.clip(value),
      'focused': field.mounted && field.widget.focusNode.hasFocus,
    };
  }

  static EditableTextState? _editableIn(Element element) {
    EditableTextState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 2000) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }

  /// Moves a scrollable by `dy` (a vertical one) or `dx` (a horizontal
  /// one): the nearest of that axis at or above the handle, or the main
  /// one with no handle. The axis decides, so a text field's own
  /// horizontal scrollable never takes a `dy` meant for the page.
  Future<Map<String, Object?>> scroll(Map<String, Object?> args) async {
    final dx = args['dx'];
    final dy = args['dy'];
    final vertical = dy is num && dy != 0;
    final horizontal = dx is num && dx != 0;
    if (vertical == horizontal) {
      throw const AgentError('give one of dy (vertical) or dx (horizontal)');
    }
    final axis = vertical ? Axis.vertical : Axis.horizontal;
    final delta = (vertical ? dy : dx)! as num;
    final target = args['handle'] == null ? null : element(args);
    await prepareToDrive();
    final scrollable = target == null
        ? mainScrollable(axis: axis)
        : scrollableFor(target, axis: axis);
    if (scrollable == null) {
      throw AgentError(
        'no ${axis.name} scrollable '
        '${target == null ? 'on screen' : 'at or above the widget'}',
      );
    }
    final position = scrollable.position;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await AgentDrive._frame();
    return _scrollState(position);
  }

  static Map<String, Object?> _scrollState(ScrollPosition position) => {
    'pixels': AgentScreen._round(position.pixels),
    'min': AgentScreen._round(position.minScrollExtent),
    'max': AgentScreen._round(position.maxScrollExtent),
    'viewport': AgentScreen._round(position.viewportDimension),
    'axis': axisDirectionToAxis(position.axisDirection).name,
  };

  /// The scrollable of a handle: its own (a list's handle), else the
  /// nearest above it; with [axis], only one that scrolls along it. Found
  /// without subscribing (engineering rule 3).
  static ScrollableState? scrollableFor(Element element, {Axis? axis}) {
    bool fits(Element e) =>
        e is StatefulElement &&
        e.state is ScrollableState &&
        (axis == null ||
            axisDirectionToAxis((e.state as ScrollableState).axisDirection) ==
                axis);
    ScrollableState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 200) return;
      if (fits(e)) {
        found = (e as StatefulElement).state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    if (found != null) return found;
    element.visitAncestorElements((e) {
      if (!fits(e)) return true;
      found = (e as StatefulElement).state as ScrollableState;
      return false;
    });
    return found;
  }

  /// The biggest scrollable on screen, of [axis] when given: the page's
  /// main list.
  ScrollableState? mainScrollable({Axis? axis}) {
    ScrollableState? best;
    var bestArea = 0.0;
    var visited = 0;
    void visit(Element e) {
      if (++visited > 20000) return;
      if (e is StatefulElement &&
          e.state is ScrollableState &&
          (axis == null ||
              axisDirectionToAxis((e.state as ScrollableState).axisDirection) ==
                  axis)) {
        final renderObject = AgentCommands.renderObjectOf(e);
        final shown = renderObject == null
            ? null
            : RenderSearch.visibleRectOf(renderObject);
        final area = shown == null ? 0.0 : shown.width * shown.height;
        if (area > bestArea) {
          bestArea = area;
          best = e.state as ScrollableState;
        }
      }
      e.visitChildren(visit);
    }

    visit(contentRoot);
    return best;
  }

  /// `scroll_to`: with a handle, brings it into view. With a query, scrolls
  /// a list one screen at a time until a matching widget is built, then
  /// brings it into view.
  ///
  /// Lazy lists build only what is near the screen (watch out for):
  /// `find_widgets` cannot see an item that was never built, so this
  /// scrolls, waits for the frame that builds the next items, and searches
  /// again, at most `max_steps` times (default 30). From the end of the
  /// list it goes on from the start, up to where it began.
  Future<Map<String, Object?>> scrollTo(
    Map<String, Object?> args,
    OutputLimits limits,
    AgentCancel cancel,
  ) async {
    await prepareToDrive();
    if (args['handle'] is String) {
      final target = element(args);
      await ensureVisible(target);
      await AgentDrive._frame();
      return {'widget': describe(target, _anchorOf(target), limits)};
    }
    final within = args['within'];
    final scrollable = within is String
        ? scrollableFor(element({'handle': within}))
        : mainScrollable();
    if (scrollable == null) {
      throw const AgentError('no scrollable list on screen');
    }
    final steps = args['max_steps'] is num
        ? (args['max_steps']! as num).round().clamp(1, 200)
        : 30;
    final start = scrollable.position.pixels;
    var wrapped = false;
    for (var step = 0; step < steps; step++) {
      cancel.check();
      if (!scrollable.mounted) throw const AgentError('the list went away');
      final found = matching(
        args,
        root: scrollable.context as Element,
        take: 1,
      );
      if (found.isNotEmpty) {
        final target = found.first;
        await ensureVisible(target);
        await AgentDrive._frame();
        return {
          'widget': describe(target, _anchorOf(target), limits),
          'steps': step,
        };
      }
      final position = scrollable.position;
      if (position.pixels >= position.maxScrollExtent - 0.5) {
        // The end: go on from the start, once.
        if (wrapped || start <= position.minScrollExtent + 0.5) break;
        wrapped = true;
        position.jumpTo(position.minScrollExtent);
      } else {
        // One screen on: with the cache extent, no item is skipped.
        position.jumpTo(
          math.min(
            position.pixels + position.viewportDimension,
            position.maxScrollExtent,
          ),
        );
        if (wrapped && position.pixels >= start) break;
      }
      // The frame that builds the newly shown items.
      await AgentDrive._frame();
    }
    throw AgentError('not found after $steps steps');
  }

  NoteAnchor? _anchorOf(Element element) =>
      sourceIndex().anchorsFor([element], root: contentRoot)[element];

  /// Pushes a route by path, as the platform would.
  Future<Map<String, Object?>> navigate(
    Map<String, Object?> args,
    AgentCancel cancel,
  ) async {
    final path = args['path'];
    if (path is! String || path.isEmpty) {
      throw const AgentError('path is required, for example /settings');
    }
    await prepareToDrive();
    final handled = await AgentDrive.pushRoute(path);
    await waitIdle(AgentVerify.settleTimeout, cancel);
    return {
      'handled': handled,
      'route': currentRoute(),
      if (!handled) 'reason': 'no navigator or router took the route',
    };
  }

  /// Pops the current route, as the back button does.
  Future<Map<String, Object?>> back(AgentCancel cancel) async {
    await prepareToDrive();
    final handled = await AgentDrive.popRoute();
    await waitIdle(AgentVerify.settleTimeout, cancel);
    return {'handled': handled, 'route': currentRoute()};
  }
}
