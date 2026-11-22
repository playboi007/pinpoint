// Plain Dart with `dart:io` (through [SourceLookup]): no `dart:ui` and no
// `package:flutter`, so `dart run pinpoint:bridge` can run it.
//
// The text of the `state_flow` tool: what the widget reads, then the story of changes
// per cause, with the code line under each row and the declaration of each
// state type, from the project's source on this side. The story is the same
// [Story] the watch card shows ([storyLines] in `story_text.dart`).

import '../model/json_read.dart';
import '../trace/story.dart';
import '../trace/story_names.dart';
import 'source_lookup.dart';
import 'story_text.dart';

/// The most characters one answer has (about 4 KB).
const int stateFlowMaxChars = 4000;

/// The most declarations looked up for one answer.
const int stateFlowMaxDeclarations = 6;

/// The answer of `state_flow` as text. [result] is what the app sent.
Future<String> stateFlowText(
  Map<String, Object?> result,
  SourceLookup lookup,
) async {
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

  final target = asJsonMap(result['target']);
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
    for (final r in asJsonList(result['readers']))
      if (r is Map<String, Object?>) r,
  ];
  final story = Story.fromJson(result['story']);
  final hasStory = story.hasChanges;
  if (armedNow) {
    lines.add(
      'Armed for ${window ?? 30} s: act now (run_steps), then call '
      'state_flow again.',
    );
    lines.add(await _readsText(readers, declaration));
  }

  // -------------------------------------------------------------- the story
  final chain = <String>[];
  if (!armedNow || hasStory) {
    if (!hasStory) {
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
            ? 'Story since arming, oldest first ($secondsLeft s left):'
            : 'Story since arming, oldest first (window ended: '
                  '${result['ended'] ?? 'ended'}):',
      );
    }
  }

  // ---------------------------------------------------------------- notes
  final tail = <String>[];
  if (!armedNow && readers.isNotEmpty && hasStory) {
    // Where the types are declared, one line.
    final types = <String>{};
    for (final block in story.blocks) {
      for (final row in block.rows) {
        if (row.kind == 'notify' && !isFrameworkType(row.base)) {
          types.add(row.base);
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
  if (story.droppedStacks > 0) {
    tail.add(
      'Note: ${story.droppedStacks} setState stacks were dropped (the cap).',
    );
  }
  for (final note in asJsonList(result['notes'])) {
    tail.add('Note: $note');
  }

  // ----------------------------------------------------------- the budget
  final fixed = [...lines, ...chain, ...tail].join('\n').length;
  final room = stateFlowMaxChars - fixed - 60;
  final body = hasStory
      ? await storyLines(story, lookup, budget: room < 400 ? 400 : room)
      : const <String>[];
  final out = [...lines, ...chain, ...body, ...tail].join('\n');
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
    final dependencies = asJsonList(reader['dependencies']);
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
    if (asJsonList(reader['dependencies']).isEmpty && own.isNotEmpty) {
      final decl = await declaration(_baseType(own));
      if (decl != null) out.add('    class at ${decl.file}:${decl.line}');
    }
  }
  return out.join('\n');
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
