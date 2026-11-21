// Plain Dart: no `dart:ui` and no `package:flutter`. The bridge writes the
// rounds of a note (PLAN-v3 Milestone 20); the app and the bridge's text
// read them with these classes.

/// One file in a [RoundChange]. [path] is relative to the git top level,
/// which can be above the app's folder.
class RoundFile {
  const RoundFile({
    required this.path,
    this.added,
    this.removed,
    this.shared = false,
  });

  /// [json] as a file, or null when it has no path.
  static RoundFile? fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['path'] is! String) return null;
    return RoundFile(
      path: json['path']! as String,
      added: json['added'] is int ? json['added']! as int : null,
      removed: json['removed'] is int ? json['removed']! as int : null,
      shared: json['shared'] == true,
    );
  }

  final String path;

  /// Lines added and removed; null without git, and for a binary file.
  final int? added;
  final int? removed;

  /// Another note's open round changed this file too, so the change may not
  /// be the agent's of this note alone.
  final bool shared;
}

/// One labelled unit of a round: what the agent said it did, and the files.
/// The id `other` holds the files in the diff that no label named.
class RoundChange {
  const RoundChange({
    required this.id,
    required this.summary,
    this.files = const <RoundFile>[],
  });

  /// [json] as a change, or null when it has no id.
  static RoundChange? fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['id'] is! String) return null;
    final files = json['files'];
    return RoundChange(
      id: json['id']! as String,
      summary: json['summary'] is String ? json['summary']! as String : '',
      files: [
        if (files is List<Object?>)
          for (final f in files) ?RoundFile.fromJson(f),
      ],
    );
  }

  /// `c1`, `c2`… in the order the agent gave them, or [otherId].
  final String id;
  final String summary;
  final List<RoundFile> files;

  /// The id of the change that holds files no label named.
  static const String otherId = 'other';

  bool get shared => files.any((f) => f.shared);
}

/// How the undo of a round went.
enum RoundUndo {
  /// The bridge put the files back.
  done,

  /// The agent was asked to undo them (no git, or a file changed since).
  requested,

  /// Git failed; the agent was asked as for [requested].
  failed;

  static RoundUndo? byName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// One pass of the agent on a note: from `inProgress` to `fixed` or
/// `resolved`.
class NoteRound {
  const NoteRound({
    required this.n,
    this.startedAt,
    this.endedAt,
    this.start,
    this.end,
    this.changes = const <RoundChange>[],
    this.undone = const <String>[],
    this.undo,
  });

  /// [json] as a round, or null when it has no number.
  static NoteRound? fromJson(Map<String, Object?> json) {
    final n = json['n'];
    if (n is! int) return null;
    final changes = json['changes'];
    final undone = json['undone'];
    return NoteRound(
      n: n,
      startedAt: _date(json['startedAt']),
      endedAt: _date(json['endedAt']),
      start: json['start'] is String ? json['start']! as String : null,
      end: json['end'] is String ? json['end']! as String : null,
      changes: [
        if (changes is List<Object?>)
          for (final c in changes) ?RoundChange.fromJson(c),
      ],
      undone: [
        if (undone is List<Object?>)
          for (final u in undone)
            if (u is String) u,
      ],
      undo: RoundUndo.byName(json['undo']),
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  final int n;
  final DateTime? startedAt;

  /// Null while the agent still works on the round.
  final DateTime? endedAt;

  /// Git trees before and after the round. Null without git: then the
  /// bridge cannot undo, and the buttons ask the agent instead.
  final String? start;
  final String? end;

  final List<RoundChange> changes;

  /// The ids the user chose to undo: `*` for all.
  final List<String> undone;

  /// How the last undo went; null while none was asked for.
  final RoundUndo? undo;

  bool get isOpen => endedAt == null;

  /// Whether the bridge can undo this round itself (git was there).
  bool get hasCheckpoints => start != null && end != null;

  /// Whether change [id] was undone.
  bool isUndone(String id) => undone.contains('*') || undone.contains(id);
}
