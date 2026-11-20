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

  // Only once the agent or the user moved the note on: a sent note is
  // `submitted`, and a copied one is still a `draft`.
  final status = _string(json['status']);
  if (status != null && status != 'submitted' && status != 'draft') {
    out.writeln('Status: ${_line(status)}');
  }
  // A reopened note is submitted again: say so, or a file-inbox agent
  // takes it for new work and misses the user's reason.
  final reopened = json['reopened'];
  if (reopened is int && reopened > 0) {
    out.writeln(
      'Reopened by the user${reopened > 1 ? ' ($reopened times)' : ''}: '
      'their reason is the last reply.',
    );
  }

  final widget = _string(target['widget']);
  final description = _string(target['description']) ?? widget;
  if (description != null) out.writeln('Target: ${_line(description)}');
  final text = _string(target['text']);
  if (text != null &&
      text.isNotEmpty &&
      !(description?.contains(text) ?? false)) {
    out.writeln('Text: ${_block(text)}');
  }

  final root = projectRootOf(json);
  if (root != null) out.writeln('Root: ${_line(root)}');
  final source = _where(target['source'], column: true, root: root);
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

  if (enclosingLine(json) case final enclosing?) out.writeln(enclosing);

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
  if (whatIfLine(json['environment']) case final whatIf?) out.writeln(whatIf);
  findingLines(json).forEach(out.writeln);
  tweakLines(json).forEach(out.writeln);
  verificationLines(json).forEach(out.writeln);

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
  if (stateOwnersLine(json) case final owners?) out.writeln(owners);

  final file = _string(shot['file']);
  if (file != null) {
    final debugPaint = [
      for (final flag in _list(shot['debugPaint'])) ?_string(flag),
    ];
    out.writeln(
      'Screenshot: ${_line(file)}'
      '${shot['beforeAfter'] == true ? ' (left: before the tweaks, right: after)' : ''}'
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

  final replies = [
    for (final m in _list(json['messages']))
      if (_map(m) case final message when _string(message['text']) != null)
        '- ${_line(_string(message['from']) ?? 'agent')}'
            '${_string(message['at']) == null ? '' : ' (${_line(_string(message['at'])!)})'}'
            ': ${_block(_string(message['text'])!)}',
  ];
  if (replies.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Replies:');
    replies.forEach(out.writeln);
  }

  final happened = [?tapeLine(json['tape']), ...whatHappenedLines(json)];
  if (happened.isNotEmpty) {
    out.writeln();
    happened.forEach(out.writeln);
  }

  final subtree = _string(json['subtree']);
  if (subtree != null && subtree.isNotEmpty) {
    out
      ..writeln()
      ..writeln('Subtree:');
    for (final line in subtreeLines(json)) {
      out.writeln('  $line');
    }
  }
  return out.toString();
}

/// The "What happened" section of a note (its `trace` JSON): a heading,
/// then the compact trace lines indented. Empty without a trace.
List<String> whatHappenedLines(Map<String, Object?> json) {
  final trace = _map(json['trace']);
  // "rebuilds not recorded" says nothing about the problem (PLAN-v3
  // Milestone 19, step 9): the lines of the run stay, that one goes.
  final lines = [
    for (final l in _list(trace['lines']))
      if (_string(l) case final line? when !line.startsWith(traceNotRecorded))
        line,
  ];
  if (lines.isEmpty) return const <String>[];
  final seconds = _number(trace['seconds']);
  final partial = trace['partial'] == true;
  return [
    'What happened${seconds == null ? '' : ' ($seconds s before the pick)'}'
        '${partial ? ' (partial: ${_line(_string(trace['reason']) ?? 'older events dropped')})' : ''}:',
    for (final line in lines) '  ${_line(line)}',
  ];
}

/// The tape line of a note (its `tape` JSON), for example `Tape:
/// tp_… (full, 12 inputs, 3 requests, 1 mark). Replay it with replay.`,
/// or null without a tape (PLAN-v2 Milestone 15, step 18).
String? tapeLine(Object? tape) {
  final t = _map(tape);
  final id = _string(t['id']);
  if (id == null) return null;
  String count(String key, String word) {
    final n = _number(t[key]) ?? 0;
    return '$n $word${n == 1 ? '' : 's'}';
  }

  final partial = t['partial'];
  return 'Tape: $id (${_string(t['kind']) ?? 'segment'}, '
      '${count('inputs', 'input')}, ${count('requests', 'request')}, '
      '${count('marks', 'mark')}'
      '${partial == null || partial == false ? '' : ', partial: ${_line('$partial')}'}'
      '). Replay it with replay({tape: "$id"}).';
}

/// The what-if overrides of a note (its `environment` JSON) on one line,
/// for example `What-if: viewport 360x800, textScale 1.5, rtl`, or null
/// when there are none. A field of the wrong type is skipped.
String? whatIfLine(Object? environment) {
  final env = _map(environment);
  final viewport = _map(env['viewport']);
  final width = _number(viewport['width']);
  final height = _number(viewport['height']);
  final safe = _map(env['safeArea']);
  final insets = [
    for (final side in ['left', 'top', 'right', 'bottom']) _number(safe[side]),
  ];
  final parts = [
    if (width != null && height != null) 'viewport ${width}x$height',
    if (_number(env['textScale']) case final t?) 'textScale $t',
    if (env['boldText'] == true) 'boldText',
    if (insets.every((i) => i != null)) 'safeArea ${insets.join(',')}',
    if (_number(env['keyboardHeight']) case final k?) 'keyboard $k',
    ?_string(env['textDirection']),
    ?_string(env['brightness']),
    if (_string(env['themeVariant']) case final t?) 'theme $t',
    if (_string(env['seedColor']) case final c?) 'seed $c',
    if (_string(env['platform']) case final p?) 'platform $p',
    if (_number(env['timeDilation']) case final d?) 'slow motion ${d}x',
  ];
  return parts.isEmpty ? null : 'What-if: ${_line(parts.join(', '))}';
}

/// The finding a note was made from and its suggested checks, for example
/// `Found: overflow (error): Row overflows by 23 px on the right` and
/// `Checks: no_overflow`. Empty for a note written by hand; a field of the
/// wrong type is skipped.
List<String> findingLines(Map<String, Object?> json) {
  final finding = _map(json['finding']);
  final kind = _string(finding['kind']);
  final severity = _string(finding['severity']);
  final summary = _string(finding['summary']);
  final checks = [
    for (final check in _list(json['checks']))
      if (_string(_map(check)['type']) case final type?)
        _checkLabel(type, _map(check)),
  ];
  return [
    if (kind != null && summary != null)
      _line('Found: $kind${severity == null ? '' : ' ($severity)'}: $summary'),
    if (checks.isNotEmpty) _line('Checks: ${checks.join(', ')}'),
  ];
}

/// The outcome of the last `verify_note`: `Verification: failed (0 of 1
/// checks passed, at 2026-11-11T10:05:00Z)`, then one line per check, for
/// example `- FAIL no_overflow: Row overflows by 72 px on the right`.
/// Empty before a verification ran.
List<String> verificationLines(Map<String, Object?> json) {
  final verification = _map(json['verification']);
  final passed = verification['passed'];
  if (passed is! bool) return const <String>[];
  final checks = [
    for (final c in _list(verification['checks']))
      if (_map(c) case final check when _string(check['type']) != null) check,
  ];
  final count = checks.where((c) => c['passed'] == true).length;
  final at = _string(verification['at']);
  final after = _string(verification['after']);
  return [
    _line(
      'Verification: ${passed ? 'passed' : 'failed'} ($count of '
      '${checks.length} checks passed${at == null ? '' : ', at $at'})',
    ),
    for (final check in checks)
      _line(
        '- ${check['passed'] == true ? 'PASS' : 'FAIL'} ${check['type']}'
        '${_string(check['message']) == null ? '' : ': ${check['message']}'}',
      ),
    if (after != null) 'After screenshot: $after',
  ];
}

/// What the agent is to do with a note's tweaks (plan Milestone 11, step
/// 10).
const String tweakInstruction =
    'Apply these as source changes. A value may come from a theme or design '
    'token; change the token only if every use should change.';

/// A note's tweaks: the instruction, then one line per edit, for example
/// `- padding: EdgeInsets.all(8.0) -> EdgeInsets.all(16.0) (RenderPadding
/// from Padding, in Container at lib/widgets/save_bar.dart:31:12)`. Empty
/// without tweaks; a malformed one is skipped.
List<String> tweakLines(Map<String, Object?> json) {
  final root = projectRootOf(json);
  final lines = <String>[];
  for (final item in _list(json['tweaks'])) {
    final tweak = _map(item);
    final property = _string(tweak['property']);
    final from = _string(tweak['from']);
    final to = _string(tweak['to']);
    if (property == null || from == null || to == null) continue;
    final local = _map(tweak['nearestLocal']);
    final widget = _string(local['widget']);
    final where = _where(local['source'], column: true, root: root);
    final maker = [
      ?_string(tweak['renderType']),
      if (_string(tweak['createdBy']) case final by?) 'from $by',
    ].join(' ');
    final made = [
      if (maker.isNotEmpty) maker,
      if (widget != null) where == null ? 'in $widget' : 'in $widget at $where',
    ].join(', ');
    lines.add(
      _line('- $property: $from -> $to${made.isEmpty ? '' : ' ($made)'}'),
    );
  }
  return lines.isEmpty ? lines : ['Tweaks: $tweakInstruction', ...lines];
}

/// `tap_target_min (min 48)`: the type, then its other fields.
String _checkLabel(String type, Map<String, Object?> check) {
  final args = [
    for (final MapEntry(:key, :value) in check.entries)
      if (key != 'type')
        if (_number(value) ?? _string(value) case final v?) '$key $v',
  ];
  return args.isEmpty ? type : '$type (${args.join(', ')})';
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

/// `file:line`, or `file:line:column` with [column], or null. A file
/// under [root] is printed relative to it.
String? _where(Object? source, {bool column = false, String? root}) {
  final s = _map(source);
  final file = _string(s['file']);
  final line = s['line'];
  if (file == null || line is! int) return null;
  final col = s['column'];
  final name = _line(shortFile(file, root));
  return column && col is int ? '$name:$line:$col' : '$name:$line';
}

/// The project folder of [json] (a note), without a trailing slash, or
/// null when the note has none. The app sets it with `PINPOINT_ROOT`; the
/// bridge fills it in when the app did not.
String? projectRootOf(Map<String, Object?> json) {
  final root = _string(_map(json['app'])['projectRoot']);
  if (root == null || root.trim().isEmpty) return null;
  return root.length > 1 && root.endsWith('/')
      ? root.substring(0, root.length - 1)
      : root;
}

/// [file] relative to [root] when it is under it, else as it is.
String shortFile(String file, String? root) =>
    root != null && file.startsWith('$root/')
    ? file.substring(root.length + 1)
    : file;

/// The `Enclosing:` line of [json] (a note), nearest first, or null
/// without ancestors. The file is printed once per run of rows from one
/// file, relative to the root: `Container (a/b.dart:45) < BxLandmark :43 <
/// DetailToolbar (c.dart:278)`. [max] cuts the list.
String? enclosingLine(Map<String, Object?> json, {int? max}) {
  final root = projectRootOf(json);
  final items = <String>[];
  String? previous;
  for (final ancestor in _list(json['ancestors'])) {
    if (max != null && items.length >= max) break;
    final a = _map(ancestor);
    final widget = _string(a['widget']);
    if (widget == null) continue;
    final source = _map(a['source']);
    final file = _string(source['file']);
    final line = source['line'];
    if (file == null || line is! int) {
      items.add(_line(widget));
    } else if (file == previous) {
      items.add('${_line(widget)} :$line');
    } else {
      items.add('${_line(widget)} (${_line(shortFile(file, root))}:$line)');
    }
    if (file != null && line is int) previous = file;
  }
  return items.isEmpty ? null : 'Enclosing: ${items.join(' < ')}';
}

/// The rows of a note's `subtree` as text (`Name  file:line`), with each
/// file relative to the root and printed once per run of rows from one
/// file: later rows show `Name  :line`. Empty without a subtree.
List<String> subtreeLines(Map<String, Object?> json) {
  final subtree = _string(json['subtree']);
  if (subtree == null || subtree.isEmpty) return const <String>[];
  final root = projectRootOf(json);
  final row = RegExp(r'^(\s*)(.*)  (\S.*?):(\d+)( …)?$');
  final out = <String>[];
  String? previous;
  for (final line in subtree.split('\n')) {
    final match = row.firstMatch(line);
    if (match == null) {
      out.add(line);
      continue;
    }
    final file = match[3]!;
    final where = file == previous
        ? ':${match[4]}'
        : '${shortFile(file, root)}:${match[4]}';
    previous = file;
    out.add('${match[1]}${match[2]}  $where${match[5] ?? ''}');
  }
  return out;
}

/// The `State owners:` line of [json] (a note), for example `State owners:
/// state _CartState (lib/cart.dart:12), provider CartModel`, or null
/// without any.
String? stateOwnersLine(Map<String, Object?> json) {
  final root = projectRootOf(json);
  final owners = [
    for (final o in _list(json['stateOwners']))
      if (_map(o) case final owner
          when _string(owner['kind']) != null && _string(owner['type']) != null)
        '${_line(_string(owner['kind'])!)} ${_line(_string(owner['type'])!)}'
            '${_where(owner['source'], root: root) == null ? '' : ' (${_where(owner['source'], root: root)})'}',
  ];
  return owners.isEmpty ? null : 'State owners: ${owners.join(', ')}';
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
