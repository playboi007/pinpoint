// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can use it too.

/// Where a widget's constructor call appears in source.
///
/// Read from the widget, so after an edit and a hot reload the new widget
/// instance carries the new line. Anything stored across edits (pins in
/// Milestone 8) must re-match by file, widget type and nearest line, not by
/// line alone.
class SourceLocation {
  const SourceLocation({
    required this.uri,
    required this.line,
    required this.column,
    this.name,
  });

  /// The file as the inspector reports it: a `file:///` URI on the VM and on
  /// web (docs/api-notes.md, item 2).
  final String uri;

  /// 1-based.
  final int line;

  /// 1-based.
  final int column;

  /// The constructor name, for example `Text`. Null when not reported.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is SourceLocation &&
      other.uri == uri &&
      other.line == line &&
      other.column == column &&
      other.name == name;

  @override
  int get hashCode => Object.hash(uri, line, column, name);

  @override
  String toString() => '$uri:$line:$column';
}
