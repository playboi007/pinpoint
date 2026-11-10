import 'package:flutter/widgets.dart';

import '../model/source_location.dart';

/// Reads where widgets were created in source.
///
/// With `source_index.dart`, the only file that touches
/// [WidgetInspectorService] (engineering rule 8). A Flutter upgrade that
/// changes the inspector should break here and nowhere else;
/// `test/source/source_resolver_test.dart` checks a known file and line.
class SourceResolver {
  const SourceResolver({this.tracked});

  /// Whether creation locations exist. Null: ask the inspector. Tests pass
  /// false to act as profile mode.
  final bool? tracked;

  /// Whether creation locations exist in this build.
  ///
  /// They need `--track-widget-creation`, which is on in debug only. When
  /// false, no location work is done at all.
  bool get available =>
      tracked ?? WidgetInspectorService.instance.isWidgetCreationTracked();

  /// Locations keyed by the widget instance. A location belongs to the
  /// widget, not the element: a hot reload builds new widget instances, so
  /// edited lines are read again, and an old entry goes with its widget.
  static final Expando<Object> _cache = Expando<Object>(
    'pinpoint source locations',
  );

  /// Stored for a widget that has no location, so it is not read again.
  static const Object _none = Object();

  /// Where [element]'s widget was created, or null when unknown.
  ///
  /// Read through the inspector's serializer on the widget alone (no
  /// children, no properties). This does not set the inspector's global
  /// selection, so DevTools keeps showing what the user selected there.
  SourceLocation? locationOf(Element element) {
    if (!available) return null;
    final Widget widget;
    try {
      widget = element.widget; // throws once the element is unmounted
    } catch (_) {
      return null;
    }
    final cached = _cache[widget];
    if (cached != null) return cached is SourceLocation ? cached : null;
    final location = _read(widget);
    _cache[widget] = location ?? _none;
    return location;
  }

  static SourceLocation? _read(Widget widget) {
    try {
      // `toJsonMap` builds its map inside an assert, so outside debug it is
      // empty (docs/api-notes.md, item 1). `available` already covers that.
      final json = widget.toDiagnosticsNode().toJsonMap(
        InspectorSerializationDelegate(
          service: WidgetInspectorService.instance,
          subtreeDepth: 0,
          includeProperties: false,
        ),
      );
      final location = json['creationLocation'];
      if (location is! Map) return null;
      final file = location['file'];
      final line = location['line'];
      final column = location['column'];
      final name = location['name'];
      if (file is! String || line is! int || column is! int) return null;
      return SourceLocation(
        uri: file,
        line: line,
        column: column,
        name: name is String ? name : null,
      );
    } catch (_) {
      // Diagnostics run code written by widget authors; one that throws
      // must not stop a pick (engineering rule 4).
      return null;
    }
  }
}
