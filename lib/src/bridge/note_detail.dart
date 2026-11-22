// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge's MCP
// tools format notes with this.

import '../model/annotation.dart' show clipText;
import '../model/json_read.dart';
import '../model/note_round.dart';
import '../sink/markdown_formatter.dart';

/// How much of a note an MCP tool returns. More detail costs the agent
/// more context.
enum NoteDetail {
  /// The comment, the source and the rect: enough to find the code.
  compact,

  /// Adds the layout, the enclosing widgets, the page and the replies.
  /// The default, and the text of the `.md` file on disk.
  standard,

  /// Everything: adds the properties, the subtree, the state owners and
  /// the environment.
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
  final target = asJsonMap(note['target']);
  final name = asString(target['widget']) ?? '?';
  final body = switch (detail) {
    NoteDetail.compact => _location(note),
    NoteDetail.standard => _standard(note).split('\n').skip(2).toList(),
    NoteDetail.full => [
      ..._standard(note).split('\n').skip(2),
      for (final MapEntry(:key, :value) in asJsonMap(
        target['properties'],
      ).entries)
        if (value is String) '  $key: ${_line(value)}',
      if (subtreeLines(note) case final rows when rows.isNotEmpty) ...[
        'Subtree:',
        for (final line in rows) '  $line',
      ],
    ],
  };
  return ['$handle: $name', ...body.where((l) => l.isNotEmpty)].join('\n');
}

String _header(Map<String, Object?> note) {
  final id = asString(note['id']) ?? '?';
  final reopened = note['reopened'];
  final parts = [
    ?asString(note['intent']),
    ?asString(note['status']),
    if (reopened is int && reopened > 0)
      reopened == 1 ? 'reopened' : 'reopened $reopened times',
    // PLAN-v2 Milestone 15, step 18: the agent can replay what the user
    // did.
    if (note['tape'] is Map<String, Object?>) 'has tape',
  ];
  return parts.isEmpty ? id : '$id (${parts.join(', ')})';
}

/// What the user said when they last reopened [note], for the compact
/// view: the replies are not in it, and this is the work left to do.
List<String> _reopenedLines(Map<String, Object?> note) {
  final reopened = note['reopened'];
  if (reopened is! int || reopened < 1) return const [];
  for (final m in asJsonList(note['messages']).reversed) {
    final message = asJsonMap(m);
    if (asString(message['from']) != 'user') continue;
    final text = asString(message['text']);
    if (text != null) return ['User: ${_line(clipText(text, 200))}'];
  }
  return const [];
}

List<String> _location(Map<String, Object?> note) {
  final target = asJsonMap(note['target']);
  final rect = asJsonMap(target['rect']);
  final x = jsonNumberText(rect['x']);
  final y = jsonNumberText(rect['y']);
  final w = jsonNumberText(rect['w']);
  final h = jsonNumberText(rect['h']);
  final description =
      asString(target['description']) ?? asString(target['widget']);
  return [
    if (description != null) 'Target: ${_line(clipText(description, 120))}',
    'Source: ${_where(target['source'], root: projectRootOf(note)) ?? 'unavailable'}',
    if (x != null && y != null && w != null && h != null) 'Rect: $x,$y ${w}x$h',
  ];
}

String _compact(Map<String, Object?> note) {
  final comment = _line(asString(note['comment']) ?? '');
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

String _standard(Map<String, Object?> note) => _standardLines(note).join('\n');

/// The standard text, one line per entry. PLAN-v3 Milestone 19, step 9:
/// what finds and explains the problem, and no more. The properties, the
/// subtree, the state owners and the environment are [NoteDetail.full].
///
/// [onDisk] is for the `.md` next to the note's files: there the screenshot
/// is the full-size file beside it, not the MCP attachment.
List<String> _standardLines(Map<String, Object?> note, {bool onDisk = false}) {
  final target = asJsonMap(note['target']);
  final page = asJsonMap(note['page']);
  final siblings = asJsonMap(note['siblings']);
  final shot = asJsonMap(note['screenshot']);
  final root = projectRootOf(note);
  final description =
      asString(target['description']) ?? asString(target['widget']);
  final text = asString(target['text']);
  final reopened = note['reopened'];
  final lines = <String>[
    _header(note),
    'Comment: ${_block(asString(note['comment']) ?? '')}',
    // The reason is the last reply; a file reader must not take a
    // reopened note for new work.
    if (reopened is int && reopened > 0)
      'Reopened by the user${reopened > 1 ? ' ($reopened times)' : ''}: '
          'their reason is the last reply.',
    if (description != null) 'Target: ${_line(clipText(description, 120))}',
    if (text != null &&
        text.isNotEmpty &&
        !(description?.contains(text) ?? false))
      'Text: ${_block(text)}',
    if (root != null) 'Root: ${_line(root)}',
    'Source: ${_where(target['source'], root: root) ?? 'unavailable'}',
  ];
  if (enclosingLine(note, max: 6) case final enclosing?) lines.add(enclosing);
  final rect = asJsonMap(target['rect']);
  final x = jsonNumberText(rect['x']);
  final y = jsonNumberText(rect['y']);
  final w = jsonNumberText(rect['w']);
  final h = jsonNumberText(rect['h']);
  final constraints = asString(target['constraints']);
  final parent = asString(siblings['parent']);
  final index = siblings['index'];
  final count = siblings['count'];
  final layout = [
    if (x != null && y != null && w != null && h != null) 'rect $x,$y ${w}x$h',
    if (constraints != null) 'constraints ${compactConstraints(constraints)}',
    ?asString(target['renderObject']),
    if (parent != null)
      index is int && count is int
          ? 'parent $parent, child ${index + 1} of $count'
          : 'parent $parent',
  ];
  if (layout.isNotEmpty) lines.add('Layout: ${_line(layout.join('  '))}');
  final viewport = asJsonMap(page['viewport']);
  final pageParts = [
    ?asString(page['route']) ?? asString(page['url']),
    if (jsonNumberText(viewport['width']) case final w?)
      if (jsonNumberText(viewport['height']) case final h?) 'viewport ${w}x$h',
    ?asString(page['brightness']),
  ];
  if (pageParts.isNotEmpty) lines.add('Page: ${_line(pageParts.join('  '))}');
  // From standard up, not only at full as the plan says: a note filed at
  // 360 wide means nothing to an agent that thinks it was 1280.
  if (whatIfLine(note['environment']) case final whatIf?) lines.add(whatIf);
  lines.addAll(findingLines(note));
  lines.addAll(tweakLines(note));
  lines.addAll(verificationLines(note));
  if (asString(shot['file']) case final file?) {
    lines.add(
      'Screenshot: $file'
      '${onDisk ? '' : ' (attached, at most 800 px wide)'}'
      '${shot['hasPlatformViews'] == true ? ' (platform views show blank)' : ''}'
      '${shot['beforeAfter'] == true ? ' (left: before the tweaks, right: after)' : ''}',
    );
  }
  lines.addAll(roundLines(note));
  final replies = _replies(note);
  if (replies.isNotEmpty) lines.addAll(['Replies:', ...replies]);
  if (tapeLine(note['tape']) case final line?) lines.add(line);
  lines.addAll(whatHappenedLines(note));
  return lines;
}

/// The standard text and what only [NoteDetail.full] shows.
String _full(Map<String, Object?> note) {
  final app = asJsonMap(note['app']);
  final page = asJsonMap(note['page']);
  final inherited = asJsonMap(note['inherited']);
  final environment = [
    ?asString(app['buildMode']),
    ?asString(app['platform']),
    if (jsonNumberText(page['devicePixelRatio']) case final dpr?) 'dpr $dpr',
    if (jsonNumberText(page['textScale']) case final scale?) 'textScale $scale',
    ?asString(page['locale']),
    if (asString(inherited['themeBrightness']) case final b?) 'theme $b',
    if (inherited['useMaterial3'] == true) 'Material 3',
    ?asString(inherited['textDirection']),
  ];
  final properties = [
    for (final MapEntry(:key, :value) in asJsonMap(
      asJsonMap(note['target'])['properties'],
    ).entries)
      if (asString(value) case final v?) '$key=$v',
  ];
  final errors = [for (final e in asJsonList(note['errors'])) ?asString(e)];
  final truncated = [
    for (final t in asJsonList(note['truncated'])) ?asString(t),
  ];
  final subtree = subtreeLines(note);
  return [
    ..._standardLines(note),
    if (properties.isNotEmpty) 'Properties: ${_line(properties.join(', '))}',
    ?stateOwnersLine(note),
    ...dependencyLines(note),
    if (environment.isNotEmpty) 'Environment: ${_line(environment.join(', '))}',
    if (errors.isNotEmpty) 'Not collected: ${_line(errors.join(', '))}',
    if (truncated.isNotEmpty) 'Truncated: ${_line(truncated.join(', '))}',
    if (subtree.isNotEmpty) ...['Subtree:', for (final l in subtree) '  $l'],
  ].join('\n');
}

/// One line for each state owner that reads state objects (PLAN-v3
/// Milestone 21, step 1), for example `Reads: _CartState: provider CartModel
/// #a1 (lib/cart_model.dart:9), inherited Flags #a2`. The same tag on two
/// lines is one object.
List<String> dependencyLines(Map<String, Object?> note) {
  final root = projectRootOf(note);
  return [
    for (final o in asJsonList(note['stateOwners']))
      if (asJsonMap(o) case final owner)
        if ([
              for (final d in asJsonList(owner['dependencies']))
                if (asJsonMap(d) case final dep
                    when asString(dep['kind']) != null &&
                        asString(dep['type']) != null)
                  '${_line(asString(dep['kind'])!)} ${_line(asString(dep['type'])!)}'
                      '${asString(dep['tag']) == null ? '' : ' ${_line(asString(dep['tag'])!)}'}'
                      '${_where(dep['source'], root: root) == null ? '' : ' (${_where(dep['source'], root: root)})'}',
            ]
            case final deps when deps.isNotEmpty)
          'Reads: ${_line(asString(owner['type']) ?? '?')}: ${deps.join(', ')}',
  ];
}

/// One short line for each round the agent closed (PLAN-v3 Milestone 20),
/// for example `Round 2 (undone by user: c1; kept: c2)`. A round the user
/// did not undo says what changed: `Round 1 (changed: c1, c2)`. After a
/// request the agent has to do, it says `undo requested of: c1`.
List<String> roundLines(Map<String, Object?> note) {
  final lines = <String>[];
  for (final json in asJsonList(note['rounds'])) {
    final round = json is Map<String, Object?>
        ? NoteRound.fromJson(json)
        : null;
    if (round == null || round.isOpen || round.changes.isEmpty) continue;
    final ids = [for (final c in round.changes) c.id];
    final undone = [
      for (final id in ids)
        if (round.isUndone(id)) id,
    ];
    final kept = [
      for (final id in ids)
        if (!round.isUndone(id)) id,
    ];
    final what = undone.isEmpty
        ? 'changed: ${ids.join(', ')}'
        : '${round.undo == RoundUndo.done ? 'undone by user' : 'undo requested of'}'
              ': ${undone.join(', ')}'
              '${kept.isEmpty ? '' : '; kept: ${kept.join(', ')}'}';
    lines.add('Round ${round.n} ($what)');
  }
  return lines;
}

/// The `.md` the bridge writes beside a note's JSON: the standard text,
/// and one line that says where the rest is.
String noteMarkdown(Map<String, Object?> note) {
  final id = asString(note['id']) ?? '<id>';
  return '${_standardLines(note, onDisk: true).join('\n')}\n'
      'More: get_note detail full, or $id.json\n';
}

List<String> _replies(Map<String, Object?> note) => [
  for (final m in asJsonList(note['messages']))
    if (asJsonMap(m) case final message when asString(message['text']) != null)
      '- ${asString(message['from']) ?? 'agent'}: '
          '${_block(asString(message['text'])!)}',
];

String? _where(Object? source, {String? root}) {
  final s = asJsonMap(source);
  final file = asString(s['file']);
  final line = s['line'];
  if (file == null || line is! int) return null;
  final column = s['column'];
  final name = _line(shortFile(file, root));
  return column is int ? '$name:$line:$column' : '$name:$line';
}

String _line(String text) => text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');

String _block(String text) => [
  for (final (i, line) in text.split(RegExp(r'\r\n?|\n')).indexed)
    i == 0 || line.trim().isEmpty ? line.trimRight() : '  ${line.trimRight()}',
].join('\n');
