import 'dart:convert';

import '../model/annotation.dart';

/// [note] as Markdown for a coding agent: the instruction and the location
/// first, since that is what the agent acts on, then the whole note as JSON.
///
/// Interim form for Copy as Markdown (Milestone 5). Milestone 7 replaces the
/// JSON block with the planned layout (page, layout, properties, subtree)
/// and fixes it with golden tests.
String markdownFor(Annotation note) {
  String where(SourceRef? source) =>
      source == null ? 'unavailable' : '${source.file}:${source.line}';
  final target = note.target;
  final source = target.source;
  final out = StringBuffer()
    ..writeln('# Pinpoint ${note.id} (${note.intent.name})')
    ..writeln()
    ..writeln('Comment: ${note.comment}')
    ..writeln()
    ..writeln('Target: ${target.description ?? target.widget}')
    ..writeln(
      'Source: ${source == null ? 'unavailable' : '${where(source)}:${source.column}'}',
    );
  if (note.ancestors.isNotEmpty) {
    out.writeln(
      'Enclosing: ${note.ancestors.map((a) => '${a.widget} (${where(a.source)})').join(' < ')}',
    );
  }
  out
    ..writeln()
    ..writeln('```json')
    ..writeln(const JsonEncoder.withIndent('  ').convert(note.toJson()))
    ..writeln('```');
  return out.toString();
}
