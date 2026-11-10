// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge (`bin/`)
// writes each note's `.md` with the same function the clipboard sink uses.

import '../model/annotation.dart';

/// [note] as the Markdown a coding agent reads.
///
/// It leads with the instruction and the location, since that is what the
/// agent acts on, then the page, the layout and the subtree. The image data
/// is never in it; the screenshot is named by its file.
String markdownFor(Annotation note) => markdownFromJson(note.toJson());

/// [json] (an `Annotation.toJson` map) as Markdown, see [markdownFor].
///
/// The bridge calls this on the JSON it receives, so it reads every field
/// defensively: a missing field or one of the wrong type is left out, never
/// thrown on.
String markdownFromJson(Map<String, Object?> json) {
  final target = _map(json['target']);
  final page = _map(json['page']);
  final app = _map(json['app']);
  final siblings = _map(json['siblings']);
  final shot = _map(json['screenshot']);

  final id = _string(json['id']);
  final intent = _string(json['intent']);
  final out = StringBuffer()
    ..writeln(
      '# Pinpoint${id == null ? '' : ' ${_line(id)}'}'
      '${intent == null ? '' : ' (${_line(intent)})'}',
    )
    ..writeln()
    ..writeln('Comment: ${_block(_string(json['comment']) ?? '')}')
    ..writeln();

  final widget = _string(target['widget']);
  final description = _string(target['description']) ?? widget;
  if (description != null) out.writeln('Target: ${_line(description)}');
  final text = _string(target['text']);
  if (text != null &&
      text.isNotEmpty &&
      !(description?.contains(text) ?? false)) {
    out.writeln('Text: ${_block(text)}');
  }

  final source = _where(target['source'], column: true);
  if (source != null) {
    out.writeln('Source: $source');
  } else {
    final mode = _string(app['buildMode']);
    out.writeln(
      mode != null && mode != 'debug'
          ? 'Source: unavailable ($mode build; file:line needs debug)'
          : 'Source: unavailable (no widget written in this project found)',
    );
  }

  final enclosing = [
    for (final ancestor in _list(json['ancestors']))
      if (_map(ancestor) case final a when _string(a['widget']) != null)
        _where(a['source']) == null
            ? _line(_string(a['widget'])!)
            : '${_line(_string(a['widget'])!)} (${_where(a['source'])})',
  ];
  if (enclosing.isNotEmpty) out.writeln('Enclosing: ${enclosing.join(' < ')}');

  final viewport = _map(page['viewport']);
  final width = _number(viewport['width']);
  final height = _number(viewport['height']);
  final textScale = _number(page['textScale']);
  final pageParts = [
    ?_string(page['route']) ?? _string(page['url']),
    if (width != null && height != null) 'viewport ${width}x$height',
    ?_string(page['brightness']),
    if (textScale != null)
      'textScale ${textScale.contains('.') ? textScale : '$textScale.0'}',
  ];
  if (pageParts.isNotEmpty) out.writeln('Page: ${_line(pageParts.join('  '))}');

  final rect = _map(target['rect']);
  final x = _number(rect['x']);
  final y = _number(rect['y']);
  final w = _number(rect['w']);
  final h = _number(rect['h']);
  final constraints = _string(target['constraints']);
  final parent = _string(siblings['parent']);
  final index = siblings['index'];
  final count = siblings['count'];
  final layoutParts = [
    if (x != null && y != null && w != null && h != null) 'rect $x,$y ${w}x$h',
    if (constraints != null) 'constraints ${compactConstraints(constraints)}',
    if (parent != null)
      index is int && count is int
          ? 'parent $parent, child ${index + 1} of $count'
          : 'parent $parent',
  ];
  if (layoutParts.isNotEmpty) {
    out.writeln('Layout: ${_line(layoutParts.join('  '))}');
  }

  final properties = [
    for (final MapEntry(:key, :value) in _map(target['properties']).entries)
      if (_string(value) case final v?) '$key=$v',
  ];
  if (properties.isNotEmpty) {
    out.writeln('Properties: ${_line(properties.join(', '))}');
  }

  final file = _string(shot['file']);
  if (file != null) {
    final debugPaint = [
      for (final flag in _list(shot['debugPaint'])) ?_string(flag),
    ];
    out.writeln(
      'Screenshot: ${_line(file)}'
      '${shot['hasPlatformViews'] == true ? ' (platform views show blank)' : ''}'
      '${debugPaint.isEmpty ? '' : ' (debug paint on: ${_line(debugPaint.join(', '))})'}',
    );
  }

  final errors = [for (final e in _list(json['errors'])) ?_string(e)];
  if (errors.isNotEmpty) {
    out.writeln('Not collected: ${_line(errors.join(', '))}');
  }
  final truncated = [for (final t in _list(json['truncated'])) ?_string(t)];
  if (truncated.isNotEmpty) {
    out.writeln('Truncated: ${_line(truncated.join(', '))}');
  }

  final subtree = _string(json['subtree']);
  if (subtree != null && subtree.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Subtree:');
    for (final line in subtree.split('\n')) {
      out.writeln('  $line');
    }
  }
  return out.toString();
}

/// [constraints] (a `toString()` of the target's constraints) without the
/// type name, unbounded ranges and trailing `.0`, as in `0<=w<=96`.
/// Anything other than `BoxConstraints(...)` is returned as is.
String compactConstraints(String constraints) {
  final match = RegExp(r'^BoxConstraints\((.*)\)$').firstMatch(constraints);
  if (match == null) return constraints;
  final parts = [
    for (final part in match.group(1)!.split(', '))
      if (!RegExp(r'^0\.0<=[wh]<=Infinity$').hasMatch(part))
        part.replaceAllMapped(RegExp(r'(\d+)\.0\b'), (m) => m.group(1)!),
  ];
  return parts.isEmpty ? 'unconstrained' : parts.join(', ');
}

/// `file:line`, or `file:line:column` with [column], or null.
String? _where(Object? source, {bool column = false}) {
  final s = _map(source);
  final file = _string(s['file']);
  final line = s['line'];
  if (file == null || line is! int) return null;
  final col = s['column'];
  return column && col is int
      ? '${_line(file)}:$line:$col'
      : '${_line(file)}:$line';
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

String? _string(Object? value) => value is String ? value : null;

/// [value] as JSON writes it: `96`, not `96.0`.
String? _number(Object? value) => switch (value) {
  final int n => '$n',
  final double n when n.isFinite =>
    n == n.truncateToDouble() ? '${n.toInt()}' : '$n',
  _ => null,
};

/// [text] on one line, so a value can never start a line of its own.
String _line(String text) => text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');

/// [text] with every line after the first indented by two spaces, so a
/// comment line can never read as a heading or a field of the note.
String _block(String text) => [
  for (final (i, line) in text.split(RegExp(r'\r\n?|\n')).indexed)
    i == 0 || line.trim().isEmpty ? line.trimRight() : '  ${line.trimRight()}',
].join('\n');
