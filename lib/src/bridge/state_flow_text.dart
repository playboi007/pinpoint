// Plain Dart with `dart:io` (through [SourceLookup]): no `dart:ui` and no
// `package:flutter`, so `dart run pinpoint:bridge` can run it.
//
// The text of the `state_flow` tool (PLAN-v3 Milestone 21, step 8): the
// app's answer (readers, causes, notifies, rebuilt readers, hints) with the
// code line under each notify and the declaration of each state type, from
// the project's source on this side.

import '../trace/code_lines.dart';
import 'source_lookup.dart';

/// The most characters one answer has (about 4 KB).
const int stateFlowMaxChars = 4000;

/// The most declarations looked up for one answer.
const int stateFlowMaxDeclarations = 6;

/// The answer of `state_flow` as text. [result] is what the app sent.
Future<String> stateFlowText(
  Map<String, Object?> result,
  SourceLookup lookup,
) async {
  final snippets = <String, List<String>?>{};

  Future<List<String>> codeLines(Object? file, Object? line) async {
    if (file is! String || line is! int || line < 1) return const <String>[];
    final key = '$file:$line';
    if (snippets.containsKey(key)) return snippets[key] ?? const <String>[];
    List<String>? shown;
    try {
      final snippet = await lookup.methodLines(file, line);
      shown = codeLinesAt(snippet.text, snippet.start, line);
    } on SourceLookupException {
      shown = null;
    } on Object {
      shown = null;
    }
    snippets[key] = shown;
    return shown ?? const <String>[];
  }

  final declarations = <String, SourceDeclaration?>{};
  Future<SourceDeclaration?> declaration(String type) async {
    if (declarations.containsKey(type)) return declarations[type];
    if (declarations.length >= stateFlowMaxDeclarations) return null;
    SourceDeclaration? found;
    try {
      found = await lookup.declaration(type);
    } on Object {
      found = null;
    }
    return declarations[type] = found;
  }

  final target = _map(result['target']);
  final targetText =
      '${target['type'] ?? '?'}'
      '${target['source'] == null ? '' : ' (${target['source']})'}';
  final armedNow = result['armedNow'] == true;
  final armed = result['armed'] == true;
  final secondsLeft = result['secondsLeft'];
  final window = result['seconds'];
  final lines = <String>['state_flow $targetText'];

  // ----------------------------------------------------------- static part
  final readers = [
    for (final r in _list(result['readers']))
      if (r is Map<String, Object?>) r,
  ];
  final causes = [
    for (final c in _list(result['causes']))
      if (c is Map<String, Object?>) c,
  ];
  if (armedNow) {
    lines.add(
      'Armed for ${window ?? 30} s: act now (run_steps), then call '
      'state_flow again.',
    );
    lines.add(await _readsText(readers, declaration));
  }

  // ------------------------------------------------------------ the chain
  final chain = <String>[];
  if (!armedNow || causes.isNotEmpty) {
    if (causes.isEmpty) {
      chain.add(
        armed
            ? 'No state change yet ($secondsLeft s left). Act now '
                  '(run_steps), then call state_flow again.'
            : 'The window ended (${result['ended'] ?? 'ended'}) with no state '
                  'change on this target. Call state_flow with rearm: true to '
                  'listen again.',
      );
    } else {
      chain.add(
        armed
            ? 'Chain since arming ($secondsLeft s left):'
            : 'Chain since arming (window ended: '
                  '${result['ended'] ?? 'ended'}):',
      );
    }
  }
  final blocks = <String>[];
  for (final cause in causes) {
    blocks.add(await _causeText(cause, codeLines));
  }
  final earlier = result['earlierCauses'];

  // ---------------------------------------------------------------- notes
  final tail = <String>[];
  if (!armedNow && readers.isNotEmpty && causes.isNotEmpty) {
    // Where the types are declared, one line.
    final types = <String>{};
    for (final c in causes) {
      for (final n in _list(c['notifies'])) {
        if (n is Map<String, Object?> && n['owner'] is String) {
          types.add(_baseType(n['owner']! as String));
        }
      }
    }
    final found = <String>[];
    for (final type in types) {
      final d = await declaration(type);
      if (d != null) found.add('$type ${d.file}:${d.line}');
    }
    if (found.isNotEmpty) tail.add('Declared: ${found.join('; ')}');
  }
  if (result['dropped'] is int) {
    tail.add(
      'Note: ${result['dropped']} setState stacks were dropped (the cap).',
    );
  }
  for (final note in _list(result['notes'])) {
    tail.add('Note: $note');
  }

  // ----------------------------------------------------------- the budget
  // The newest causes matter most: they are kept, the oldest go.
  final fixed = [...lines, ...chain, ...tail].join('\n').length;
  var room = stateFlowMaxChars - fixed - 60;
  final keep = <String>[];
  for (final block in blocks.reversed) {
    if (block.length + 1 > room && keep.isNotEmpty) break;
    keep.insert(0, block);
    room -= block.length + 1;
  }
  final cut = blocks.length - keep.length + (earlier is int ? earlier : 0);
  final out = [
    ...lines,
    ...chain,
    if (cut > 0) '($cut earlier causes not shown)',
    ...keep,
    ...tail,
  ].join('\n');
  return out.length <= stateFlowMaxChars
      ? out
      : '${out.substring(0, stateFlowMaxChars - 20)}\n... (cut)';
}

Future<String> _readsText(
  List<Map<String, Object?>> readers,
  Future<SourceDeclaration?> Function(String type) declaration,
) async {
  if (readers.isEmpty) {
    return 'Reads no state object of the project (no provider, notifier or '
        'inherited widget of the app above this widget).';
  }
  final out = <String>['Reads:'];
  for (final reader in readers) {
    out.add(
      '  ${reader['type']} (${reader['kind']}'
      '${_at(reader['source'], ', ')})',
    );
    final dependencies = _list(reader['dependencies']);
    if (dependencies.isEmpty) {
      out.add('    no state object read');
    }
    for (final d in dependencies) {
      if (d is! Map<String, Object?>) continue;
      final type = '${d['type']}';
      final decl = await declaration(_baseType(type));
      final made = _at(d['source'], ', made at ');
      out.add(
        '    ${d['type']} ${d['tag']} (${d['kind']}$made'
        '${decl == null ? '' : ', class at ${decl.file}:${decl.line}'})',
      );
    }
    final own = '${reader['type']}';
    if (_list(reader['dependencies']).isEmpty && own.isNotEmpty) {
      final decl = await declaration(_baseType(own));
      if (decl != null) out.add('    class at ${decl.file}:${decl.line}');
    }
  }
  return out.join('\n');
}

Future<String> _causeText(
  Map<String, Object?> cause,
  Future<List<String>> Function(Object? file, Object? line) codeLines,
) async {
  final out = <String>[];
  final id = cause['cause'];
  final entry = cause['entry'];
  out.add(
    id is int
        ? '${entry is String ? entry : cause['kind'] ?? 'a change'} '
              '(cause c$id)'
        : 'a change in frame f${cause['frame']} (no cause recorded)',
  );
  for (final raw in _list(cause['notifies'])) {
    if (raw is! Map<String, Object?>) continue;
    final method = _methodText(raw['method']);
    final values = raw.containsKey('after')
        ? '  ${raw['before']} -> ${raw['after']}'
        : '';
    final depth = raw['depth'];
    final nested = depth is int && depth > 1 ? '  (inside another notify)' : '';
    final tag = raw['tag'] is String ? ' ${raw['tag']}' : '';
    out.add(
      ' └ ${raw['owner']}$tag notified'
      '${method.isEmpty ? '' : '   $method'}'
      '${_whereText(raw['file'], raw['line'])}$values$nested',
    );
    out.addAll(_codeText(await codeLines(raw['file'], raw['line'])));
  }
  if (cause['moreNotifies'] is int) {
    out.add('   (${cause['moreNotifies']} more notifies)');
  }
  for (final raw in _list(cause['setStates'])) {
    if (raw is! Map<String, Object?>) continue;
    final method = _methodText(raw['method']);
    out.add(
      ' └ ${raw['widget']} setState'
      '${method.isEmpty ? '' : '   $method'}'
      '${_whereText(raw['file'], raw['line'])}',
    );
    out.addAll(_codeText(await codeLines(raw['file'], raw['line'])));
  }
  if (cause['moreSetStates'] is int) {
    out.add('   (${cause['moreSetStates']} more setStates)');
  }
  final rebuilt = [
    for (final r in _list(cause['rebuilt']))
      if (r is Map<String, Object?>) r,
  ];
  if (rebuilt.isEmpty) {
    // Only news for a notify: a setState rebuilds its own widget.
    if (_list(cause['notifies']).isNotEmpty) {
      out.add(' └ no rebuilt reader seen for it');
    }
  } else {
    out.add(' └ rebuilt because they read it:');
    final sharedTags = <String, Set<Object?>>{};
    for (final r in rebuilt) {
      final tag = r['tag'];
      if (tag is String && r['via'] != 'setState') {
        sharedTags.putIfAbsent(tag, () => <Object?>{}).add(r['type']);
      }
    }
    final width = rebuilt.fold<int>(
      0,
      (w, r) => '${r['type']}'.length > w ? '${r['type']}'.length : w,
    );
    for (final r in rebuilt) {
      final why = switch (r['via']) {
        'dependency' => 'dependencies: ${r['owner']} ${r['tag']}',
        'builder' => 'listens to ${r['owner']} ${r['tag']}',
        _ => 'its own setState',
      };
      final shared =
          r['tag'] is String && (sharedTags[r['tag']]?.length ?? 0) > 1
          ? '   <- same object'
          : '';
      out.add(
        '     ${'${r['type']}'.padRight(width)}   '
        '($why)$shared',
      );
    }
    if (cause['moreRebuilt'] is int) {
      out.add('     (${cause['moreRebuilt']} more)');
    }
  }
  if (cause['hint'] is String) out.add(' hint: ${cause['hint']}');
  return out.join('\n');
}

/// The code lines of a notify, as one line when they are short.
List<String> _codeText(List<String> lines) {
  if (lines.isEmpty) return const <String>[];
  final joined = lines.join(' ');
  if (joined.length <= 110) return ['     code:  $joined'];
  return ['     code:', for (final line in lines) '       $line'];
}

/// `Class.method` as `method()`; a top-level function keeps its name.
String _methodText(Object? method) {
  if (method is! String || method.isEmpty) return '';
  final dot = method.lastIndexOf('.');
  final name = dot < 0 ? method : method.substring(dot + 1);
  return name.isEmpty ? '' : '$name()';
}

/// `  lib/x.dart:88` for a frame's file and line; a `package:app/x.dart` file
/// shows as `lib/x.dart`.
String _whereText(Object? file, Object? line) {
  if (file is! String || file.isEmpty) return '';
  var shown = file;
  if (shown.startsWith('package:')) {
    final slash = shown.indexOf('/');
    shown = slash < 0 ? shown : 'lib/${shown.substring(slash + 1)}';
  }
  return '  $shown${line is int && line > 0 ? ':$line' : ''}';
}

/// `, lib/x.dart:12` for a `{file, line}` source, or empty.
String _at(Object? source, String prefix) {
  if (source is! Map<String, Object?>) return '';
  final file = source['file'];
  if (file is! String) return '';
  final line = source['line'];
  return '$prefix$file${line is int ? ':$line' : ''}';
}

String _baseType(String type) {
  final open = type.indexOf('<');
  return open < 0 ? type : type.substring(0, open);
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];
