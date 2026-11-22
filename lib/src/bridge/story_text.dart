// Plain Dart with `dart:io` (through [SourceLookup]): no `dart:ui` and no
// `package:flutter`, so `dart run pinpoint:bridge` can run it.
//
// The story as plain text, for `state_flow`. It
// reads the same [Story] blocks as the watch card and says the same words
// ([storyName], [rowHeadline], [changesText]); the code lines and the names
// from the code come from the project's source on this side.

import '../trace/code_lines.dart';
import '../trace/story.dart';
import '../trace/story_names.dart';
import 'source_lookup.dart';

/// The lines of [story] (oldest first), within [budget] characters: the
/// newest blocks are kept and the oldest are counted.
Future<List<String>> storyLines(
  Story story,
  SourceLookup lookup, {
  int budget = 3000,
}) async {
  final snippets = <String, SourceSnippet?>{};
  Future<SourceSnippet?> snippet(String file, int line, int before) async {
    final key = '$file:$line:$before';
    if (snippets.containsKey(key)) return snippets[key];
    SourceSnippet? found;
    try {
      found = await lookup.methodLines(file, line, before: before);
    } on Object {
      found = null;
    }
    return snippets[key] = found;
  }

  Future<List<String>> code(Object? file, Object? line) async {
    if (file is! String || line is! int || line < 1) return const <String>[];
    final found = await snippet(file, line, 15);
    return found == null
        ? const <String>[]
        : codeLinesAt(found.text, found.start, line);
  }

  // Rung 2 of the name ladder: the expression at the creating line.
  Future<String?> expression(StoryRow row) async {
    final src = row.src;
    final arg = row.srcArg;
    if (src == null || arg == null || !isFrameworkType(row.base)) return null;
    final colon = src.lastIndexOf(':');
    final line = colon < 0 ? null : int.tryParse(src.substring(colon + 1));
    if (line == null) return null;
    final found = await snippet(src.substring(0, colon), line, 0);
    return found == null ? null : expressionFromSource(found.text, arg);
  }

  final blocks = <List<String>>[];
  for (final item in story.timeline) {
    if (item is StoryEnd) {
      blocks.add(['${formatStoryAt(item.at)}  ${item.text}']);
      continue;
    }
    final block = item as StoryBlock;
    final out = <String>['${blockTime(block)}  ${causeLine(block)}'];
    for (final row in block.rows) {
      final name = storyName(row, expression: await expression(row));
      final change = changesText(row);
      final where = storyWhere(row.file, row.line);
      final method = storyMethod(row.method);
      out.add(
        ' └ ${rowHeadline(row, name)}'
        '${change.isEmpty ? '' : '  $change'}'
        '${method.isEmpty ? '' : '   $method'}'
        '${where.isEmpty ? '' : '  $where'}',
      );
      final instances = instancesText(row);
      if (instances.isNotEmpty) out.add('     instances: $instances');
      out.addAll(_codeText(await code(row.file, row.line)));
    }
    if (block.droppedRows > 0) {
      out.add('   (${block.droppedRows} more changes in this block)');
    }
    if (block.rebuilt.isNotEmpty) {
      final more = block.rebuiltCount - block.rebuilt.length;
      out.add(
        ' └ rebuilt ${block.rebuiltCount}: ${block.rebuilt.join(', ')}'
        '${more > 0 ? ' (+$more more)' : ''}',
      );
    } else if (story.rebuildsRecorded &&
        block.rows.any((r) => r.kind == 'notify')) {
      out.add(' └ no rebuilt widget seen for it');
    }
    if (block.hint != null) out.add(' hint: ${block.hint}');
    blocks.add(out);
  }

  // The newest blocks matter most.
  var room = budget;
  final keep = <List<String>>[];
  for (final block in blocks.reversed) {
    final size = block.fold<int>(1, (n, l) => n + l.length + 1);
    if (size > room && keep.isNotEmpty) break;
    keep.insert(0, block);
    room -= size;
  }
  final cut = blocks.length - keep.length;
  return [
    if (story.noCauseHint != null) story.noCauseHint!,
    if (story.droppedBlocks > 0 || cut > 0)
      '(${story.droppedBlocks + cut} earlier blocks not shown)',
    for (final block in keep) ...block,
    if (hiddenLine(story) != null)
      'Hidden: ${hiddenLine(story)}. Call state_flow with hover: true or '
          'controllers: true to see them.',
  ];
}

/// The code lines of a notify, as one line when they are short.
List<String> _codeText(List<String> lines) {
  if (lines.isEmpty) return const <String>[];
  final joined = lines.join(' ');
  if (joined.length <= 110) return ['     code:  $joined'];
  return ['     code:', for (final line in lines) '       $line'];
}
