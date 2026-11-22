part of 'commands.dart';

/// What is on screen: the widget list, one widget, inspect and flash.
extension AgentScreen on AgentCommands {
  /// The info payload for the handle's widget, without a
  /// screenshot.
  Map<String, Object?> inspect(Map<String, Object?> args) {
    final target = element(args);
    final pick = pickFor(target);
    final note = _collector.collect(
      pick,
      '',
      AnnotationIntent.improve,
      context: pageContext(),
      environment: controller.environment.toJson(),
    );
    return {
      'handle': args['handle'],
      if (args['detail'] case final String detail) 'detail': detail,
      'note': note.toJson(),
    };
  }

  /// Outlines the handle's widget for 1.5 seconds, so the user sees what
  /// the agent means.
  Map<String, Object?> flash(Map<String, Object?> args) {
    final target = element(args);
    final renderObject = AgentCommands.renderObjectOf(target);
    if (renderObject == null) {
      throw const AgentError('the widget has no layout to show');
    }
    controller.agent.flashOn(renderObject);
    final rect = RenderSearch.globalRectOf(renderObject);
    return {
      'handle': args['handle'],
      if (rect != null) 'rect': rectList(rect),
      'visible': RenderSearch.visibleRectOf(renderObject) != null,
    };
  }

  /// A pick of [element] itself, as a pin or a finding makes one.
  PickResult pickFor(Element element) {
    final root = appKey.currentContext;
    if (root is! Element) throw const AgentError('the app is not on screen');
    final pick = PickResult.forElement(
      element,
      rootElement: root,
      chainBoundary: contentRoot,
      resolver: resolver(),
    );
    if (pick == null) {
      throw const AgentError('the widget is not laid out (off screen?)');
    }
    return pick;
  }

  /// A `RichText` that a `Text` built: the `Text` already stands for it.
  static bool _isTextTwin(Element element) {
    if (element.widget is! RichText) return false;
    var twin = false;
    var steps = 0;
    element.visitAncestorElements((ancestor) {
      twin = ancestor.widget is Text;
      return !twin && ++steps < 3;
    });
    return twin;
  }

  /// Route, URL, viewport, environment and a bounded outline of the local
  /// widgets on screen, each with a handle.
  Map<String, Object?> getScreen(OutputLimits limits) {
    final root = appRoot;
    final locator = this.locator();
    final seen = Set<Element>.identity();
    final shown = <Element>[];
    var total = 0;
    RenderSearch.visitVisible(root, (node, rect, visible) {
      final owner = locator.elementOf(node);
      if (owner == null) return;
      final local = locator.localEntryOf(owner);
      if (local == null || !seen.add(local.element)) return;
      total++;
      if (shown.length < limits.items) shown.add(local.element);
    });
    return {
      'route': currentRoute(),
      'url': kIsWeb ? limits.clip(Uri.base.toString()) : null,
      'viewport': _size(root.paintBounds.size),
      'environment': controller.environment.toJson(),
      'mode': controller.mode.name,
      'outline': describeAll(shown, limits),
      if (total > shown.length) 'more': total - shown.length,
    };
  }

  /// [elements] as the agent sees them, each with a new handle.
  List<Map<String, Object?>> describeAll(
    List<Element> elements,
    OutputLimits limits,
  ) {
    final anchors = sourceIndex().anchorsFor(elements, root: contentRoot);
    return [
      for (final element in elements)
        describe(element, anchors[element], limits),
    ];
  }

  /// One element as the agent sees it, with a new handle.
  Map<String, Object?> describe(
    Element element,
    NoteAnchor? anchor,
    OutputLimits limits,
  ) {
    final renderObject = AgentCommands.renderObjectOf(element);
    final rect = renderObject == null
        ? null
        : RenderSearch.globalRectOf(renderObject);
    final text = AgentCommands.textOf(element);
    var field = _soleEditableIn(element);
    var scrollable = _ownScrollable(element);
    if (field != null && scrollable != null) {
      // A field has its own horizontal scrollable; a list can hold one
      // field. Whichever is outside the other is what this widget is.
      final inField = identical(
        scrollable.context.findAncestorStateOfType<EditableTextState>(),
        field,
      );
      if (inField) {
        scrollable = null;
      } else {
        field = null;
      }
    }
    return {
      'handle': handles.add(element, anchor),
      'widget': element.widget.runtimeType.toString(),
      'source': ?_where(anchor),
      'key': ?element.widget.key?.toString(),
      'rect': ?(rect == null ? null : rectList(rect)),
      'visible':
          renderObject != null &&
          RenderSearch.visibleRectOf(renderObject) != null,
      if (text != null) 'text': limits.clip(text),
      // A field's value and a list's position, so the agent needs no
      // get_state call to read them.
      if (field != null && text == null)
        'value': field.widget.obscureText
            ? '[masked]'
            : limits.clip(field.textEditingValue.text),
      if (scrollable != null && scrollable.position.hasPixels)
        'scroll': AgentInput._scrollState(scrollable.position),
    };
  }

  /// The one text field at or close under [element] (a `TextField`,
  /// a `TextFormField`), or null when there is none or more than one (a
  /// form).
  static EditableTextState? _soleEditableIn(Element element) {
    EditableTextState? found;
    var count = 0;
    var visited = 0;
    void visit(Element e) {
      if (count > 1 || ++visited > 200) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        count++;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return count == 1 ? found : null;
  }

  /// The scrollable at or close under [element] (a list's own), or null.
  static ScrollableState? _ownScrollable(Element element) {
    ScrollableState? found;
    var visited = 0;
    void visit(Element e) {
      if (found != null || ++visited > 50) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        found = e.state as ScrollableState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }

  /// The route on top: the route of what is at the center of the app.
  String? currentRoute() {
    final root = appRoot;
    final rect = RenderSearch.globalRectOf(root);
    if (rect == null) return null;
    final hits = RenderSearch.find(root, rect.center).candidates;
    final locator = this.locator();
    for (final hit in hits) {
      final owner = locator.elementOf(hit.renderObject);
      if (owner is RenderObjectElement) {
        return ContextCollector.routeNameOf(owner);
      }
    }
    return null;
  }

  /// `[x, y, w, h]` to one decimal.
  static List<num> rectList(Rect rect) => [
    _round(rect.left),
    _round(rect.top),
    _round(rect.width),
    _round(rect.height),
  ];

  static Map<String, num> _size(Size size) => {
    'width': _round(size.width),
    'height': _round(size.height),
  };

  static num _round(double value) {
    final r = (value * 10).roundToDouble() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }

  static String? _where(NoteAnchor? anchor) {
    final file = anchor?.file;
    final line = anchor?.line;
    return file == null || line == null ? null : '$file:$line';
  }
}
