// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge's MCP
// tools format notes with this.

import '../model/annotation.dart' show clipText;
import '../sink/markdown_formatter.dart';

/// How much of a note an MCP tool returns. More detail costs the agent
/// more context.
enum NoteDetail {
  /// The comment, the source and the rect: enough to find the code.
  compact,

  /// Adds the layout, the enclosing widgets, the page and the replies.
  standard,

  /// Everything: the properties, the subtree and the environment.
  full;

  /// The detail named [name]; [standard] when null.
  static NoteDetail? byName(Object? name) {
    if (name == null) return standard;
    for (final detail in values) {
      if (detail.name == name) return detail;
    }
    return null;
  }
}

/// The longest [NoteDetail.compact] text. The comment is cut to fit.
const int maxCompactChars = 600;

/// [note] (an `Annotation.toJson` map) as text at [detail].
String noteText(Map<String, Object?> note, NoteDetail detail) =>
    switch (detail) {
      NoteDetail.compact => _compact(note),
      NoteDetail.standard => _standard(note),
      NoteDetail.full => _full(note),
    };

/// The widget of [note] (a note payload from `inspect`) as text at
/// [detail], headed by its [handle]: the note's text without the note's
/// own parts (id, comment, status, replies).
String inspectText(
  String handle,
  Map<String, Object?> note,
  NoteDetail detail,
) {
  final target = _map(note['target']);
  final name = _string(target['widget']) ?? '?';
  final body = switch (detail) {
    NoteDetail.compact => _location(note),
    NoteDetail.standard => _standard(note).split('\n').skip(2).toList(),
    NoteDetail.full => [
      ..._standard(note).split('\n').skip(2),
      for (final MapEntry(:key, :value) in _map(target['properties']).entries)
        if (value is String) '  $key: ${_line(value)}',
      if (_string(note['subtree']) case final subtree?) ...[
        'Subtree:',
        for (final line in subtree.split('\n')) '  $line',
      ],
    ],
  };
  return ['$handle: $name', ...body.where((l) => l.isNotEmpty)].join('\n');
}

String _header(Map<String, Object?> note) {
  final id = _string(note['id']) ?? '?';
  final reopened = note['reopened'];
  final parts = [
    ?_string(note['intent']),
    ?_string(note['status']),
    if (reopened is int && reopened > 0)
      reopened == 1 ? 'reopened' : 'reopened $reopened times',
  ];
  return parts.isEmpty ? id : '$id (${parts.join(', ')})';
}

/// What the user said when they last reopened [note], for the compact
/// view: the replies are not in it, and this is the work left to do.
List<String> _reopenedLines(Map<String, Object?> note) {
  final reopened = note['reopened'];
  if (reopened is! int || reopened < 1) return const [];
  for (final m in _list(note['messages']).reversed) {
    final message = _map(m);
    if (_string(message['from']) != 'user') continue;
    final text = _string(message['text']);
    if (text != null) return ['User: ${_line(clipText(text, 200))}'];
  }
  return const [];
}

List<String> _location(Map<String, Object?> note) {
  final target = _map(note['target']);
  final rect = _map(target['rect']);
  final x = _number(rect['x']);
  final y = _number(rect['y']);
  final w = _number(rect['w']);
  final h = _number(rect['h']);
  final description =
      _string(target['description']) ?? _string(target['widget']);
  return [
    if (description != null) 'Target: ${_line(clipText(description, 120))}',
    'Source: ${_where(target['source']) ?? 'unavailable'}',
    if (x != null && y != null && w != null && h != null) 'Rect: $x,$y ${w}x$h',
  ];
}

String _compact(Map<String, Object?> note) {
  final comment = _line(_string(note['comment']) ?? '');
  String build(String text) => [
    _header(note),
    'Comment: $text',
    ..._reopenedLines(note),
    ..._location(note),
  ].join('\n');
  final full = build(comment);
  if (full.length <= maxCompactChars) return full;
  // Cut the comment, never the source: that is what the agent acts on.
  final room = maxCompactChars - build('').length;
  return build(clipText(comment, room < 1 ? 1 : room));
}

String _standard(Map<String, Object?> note) {
  final target = _map(note['target']);
  final page = _map(note['page']);
  final siblings = _map(note['siblings']);
  final shot = _map(note['screenshot']);
  final lines = <String>[
    _header(note),
    'Comment: ${_block(_string(note['comment']) ?? '')}',
    ..._location(note),
  ];
  final enclosing = [
    for (final ancestor in _list(note['ancestors']).take(6))
      if (_map(ancestor) case final a when _string(a['widget']) != null)
        _where(a['source']) == null
            ? _string(a['widget'])!
            : '${_string(a['widget'])} (${_where(a['source'])})',
  ];
  if (enclosing.isNotEmpty) lines.add('Enclosing: ${enclosing.join(' < ')}');
  final constraints = _string(target['constraints']);
  final parent = _string(siblings['parent']);
  final index = siblings['index'];
  final count = siblings['count'];
  final layout = [
    if (constraints != null) 'constraints ${compactConstraints(constraints)}',
    ?_string(target['renderObject']),
    if (parent != null)
      index is int && count is int
          ? 'parent $parent, child ${index + 1} of $count'
          : 'parent $parent',
  ];
  if (layout.isNotEmpty) lines.add('Layout: ${_line(layout.join('  '))}');
  final viewport = _map(page['viewport']);
  final pageParts = [
    ?_string(page['route']) ?? _string(page['url']),
    if (_number(viewport['width']) case final w?)
      if (_number(viewport['height']) case final h?) 'viewport ${w}x$h',
    ?_string(page['brightness']),
  ];
  if (pageParts.isNotEmpty) lines.add('Page: ${_line(pageParts.join('  '))}');
  // From standard up, not only at full as the plan says: a note filed at
  // 360 wide means nothing to an agent that thinks it was 1280.
  if (whatIfLine(note['environment']) case final whatIf?) lines.add(whatIf);
  lines.addAll(findingLines(note));
  lines.addAll(tweakLines(note));
  lines.addAll(verificationLines(note));
  if (_string(shot['file']) case final file?) {
    lines.add(
      'Screenshot: $file (attached, at most 800 px wide)'
      '${shot['beforeAfter'] == true ? ' (left: before the tweaks, right: after)' : ''}',
    );
  }
  final replies = _replies(note);
  if (replies.isNotEmpty) lines.addAll(['Replies:', ...replies]);
  return lines.join('\n');
}

String _full(Map<String, Object?> note) {
  final app = _map(note['app']);
  final page = _map(note['page']);
  final inherited = _map(note['inherited']);
  final environment = [
    ?_string(app['buildMode']),
    ?_string(app['platform']),
    if (_number(page['devicePixelRatio']) case final dpr?) 'dpr $dpr',
    if (_number(page['textScale']) case final scale?) 'textScale $scale',
    ?_string(page['locale']),
    if (_string(inherited['themeBrightness']) case final b?) 'theme $b',
    if (inherited['useMaterial3'] == true) 'Material 3',
    ?_string(inherited['textDirection']),
  ];
  final status = _string(note['status']);
  return [
    markdownFromJson(note).trimRight(),
    if (status == 'submitted') 'Status: submitted',
    if (environment.isNotEmpty) 'Environment: ${_line(environment.join(', '))}',
  ].join('\n');
}

List<String> _replies(Map<String, Object?> note) => [
  for (final m in _list(note['messages']))
    if (_map(m) case final message when _string(message['text']) != null)
      '- ${_string(message['from']) ?? 'agent'}: '
          '${_block(_string(message['text'])!)}',
];

String? _where(Object? source) {
  final s = _map(source);
  final file = _string(s['file']);
  final line = s['line'];
  if (file == null || line is! int) return null;
  final column = s['column'];
  return column is int
      ? '${_line(file)}:$line:$column'
      : '${_line(file)}:$line';
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

String? _string(Object? value) => value is String ? value : null;

String? _number(Object? value) => switch (value) {
  final int n => '$n',
  final double n when n.isFinite =>
    n == n.truncateToDouble() ? '${n.toInt()}' : '$n',
  _ => null,
};

String _line(String text) => text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');

String _block(String text) => [
  for (final (i, line) in text.split(RegExp(r'\r\n?|\n')).indexed)
    i == 0 || line.trim().isEmpty ? line.trimRight() : '  ${line.trimRight()}',
].join('\n');
