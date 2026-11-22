part of 'commands.dart';

/// Finding widgets by text, key or type, and naming them.
extension AgentFind on AgentCommands {
  /// The live element of the handle in `args['handle']`.
  Element element(Map<String, Object?> args) {
    final id = args['handle'];
    if (id is! String || id.isEmpty) {
      throw const AgentError('handle is required');
    }
    return handles.resolve(id, root: contentRoot, index: sourceIndex());
  }

  /// Live widgets by source line, type, text or key: the reverse lookup.
  /// Visible ones first, then the rest (offstage routes, scrolled away).
  Map<String, Object?> findWidgets(
    Map<String, Object?> args,
    OutputLimits limits,
  ) {
    final ordered = matching(args, take: limits.items);
    final shown = ordered.take(limits.items).toList();
    return {
      'widgets': describeAll(shown, limits),
      if (ordered.length > shown.length) 'more': ordered.length - shown.length,
    };
  }

  /// The elements under [root] (the app when null) that fit the query in
  /// [args] (`file`, `line`, `type`, `text`, `key`), visible ones first.
  ///
  /// With [take], only the first [take] places are sorted: a visible rect
  /// walks every ancestor, so it is not measured for matches that cannot
  /// be among them (a `Text` query can match thousands).
  List<Element> matching(
    Map<String, Object?> args, {
    Element? root,
    int? take,
  }) {
    final file = nonEmptyString(args['file']);
    final line = args['line'];
    final type = nonEmptyString(args['type']);
    final text = nonEmptyString(args['text'])?.toLowerCase();
    final key = nonEmptyString(args['key']);
    if (file == null && type == null && text == null && key == null) {
      throw const AgentError('give at least one of file, type, text or key');
    }
    if (line != null && (line is! int || file == null)) {
      throw const AgentError('line must be an integer, with a file');
    }
    final matches = sourceIndex().query(
      root: root ?? contentRoot,
      file: file,
      line: line as int?,
      type: type,
      where: text == null && key == null
          ? null
          : (element) {
              if (key != null && !keyMatches(element.widget.key, key)) {
                return false;
              }
              if (text != null) {
                if (AgentScreen._isTextTwin(element)) return false;
                final shown = AgentCommands.textOf(element);
                if (shown == null || !shown.toLowerCase().contains(text)) {
                  return false;
                }
              }
              return true;
            },
    );
    bool visible(Element e) {
      final renderObject = AgentCommands.renderObjectOf(e);
      return renderObject != null &&
          RenderSearch.visibleRectOf(renderObject) != null;
    }

    final shown = <Element>[];
    final rest = <Element>[];
    for (final element in matches) {
      if (take != null && shown.length >= take) {
        rest.add(element);
      } else {
        (visible(element) ? shown : rest).add(element);
      }
    }
    return [...shown, ...rest];
  }

  /// Whether [widgetKey] is the key the agent named: its text as given
  /// (`[<'save'>]`) or the value inside it (`save`).
  static bool keyMatches(Key? widgetKey, String key) {
    if (widgetKey == null) return false;
    final text = widgetKey.toString();
    return text == key || text == "[<'$key'>]" || text == '[<$key>]';
  }

  /// The widget that covers a point: its nearest meaningful name, and
  /// whether it is Pinpoint's own (a pin, the launcher).
  String describeObscurer(RenderObject renderObject) {
    final locator = this.locator();
    final owner = locator.elementOf(renderObject);
    if (owner == null) return renderObject.runtimeType.toString();
    final name = _meaningfulName(owner);
    return locator.isInApp(owner) ? name : "Pinpoint's own $name";
  }

  /// Wrappers that say nothing about what covers a point.
  static const Set<String> _plain = {
    'AbsorbPointer',
    'Actions',
    'Align',
    'AnimatedBuilder',
    'BlockSemantics',
    'Builder',
    'Center',
    'ColoredBox',
    'ConstrainedBox',
    'Container',
    'CustomPaint',
    'DecoratedBox',
    'DefaultTextStyle',
    'ExcludeSemantics',
    'FadeTransition',
    'Focus',
    'FocusScope',
    'GestureDetector',
    'IconTheme',
    'IgnorePointer',
    'InkResponse',
    'InkWell',
    'KeyedSubtree',
    'Listener',
    'ListenableBuilder',
    'Material',
    'MergeSemantics',
    'MouseRegion',
    'Opacity',
    'Padding',
    'Positioned',
    'RawGestureDetector',
    'RepaintBoundary',
    'Semantics',
    'Shortcuts',
    'SizedBox',
    'Stack',
    'Tooltip',
    'ValueListenableBuilder',
  };

  /// Widgets that cover the app on purpose: named first when one of them
  /// is above the hit.
  static const Set<String> _covers = {
    'AlertDialog',
    'BottomSheet',
    'CupertinoAlertDialog',
    'Dialog',
    'Drawer',
    'ModalBarrier',
    'NavigationDrawer',
    'PinPointLauncher',
    'PinMarker',
    'SimpleDialog',
    'SnackBar',
  };

  /// The name of what covers a point: a known cover above the hit
  /// (a barrier, a dialog, a sheet), else the nearest widget from the
  /// app's own source, else the nearest public widget that is not a plain
  /// wrapper.
  String _meaningfulName(Element element) {
    final chain = <Element>[element];
    element.visitAncestorElements((ancestor) {
      chain.add(ancestor);
      return chain.length < 40;
    });
    String nameOf(Element e) =>
        e.widget.runtimeType.toString().split('<').first;
    // The outermost cover: an AlertDialog builds a Dialog inside it.
    String? cover;
    for (final e in chain) {
      if (_covers.contains(nameOf(e))) cover = nameOf(e);
    }
    if (cover != null) return cover;
    final resolver = this.resolver();
    for (final e in chain) {
      if (resolver.entryOf(e).isLocal) return nameOf(e);
    }
    for (final e in chain) {
      final name = nameOf(e);
      if (!name.startsWith('_') && !_plain.contains(name)) return name;
    }
    return nameOf(element);
  }
}
