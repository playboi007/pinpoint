// Plain Dart with `dart:io` (through [Checkpoints]): the rounds of a note
// (PLAN-v3 Milestone 20): what the agent changed in each pass, labelled by
// the agent, and the texts the bridge writes when the user undoes some of it.

import 'checkpoints.dart';

/// One label the agent gives with `update_note`: a summary and the files
/// that belong to it.
class ChangeLabel {
  const ChangeLabel(this.summary, this.files);

  final String summary;
  final List<String> files;

  /// The `changes` argument of `update_note` as labels. Throws a
  /// [FormatException] that says what is wrong.
  static List<ChangeLabel> parse(Object? raw) {
    if (raw == null) return const <ChangeLabel>[];
    if (raw is! List<Object?>) {
      throw const FormatException('changes must be a list');
    }
    final labels = <ChangeLabel>[];
    for (final item in raw) {
      if (item is! Map<String, Object?>) {
        throw const FormatException('each change is {summary, files}');
      }
      final summary = item['summary'];
      if (summary is! String || summary.trim().isEmpty) {
        throw const FormatException('each change needs a summary');
      }
      final files = item['files'];
      if (files != null &&
          (files is! List<Object?> || files.any((f) => f is! String))) {
        throw const FormatException('files is a list of paths');
      }
      labels.add(
        ChangeLabel(summary.trim().replaceAll(RegExp(r'\s+'), ' '), [
          for (final f in (files as List<Object?>? ?? const <Object?>[]))
            if ((f! as String).trim().isNotEmpty) (f as String).trim(),
        ]),
      );
    }
    return labels;
  }

  Map<String, Object?> toJson() => {'summary': summary, 'files': files};

  static ChangeLabel? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['summary'] is! String) return null;
    final files = json['files'];
    return ChangeLabel(json['summary']! as String, [
      if (files is List<Object?>)
        for (final f in files)
          if (f is String) f,
    ]);
  }
}

/// What closing a round found, for the answer to `update_note`.
class RoundsReport {
  /// Files a label named that are not in the diff.
  final List<String> droppedFiles = [];

  /// Labels that had no file in the diff.
  final List<String> droppedChanges = [];

  /// The round that was closed, as stored; null when no round closed.
  Map<String, Object?>? closed;
}

/// The summary of the change that holds files no label named.
const String otherSummary = 'Not labelled by the agent';

/// The changes of one round: the files of the diff from [start] to [end]
/// split by the agent's [labels]; the files no label names go into `other`.
///
/// Without [checkpoints], or when [start] or [end] is null or git fails,
/// the changes are the labels alone, and files carry no counts.
///
/// A path in a label may be absolute or relative to the bridge's folder;
/// stored paths are relative to the git top level (see [Checkpoints]).
Future<List<Map<String, Object?>>> buildChanges({
  required Checkpoints? checkpoints,
  required String? start,
  required String? end,
  required List<ChangeLabel> labels,
  RoundsReport? report,
}) async {
  final diff = checkpoints == null || start == null || end == null
      ? null
      : await checkpoints.diff(start, end);
  final changes = <Map<String, Object?>>[];
  final used = <String>{};
  final known = {for (final f in diff ?? const <FileDiff>[]) f.path};
  final byPath = {for (final f in diff ?? const <FileDiff>[]) f.path: f};
  for (final label in labels) {
    final files = <Map<String, Object?>>[];
    for (final raw in label.files) {
      final path = checkpoints?.toRepoPath(raw, known) ?? _plain(raw);
      if (diff == null) {
        if (used.add(path)) {
          files.add({'path': path, 'added': null, 'removed': null});
        }
      } else if (!known.contains(path)) {
        report?.droppedFiles.add(raw);
      } else if (used.add(path)) {
        files.add(byPath[path]!.toJson());
      }
    }
    if (diff != null && files.isEmpty) {
      report?.droppedChanges.add(label.summary);
      continue;
    }
    changes.add({
      'id': 'c${changes.length + 1}',
      'summary': label.summary,
      'files': files,
    });
  }
  if (diff != null) {
    final rest = [
      for (final f in diff)
        if (!used.contains(f.path)) f.toJson(),
    ];
    if (rest.isNotEmpty) {
      changes.add({'id': 'other', 'summary': otherSummary, 'files': rest});
    }
  }
  return changes;
}

String _plain(String path) {
  final parts = [
    for (final p in path.replaceAll(r'\', '/').split('/'))
      if (p.isNotEmpty && p != '.') p,
  ];
  return parts.join('/');
}

/// Sets `shared: true` on the files of [changes] that are in [others].
void markShared(List<Map<String, Object?>> changes, Set<String> others) {
  if (others.isEmpty) return;
  for (final change in changes) {
    final files = change['files'];
    if (files is! List<Object?>) continue;
    for (final file in files) {
      if (file is Map<String, Object?> && others.contains(file['path'])) {
        file['shared'] = true;
      }
    }
  }
}

/// The user's message after the bridge put the files back.
String undoDoneMessage({
  required List<String> undone,
  required List<String> kept,
  String? reason,
}) =>
    'Undone by the bridge: ${_list(undone)}. Kept: ${_list(kept)}. '
    'Do not make the undone changes again. Reason: ${_reason(reason)}';

/// The user's message when the agent must undo: no git, or a file changed
/// since the round.
String undoRequestedMessage({
  required List<String> undone,
  required List<String> files,
  required List<String> kept,
  String? reason,
}) =>
    'Undo these changes yourself: ${_list(undone)} (${files.join(', ')}). '
    'Keep: ${_list(kept)}. Then continue. Reason: ${_reason(reason)}. '
    'get_note_diff gives the patch.';

String _list(List<String> summaries) =>
    summaries.isEmpty ? 'none' : summaries.join('; ');

String _reason(String? reason) {
  final text = reason?.trim() ?? '';
  return text.isEmpty ? 'none given' : text;
}
