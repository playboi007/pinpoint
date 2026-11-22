// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it. Never exported from pinpoint.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/annotation.dart' show NoteMessage, NoteStatus;
import '../model/json_read.dart';
import '../model/note_round.dart' show RoundUndo;
import '../model/tape.dart' show tapeIdPattern;
import 'bridge_protocol.dart';
import 'checkpoints.dart';
import 'note_detail.dart';
import 'note_rounds.dart';
import 'tmp_bin.dart';

/// Why a store operation was refused, with the HTTP status that says so.
class StoreException implements Exception {
  const StoreException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

/// What [NoteStore.undo] did.
class UndoOutcome {
  const UndoOutcome({
    required this.undo,
    required this.reverted,
    required this.conflicts,
    required this.note,
  });

  /// `done` (the bridge put the files back), `requested` (the agent must:
  /// no git, or a file changed since) or `failed` (git failed; the agent
  /// is asked as for `requested`).
  final RoundUndo undo;

  /// The files that went back, relative to the git top level.
  final List<String> reverted;

  /// The files that do not fit, relative to the git top level.
  final List<String> conflicts;

  /// The note as it is now: submitted again, with the user's message.
  final Map<String, Object?> note;
}

typedef _UndoTarget = ({
  List<Map<String, Object?>> rounds,
  Map<String, Object?> round,
});

typedef _UndoPick = ({
  List<Map<String, Object?>> all,
  Set<String> already,
  List<Map<String, Object?>> chosen,
  List<Map<String, Object?>> kept,
  List<String> files,
});

typedef _UndoRevert = ({
  RoundUndo state,
  List<String> reverted,
  List<String> conflicts,
});

/// What [NoteStore.changes] found since a cursor.
class StoreChanges {
  const StoreChanges({
    required this.cursor,
    required this.changes,
    this.reset = false,
  });

  /// Pass this as `since` next time.
  final String cursor;

  /// One entry per changed note: `{id, status, note}`, or `{id, deleted:
  /// true}` for a deleted one.
  final List<Map<String, Object?>> changes;

  /// True when the cursor is from another bridge run (or not a cursor):
  /// the caller must reload every note.
  final bool reset;

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'reset': reset,
    'changes': changes,
  };
}

/// The notes on disk, one JSON file per note, in three folders:
///
/// ```text
/// <dir>/drafts/    <id>.json, <id>.png      drafts: never seen by the agent
/// <dir>/open/      <id>.md, .json, .png     submitted, inProgress, fixed
/// <dir>/resolved/  <id>.md, .json, .png     resolved, verified, rejected
/// <dir>/tmp/       <id>__<stamp>/            deleted notes, flushed after 1 h
/// ```
///
/// The folders are the file inbox: an agent without MCP
/// still reads `open/*.md` and moves a note's files to `resolved/` by
/// hand. [sync] notices such a move and records it as a change.
///
/// Every change is numbered, so the app can ask what changed since its
/// last poll ([changes]).
class NoteStore {
  NoteStore._(this.root, this._log)
    : _epoch = math.Random().nextInt(1 << 32).toRadixString(16);

  /// Creates the folders and reads the notes already in them.
  static Future<NoteStore> open(
    Directory root, {
    void Function(String line) log = _noLog,
  }) async {
    final store = NoteStore._(root.absolute, log);
    for (final dir in [store._drafts, store.openDir, store._resolved]) {
      await dir.create(recursive: true);
    }
    // Keeps the notes (comments, screenshots) out of git without editing
    // the project's own .gitignore: `*` here ignores the folder, this file
    // included.
    final ignore = File('${store.root.path}/.gitignore');
    if (!ignore.existsSync()) await ignore.writeAsString('*\n');
    await store.sync();
    return store;
  }

  final Directory root;
  final void Function(String line) _log;

  /// Differs for each run, so a cursor from another run is detected.
  final String _epoch;

  int _seq = 0;

  /// False until the first [sync] has read the folders: notes found then
  /// are not changes.
  bool _loaded = false;

  /// Where each known note is: its folder and status.
  final Map<String, _Entry> _index = <String, _Entry>{};

  /// The last change to each note.
  final Map<String, _Change> _changes = <String, _Change>{};

  /// One operation at a time: each awaits file work, and two at once could
  /// move the same note's files in two directions.
  Future<void> _queue = Future<void>.value();

  /// Git trees of the working folder for the rounds of each note; null in
  /// the answer when there is no git. Opened once, on first use.
  late final Future<Checkpoints?> checkpoints = Checkpoints.open(
    root.parent,
    undoDir: Directory('${root.path}/undo'),
  );

  Directory get _drafts => Directory('${root.path}/drafts');

  /// The folder an agent reads: `<dir>/open/`.
  Directory get openDir => Directory('${root.path}/open');

  Directory get _resolved => Directory('${root.path}/resolved');

  /// The cursor for "now".
  String get cursor => '$_epoch:$_seq';

  /// Completes when the work queued so far (for example the `base`
  /// checkpoint taken after a note is sent) is done.
  Future<void> settled() => _serial(() async {});

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Directory _folderFor(NoteStatus status) {
    if (status == NoteStatus.draft) return _drafts;
    return NoteStatus.closed.contains(status) ? _resolved : openDir;
  }

  /// Stores [note] (an `Annotation.toJson` map without the image data) and
  /// [png], replacing any copy of the note. Returns the path of the
  /// `.md` file, or of the `.json` file for a draft.
  ///
  /// With no [png], a PNG already stored for the note is kept when the
  /// note still names a screenshot ([keepPng]): a draft loaded back by the
  /// app has no image data, but its image is here. Throws a
  /// [StoreException] (409) for a note already in `resolved/`.
  Future<String> save(
    Map<String, Object?> note,
    Uint8List? png, {
    bool keepPng = false,
    String? client,
  }) => _serial(() async {
    final id = note['id']! as String;
    final status = NoteStatus.byName(note['status']) ?? NoteStatus.submitted;
    note['status'] = status.name;
    _fillProjectRoot(note);
    final old = _index[id];
    final resolvedByHand =
        File('${_resolved.path}/$id.md').existsSync() ||
        File('${_resolved.path}/$id.json').existsSync();
    if ((old != null && old.folder.path == _resolved.path) || resolvedByHand) {
      throw StoreException(HttpStatus.conflict, 'Note $id is already resolved');
    }
    // A resend keeps the replies the bridge has, unless it brings its own.
    // The rounds are the bridge's alone: the app's copy is never used.
    if (old != null) {
      final stored = await _readJson(old.folder, id);
      if (stored != null) {
        if (_messagesOf(note).isEmpty) {
          note['messages'] = stored['messages'] ?? const [];
        }
        note.remove('rounds');
        if (stored['rounds'] != null) note['rounds'] = stored['rounds'];
      }
    } else {
      note.remove('rounds');
    }
    final file = await _write(id, note, png: png, keepPng: keepPng);
    _record(id, note, client: client);
    if (status == NoteStatus.submitted && old?.status != NoteStatus.submitted) {
      // Queued, not awaited: `git add -A` can take seconds in a big repo,
      // and the app waits for this answer. Every later change of the note
      // (inProgress, fixed) queues behind it, so the base is there first.
      unawaited(_serial(() => _snapshotBase(id)));
    }
    return file.path;
  });

  /// The note [id] as JSON, or null. Drafts included.
  Future<Map<String, Object?>?> read(String id) => _serial(() async {
    final entry = _index[id];
    return entry == null ? null : _readJson(entry.folder, id);
  });

  /// The PNG file of note [id], or null when it has none.
  File? pngOf(String id) {
    final entry = _index[id];
    if (entry == null) return null;
    final file = File('${entry.folder.path}/$id.png');
    return file.existsSync() ? file : null;
  }

  /// Stores [png] as note [id]'s after screenshot, `<id>.after.png`
  /// beside its JSON, from `verify_note`. Returns the file name, or null
  /// for an unknown note.
  Future<String?> saveAfter(String id, Uint8List png) => _serial(() async {
    final entry = _index[id];
    if (entry == null) return null;
    final name = '$id.$_afterExt';
    await _writeAtomic(File('${entry.folder.path}/$name'), png);
    return name;
  });

  /// The after screenshot's extension: a note's files are `.md`, `.json`,
  /// `.png` and this, and move between folders together.
  static const String _afterExt = 'after.png';

  /// Every note whose status is in [statuses] (all when null) and, when
  /// [origin] is given, that was written on a page of that origin. Oldest
  /// first.
  Future<List<Map<String, Object?>>> list({
    Set<NoteStatus>? statuses,
    String? origin,
  }) => _serial(() async {
    final notes = <Map<String, Object?>>[];
    for (final MapEntry(key: id, value: entry) in _index.entries) {
      if (statuses != null && !statuses.contains(entry.status)) continue;
      if (origin != null && entry.origin != origin) continue;
      final json = await _readJson(entry.folder, id);
      if (json != null) notes.add(json);
    }
    // By time, then id: a stable order for notes made in one second.
    notes.sort(
      (a, b) => '${a['createdAt']} ${a['id']}'.compareTo(
        '${b['createdAt']} ${b['id']}',
      ),
    );
    return notes;
  });

  /// Changes note [id]: its [status], [comment], [intent] or
  /// [verification], and adds [message] from [from]. Moves its files when the status changes folder
  /// and rewrites its `.md`. Returns the note.
  ///
  /// The status moves keep the note's rounds:
  /// `submitted` takes the `base` checkpoint, `inProgress` opens a round,
  /// `fixed`, `resolved` and `rejected` close it. The agent's [changes]
  /// labels split the files of the closed round; [report] says what that
  /// found.
  ///
  /// Throws a [StoreException] (404) for an unknown note.
  Future<Map<String, Object?>> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? intent,
    String? message,
    String from = 'user',
    Map<String, Object?>? verification,
    String? client,
    List<ChangeLabel>? changes,
    RoundsReport? report,
  }) => _serial(
    () => _update(
      id,
      status: status,
      comment: comment,
      intent: intent,
      message: message,
      from: from,
      verification: verification,
      client: client,
      changes: changes,
      report: report,
    ),
  );

  /// [update] without the queue, for a caller that holds it. [edit] changes
  /// the note after the status moves and before it is written.
  Future<Map<String, Object?>> _update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? intent,
    String? message,
    String from = 'user',
    Map<String, Object?>? verification,
    String? client,
    List<ChangeLabel>? changes,
    RoundsReport? report,
    void Function(Map<String, Object?> note)? edit,
  }) async {
    final entry = _index[id];
    final note = entry == null ? null : await _readJson(entry.folder, id);
    if (entry == null || note == null) {
      throw StoreException(HttpStatus.notFound, 'No note $id');
    }
    final before = NoteStatus.byName(note['status']);
    if (status != null) {
      // Reopened: back to submitted after the agent worked it. The last
      // check result is about the old code, and the agent must see that
      // the note came back.
      if (status == NoteStatus.submitted &&
          before != null &&
          before != NoteStatus.draft &&
          before != NoteStatus.submitted) {
        note.remove('verification');
        final reopened = note['reopened'];
        note['reopened'] = (reopened is int ? reopened : 0) + 1;
      }
      note['status'] = status.name;
    }
    await _moveRounds(id, note, before, status, changes ?? const [], report);
    edit?.call(note);
    if (verification != null) note['verification'] = verification;
    if (comment != null) note['comment'] = comment;
    if (intent != null) note['intent'] = intent;
    if (message != null && message.trim().isNotEmpty) {
      note['messages'] = [
        ..._messagesOf(note),
        NoteMessage(at: DateTime.now(), from: from, text: message).toJson(),
      ];
    }
    await _write(id, note, keepPng: true);
    _record(id, note, client: client);
    return note;
  }

  // ------------------------------------------------------------- rounds

  /// The `base` checkpoint of note [id]: the tree when it was sent.
  Future<void> _snapshotBase(String id) async {
    final cp = await checkpoints;
    if (cp != null) await cp.snapshot(id, 'base');
  }

  /// Deletes the checkpoint refs of note [id] (a deleted or expired note).
  Future<void> _dropCheckpoints(String id) async {
    try {
      await (await checkpoints)?.drop(id);
    } on Object {
      // The refs stay; they hold only trees.
    }
  }

  static List<Map<String, Object?>> _roundsOf(Map<String, Object?> note) => [
    for (final r in asJsonList(note['rounds']))
      if (r is Map<String, Object?>) r,
  ];

  static Map<String, Object?>? _openRound(List<Map<String, Object?>> rounds) {
    for (final round in rounds.reversed) {
      if (round['endedAt'] == null) return round;
    }
    return null;
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// Keeps `rounds` of [note] in step with the move from [before] to
  /// [status] (null: no move), and takes the `base` checkpoint when the
  /// note goes (back) to submitted.
  Future<void> _moveRounds(
    String id,
    Map<String, Object?> note,
    NoteStatus? before,
    NoteStatus? status,
    List<ChangeLabel> labels,
    RoundsReport? report,
  ) async {
    final rounds = _roundsOf(note);
    final open = _openRound(rounds);
    final closing =
        status == NoteStatus.fixed ||
        status == NoteStatus.resolved ||
        status == NoteStatus.rejected;
    if (status == NoteStatus.submitted && before != NoteStatus.submitted) {
      await _snapshotBase(id);
    } else if (status == NoteStatus.inProgress && open == null) {
      final n = rounds.length + 1;
      final cp = await checkpoints;
      final start = await cp?.snapshot(id, 'r$n-start');
      rounds.add(_newRound(n, start));
      note['rounds'] = rounds;
    } else if (closing && open != null) {
      await _closeRound(id, open, labels, report);
      note['rounds'] = rounds;
    } else if (closing && status != NoteStatus.rejected && !_wasDone(before)) {
      // Set fixed without inProgress: the round starts at the base.
      final n = rounds.length + 1;
      final cp = await checkpoints;
      final round = _newRound(n, await cp?.resolve(id, 'base'));
      rounds.add(round);
      await _closeRound(id, round, labels, report);
      note['rounds'] = rounds;
    } else if (labels.isNotEmpty) {
      if (open != null) {
        // Labels before the round closes: kept until it does.
        open['pending'] = [
          ...asJsonList(open['pending']),
          for (final l in labels) l.toJson(),
        ];
      } else if (rounds.isNotEmpty) {
        // A second call after the round closed: labels the last one again.
        await _relabel(id, rounds.last, labels, report);
      }
      note['rounds'] = rounds;
    }
  }

  static bool _wasDone(NoteStatus? status) =>
      status == NoteStatus.fixed ||
      status == NoteStatus.resolved ||
      status == NoteStatus.verified ||
      status == NoteStatus.rejected;

  static Map<String, Object?> _newRound(int n, String? start) => {
    'n': n,
    'startedAt': _now(),
    'start': start,
    'changes': <Object?>[],
    'undone': <Object?>[],
    'undo': null,
  };

  /// Ends [round]: takes its `end` checkpoint and fills its `changes` from
  /// the diff and the agent's [labels].
  Future<void> _closeRound(
    String id,
    Map<String, Object?> round,
    List<ChangeLabel> labels,
    RoundsReport? report,
  ) async {
    final cp = await checkpoints;
    final start = round['start'] as String?;
    final n = round['n'];
    final end = cp == null || start == null
        ? null
        : await cp.snapshot(id, 'r$n-end');
    round['endedAt'] = _now();
    round['end'] = end;
    final pending = [
      for (final p in asJsonList(round.remove('pending')))
        ?ChangeLabel.fromJson(p),
    ];
    final all = [...pending, ...labels];
    final changes = await buildChanges(
      checkpoints: cp,
      start: start,
      end: end,
      labels: all,
      report: report,
    );
    if (cp != null && start != null && end != null) {
      markShared(changes, await _filesOfOtherRounds(cp, id, round));
    }
    round['changes'] = changes;
    report?.closed = round;
  }

  /// A second `update_note` with labels, after the round closed: the last
  /// round's changes are built again with them.
  Future<void> _relabel(
    String id,
    Map<String, Object?> round,
    List<ChangeLabel> labels,
    RoundsReport? report,
  ) async {
    final isUndone = asJsonList(round['undone']).isNotEmpty;
    if (round['endedAt'] == null || isUndone) return;
    final cp = await checkpoints;
    final start = round['start'] as String?;
    final end = round['end'] as String?;
    final changes = await buildChanges(
      checkpoints: cp,
      start: start,
      end: end,
      labels: labels,
      report: report,
    );
    if (cp != null && start != null && end != null) {
      markShared(changes, await _filesOfOtherRounds(cp, id, round));
    }
    round['changes'] = changes;
    report?.closed = round;
  }

  /// The files that another note's open round changed in a window that
  /// overlaps [round]: the paths a user may not want to undo with this
  /// note. Two checkpoints cannot tell whose edit is whose inside one
  /// window, so:
  ///
  /// - an other round that started before [round]: what it changed up to
  ///   the start of [round];
  /// - one that started after it began: what changed from its start to the
  ///   end of [round].
  Future<Set<String>> _filesOfOtherRounds(
    Checkpoints cp,
    String id,
    Map<String, Object?> round,
  ) async {
    final shared = <String>{};
    final start = round['start'] as String?;
    final end = round['end'] as String?;
    final began = DateTime.tryParse('${round['startedAt']}');
    if (start == null || end == null || began == null) return shared;
    for (final MapEntry(key: otherId, value: entry) in _index.entries) {
      if (otherId == id || entry.folder.path != openDir.path) continue;
      final other = await _readJson(entry.folder, otherId);
      final otherOpen = other == null ? null : _openRound(_roundsOf(other));
      final otherStart = otherOpen?['start'];
      final otherBegan = DateTime.tryParse('${otherOpen?['startedAt']}');
      if (otherStart is! String || otherBegan == null) continue;
      final files = await cp.diff(
        otherStart,
        otherBegan.isBefore(began) ? start : end,
      );
      for (final f in files ?? const <FileDiff>[]) {
        shared.add(f.path);
      }
    }
    return shared;
  }

  /// The user undoes [changes] (ids, or `*`) of [round] of note [id].
  ///
  /// With git, the bridge puts the files back ([Checkpoints.revert]); with
  /// none, or when a file changed since, no file changes and the agent is
  /// asked to do it. Either way the note goes back to submitted, as a
  /// reopen does, with the user's message and [reason].
  ///
  /// Throws a [StoreException]: 404 for an unknown note or round, 400 for a
  /// change that is not in the round, 409 for a note the agent is working
  /// on, a round still open, or changes already undone.
  Future<UndoOutcome> undo(
    String id, {
    required int round,
    required List<String> changes,
    String? reason,
    String? client,
  }) => _serial(() async {
    final target = await _undoTarget(id, round);
    final pick = _pickChanges(target.round, changes, round);
    final revert = await _revertPicked(id, round, target.round, pick.files);
    return _recordUndo(
      id,
      round,
      target,
      pick,
      revert,
      reason: reason,
      client: client,
    );
  });

  /// The round to undo. Throws 404 for an unknown note or round, 409 for a
  /// note the agent works on or a round still open.
  Future<_UndoTarget> _undoTarget(String id, int round) async {
    final entry = _index[id];
    final note = entry == null ? null : await _readJson(entry.folder, id);
    if (entry == null || note == null || entry.status == NoteStatus.draft) {
      throw StoreException(HttpStatus.notFound, 'No note $id');
    }
    if (!_wasDone(entry.status)) {
      throw StoreException(
        HttpStatus.conflict,
        'Note $id is ${entry.status.name}: the agent has it. Undo works '
        'after the agent set it fixed.',
      );
    }
    final rounds = _roundsOf(note);
    final target = rounds.where((r) => r['n'] == round).firstOrNull;
    if (target == null) {
      throw StoreException(HttpStatus.notFound, 'No round $round in $id');
    }
    if (target['endedAt'] == null) {
      throw StoreException(HttpStatus.conflict, 'Round $round is still open');
    }
    return (rounds: rounds, round: target);
  }

  /// Which changes of [target] to undo. Throws 400 for an id that is not in
  /// the round, 409 when nothing is left to undo.
  static _UndoPick _pickChanges(
    Map<String, Object?> target,
    List<String> changes,
    int round,
  ) {
    final all = [
      for (final c in asJsonList(target['changes']))
        if (c is Map<String, Object?> && c['id'] is String) c,
    ];
    final already = _undoneIds(target, all);
    final wanted = changes.contains('*')
        ? [for (final c in all) c['id']! as String]
        : changes;
    final unknown = wanted.where((w) => !all.any((c) => c['id'] == w));
    if (unknown.firstOrNull case final changeId?) {
      throw StoreException(
        HttpStatus.badRequest,
        'No change $changeId in round $round. It has: '
        '${all.map((c) => c['id']).join(', ')}',
      );
    }
    final chosen = [
      for (final c in all)
        if (wanted.contains(c['id']) && !already.contains(c['id'])) c,
    ];
    if (chosen.isEmpty) {
      throw StoreException(
        HttpStatus.conflict,
        all.isEmpty
            ? 'Round $round has no changes'
            : 'Those changes are already undone',
      );
    }
    return (
      all: all,
      already: already,
      chosen: chosen,
      kept: [
        for (final c in all)
          if (!chosen.contains(c) && !already.contains(c['id'])) c,
      ],
      files: {
        for (final c in chosen)
          for (final f in asJsonList(c['files']))
            if (f is Map<String, Object?> && f['path'] is String)
              f['path']! as String,
      }.toList(),
    );
  }

  /// Puts [files] of [target] back with git, when there is a checkpoint
  /// pair. Without one, or on a conflict, no file changes.
  Future<_UndoRevert> _revertPicked(
    String id,
    int round,
    Map<String, Object?> target,
    List<String> files,
  ) async {
    final cp = await checkpoints;
    final start = target['start'];
    final end = target['end'];
    if (cp == null || start is! String || end is! String) {
      return _revert(RoundUndo.requested);
    }
    final result = await cp.revert(start, end, files);
    switch (result.outcome) {
      case RevertOutcome.clean:
        return _revert(RoundUndo.done, reverted: result.reverted);
      case RevertOutcome.conflict:
        return _revert(RoundUndo.requested, conflicts: result.conflicts);
      case RevertOutcome.failed:
        _log('pinpoint: undo of $id round $round failed: ${result.error}');
        return _revert(RoundUndo.failed);
    }
  }

  static _UndoRevert _revert(
    RoundUndo state, {
    List<String> reverted = const <String>[],
    List<String> conflicts = const <String>[],
  }) => (state: state, reverted: reverted, conflicts: conflicts);

  /// Submits the note again with the user's message, and marks [pick] as
  /// undone in the round.
  Future<UndoOutcome> _recordUndo(
    String id,
    int round,
    _UndoTarget target,
    _UndoPick pick,
    _UndoRevert revert, {
    String? reason,
    String? client,
  }) async {
    final summaries = [for (final c in pick.chosen) '${c['summary']}'];
    final keptSummaries = [for (final c in pick.kept) '${c['summary']}'];
    final text = revert.state == RoundUndo.done
        ? undoDoneMessage(
            undone: summaries,
            kept: keptSummaries,
            reason: reason,
          )
        : undoRequestedMessage(
            undone: summaries,
            files: pick.files,
            kept: keptSummaries,
            reason: reason,
          );
    final undone = {
      ...pick.already,
      for (final c in pick.chosen) c['id']! as String,
    };
    final updated = await _update(
      id,
      status: NoteStatus.submitted,
      message: text,
      from: 'user',
      client: client,
      edit: (note) {
        target.round['undone'] = undone.length == pick.all.length
            ? const ['*']
            : [
                for (final c in pick.all)
                  if (undone.contains(c['id'])) c['id'],
              ];
        target.round['undo'] = revert.state.name;
        note['rounds'] = target.rounds;
      },
    );
    _log(
      'pinpoint: undo of $id round $round: ${revert.state.name} '
      '(${summaries.join('; ')})',
    );
    return UndoOutcome(
      undo: revert.state,
      reverted: revert.reverted,
      conflicts: revert.conflicts,
      note: updated,
    );
  }

  /// The ids of [round]'s changes that a past undo took out.
  static Set<String> _undoneIds(
    Map<String, Object?> round,
    List<Map<String, Object?>> changes,
  ) {
    final undone = asJsonList(round['undone']);
    return undone.contains('*')
        ? {for (final c in changes) c['id']! as String}
        : {
            for (final u in undone)
              if (u is String) u,
          };
  }

  /// The bin of deleted notes: `<dir>/tmp/`. [sync] never reads it.
  TmpBin get tmpBin => TmpBin(root);

  /// Removes what has been in `<dir>/tmp/` for [tmpKeep] or more. Returns
  /// how many entries it removed.
  Future<int> flushTmp({DateTime? now}) =>
      _serial(() => tmpBin.flush(now: now));

  /// Deletes note [id] for the user: moves every file of it, and its tape
  /// when no other note uses that tape, into `<dir>/tmp/<id>__<stamp>/`
  /// (see [TmpBin]). The note is gone for the app at once. Returns whether
  /// there was a note.
  Future<bool> delete(String id, {String? client}) => _serial(() async {
    final entry = _index.remove(id);
    if (entry == null) return false;
    final note = await _readJson(entry.folder, id);
    final tapeId = _tapeIdOf(note);
    final bin = tmpBin;
    final target = await bin.newEntry(id, DateTime.now());
    // Every file that starts with `<id>.`: the ids hold no dot, so these
    // are this note's alone.
    final files = <File>[];
    if (entry.folder.existsSync()) {
      await for (final file in entry.folder.list()) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last;
        if (name.startsWith('$id.')) files.add(file);
      }
    }
    for (final file in files) {
      try {
        await TmpBin.moveInto(file, target);
      } on FileSystemException {
        // Gone already.
      }
    }
    if (tapeId != null && !await _tapeUsedByOther(tapeId, id)) {
      await _moveTape(tapeId, target);
    }
    _log('pinpoint: note $id moved to .pinpoint/tmp/ (flushed after 1 h)');
    await _dropCheckpoints(id);
    _bump(id, entry.origin, client);
    return true;
  });

  static String? _tapeIdOf(Map<String, Object?>? note) {
    final tape = note?['tape'];
    if (tape is! Map<String, Object?>) return null;
    final id = tape['id'];
    return id is String && tapeIdPattern.hasMatch(id) ? id : null;
  }

  /// Whether a note other than [except], in any folder, names [tapeId].
  Future<bool> _tapeUsedByOther(String tapeId, String except) async {
    for (final folder in [_drafts, openDir, _resolved]) {
      if (!folder.existsSync()) continue;
      await for (final file in folder.list()) {
        final name = file.uri.pathSegments.last;
        if (file is! File || !name.endsWith('.json') || name.startsWith('.')) {
          continue;
        }
        final id = name.substring(0, name.length - 5);
        if (id == except || !noteIdPattern.hasMatch(id)) continue;
        final json = await _readJson(folder, id);
        if (_tapeIdOf(json) == tapeId) return true;
      }
    }
    return false;
  }

  /// Moves tape [tapeId] (`tapes/<id>.json` and `tapes/<id>/`) into
  /// `<target>/tapes/`, the same layout as under `<dir>/`.
  Future<void> _moveTape(String tapeId, Directory target) async {
    final json = File('${root.path}/tapes/$tapeId.json');
    final bodies = Directory('${root.path}/tapes/$tapeId');
    if (!json.existsSync() && !bodies.existsSync()) return;
    final into = Directory('${target.path}/tapes');
    await into.create(recursive: true);
    try {
      if (json.existsSync()) await TmpBin.moveInto(json, into);
      if (bodies.existsSync()) await TmpBin.moveInto(bodies, into);
    } on FileSystemException {
      // The tape stays where it is; the note is moved all the same.
    }
  }

  /// Deletes every note (any status, with its screenshots) whose JSON was
  /// last written before [cutoff]: the bridge's `--ttl`. Returns the ids.
  /// The app sees each as deleted in [changes], so its pin goes too.
  Future<List<String>> expire(DateTime cutoff) async {
    await sync();
    return _serial(() async {
      final gone = <String>[];
      for (final MapEntry(key: id, value: entry) in _index.entries.toList()) {
        final file = File('${entry.folder.path}/$id.json');
        try {
          if (!(await file.lastModified()).isBefore(cutoff)) continue;
        } on FileSystemException {
          continue;
        }
        _index.remove(id);
        await _removeFiles(entry.folder, id);
        await _dropCheckpoints(id);
        _bump(id, entry.origin, null);
        gone.add(id);
      }
      return gone;
    });
  }

  /// What changed after [since] (a [cursor]), for notes of [origin] when
  /// given. Reads the folders first, so files an agent moved by hand count.
  ///
  /// A change whose last writer is [client] is left out: the tab already
  /// has it.
  ///
  /// With a [wait] and nothing to report, the answer is held until a change
  /// comes, [wait] ends, [cancelled] completes (the asker went away) or the
  /// store closes. A reset answers at once. While it holds, the folders are
  /// read once per [syncEvery], so a note moved by hand is seen too.
  Future<StoreChanges> changes(
    String? since, {
    String? origin,
    String? client,
    Duration wait = Duration.zero,
    Future<void>? cancelled,
  }) async {
    await sync();
    var result = await _changesSince(since, origin, client);
    if (wait <= Duration.zero) return result;
    var gone = false;
    unawaited(cancelled?.then((_) => gone = true));
    final clock = Stopwatch()..start();
    while (result.changes.isEmpty && !result.reset && !gone && !_closed) {
      final left = wait - clock.elapsed;
      if (left <= Duration.zero) break;
      await _nap(left < syncEvery ? left : syncEvery, cancelled);
      if (gone || _closed) break;
      await sync();
      result = await _changesSince(since, origin, client);
    }
    return result;
  }

  /// How often a held [changes] request reads the folders.
  static const Duration syncEvery = Duration(seconds: 1);

  bool _closed = false;

  /// Completes when the next change is numbered.
  Completer<void> _signal = Completer<void>();

  /// Ends every held [changes] request. Called when the bridge stops.
  void close() {
    _closed = true;
    _signal.complete();
    _signal = Completer<void>();
  }

  /// Waits [time], or less when a change comes or [cancelled] completes.
  Future<void> _nap(Duration time, Future<void>? cancelled) {
    final done = Completer<void>();
    final timer = Timer(time, () {
      if (!done.isCompleted) done.complete();
    });
    void wake(Object? _) {
      if (!done.isCompleted) done.complete();
    }

    unawaited(_signal.future.then(wake));
    unawaited(cancelled?.then(wake));
    return done.future.whenComplete(timer.cancel);
  }

  Future<StoreChanges> _changesSince(
    String? since,
    String? origin,
    String? client,
  ) => _serial(() async {
    final parts = since?.split(':');
    final seq = parts != null && parts.length == 2 && parts[0] == _epoch
        ? int.tryParse(parts[1])
        : null;
    if (seq == null || seq > _seq) {
      return StoreChanges(
        cursor: cursor,
        changes: const <Map<String, Object?>>[],
        reset: true,
      );
    }
    final changed = _changes.entries.where((e) => e.value.seq > seq).toList()
      ..sort((a, b) => a.value.seq.compareTo(b.value.seq));
    final out = <Map<String, Object?>>[];
    for (final MapEntry(key: id, value: change) in changed) {
      if (origin != null && change.origin != origin) continue;
      if (client != null && change.client == client) continue;
      final entry = _index[id];
      final note = entry == null ? null : await _readJson(entry.folder, id);
      out.add(
        note == null
            ? {'id': id, 'deleted': true}
            : {'id': id, 'status': note['status'], 'note': note},
      );
    }
    return StoreChanges(cursor: cursor, changes: out);
  });

  /// Reads the three folders and records what changed on disk: a note an
  /// agent moved to `resolved/` by hand becomes resolved; one deleted by
  /// hand is deleted.
  Future<void> sync() => _serial(() async {
    final seen = <String>{};
    for (final folder in [_drafts, openDir, _resolved]) {
      if (!folder.existsSync()) continue;
      await for (final file in folder.list()) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith('.json') || name.startsWith('.')) continue;
        final id = name.substring(0, name.length - 5);
        if (!noteIdPattern.hasMatch(id)) continue;
        seen.add(id);
        final known = _index[id];
        if (known != null && known.folder.path == folder.path) continue;
        final json = await _readJson(folder, id);
        if (json == null) continue;
        var status = _statusOf(json, folder);
        if (_folderFor(status).path != folder.path) {
          // Moved by hand: the folder says where the note is now.
          status = folder.path == _resolved.path
              ? NoteStatus.resolved
              : folder.path == _drafts.path
              ? NoteStatus.draft
              : NoteStatus.submitted;
          json['status'] = status.name;
          await _writeAtomic(
            File('${folder.path}/$id.json'),
            utf8.encode(_pretty(json)),
          );
          _log('pinpoint: note $id moved to ${_folderName(folder)}/ by hand');
        }
        if (known != null) {
          // It left its old folder; keep no copy there.
          await _removeFiles(known.folder, id, keep: folder);
        }
        _index[id] = _Entry(folder, status, _originOf(json));
        if (_loaded) _bump(id, _originOf(json), null);
      }
    }
    for (final id in _index.keys.toList()) {
      if (seen.contains(id)) continue;
      final gone = _index.remove(id)!;
      await _dropCheckpoints(id);
      _bump(id, gone.origin, null);
    }
    _loaded = true;
  });

  Future<File> _write(
    String id,
    Map<String, Object?> note, {
    Uint8List? png,
    bool keepPng = false,
  }) async {
    final status = NoteStatus.byName(note['status']) ?? NoteStatus.submitted;
    final folder = _folderFor(status);
    final old = _index[id];
    final pngFile = File('${folder.path}/$id.png');
    final oldPng = old == null ? null : File('${old.folder.path}/$id.png');

    final shot = note['screenshot'];
    if (png != null) {
      await _writeAtomic(pngFile, png);
    } else if (keepPng &&
        shot is Map &&
        oldPng != null &&
        oldPng.existsSync()) {
      if (oldPng.path != pngFile.path) await oldPng.rename(pngFile.path);
    } else if (pngFile.existsSync()) {
      await pngFile.delete();
    }
    if (shot is Map<String, Object?>) {
      // The bridge names the file, so the note always points at the image
      // beside it.
      shot['file'] = pngFile.existsSync() ? '$id.png' : null;
    }

    // Image first and Markdown last: an agent that lists *.md sees a note
    // only when everything it points at is in place.
    final json = File('${folder.path}/$id.json');
    await _writeAtomic(json, utf8.encode(_pretty(note)));
    final markdown = File('${folder.path}/$id.md');
    if (status != NoteStatus.draft) {
      await _writeAtomic(markdown, utf8.encode(noteMarkdown(note)));
    } else if (markdown.existsSync()) {
      await markdown.delete();
    }
    if (old != null && old.folder.path != folder.path) {
      final after = File('${old.folder.path}/$id.$_afterExt');
      if (after.existsSync()) {
        await after.rename('${folder.path}/$id.$_afterExt');
      }
      await _removeFiles(old.folder, id);
    }
    _index[id] = _Entry(folder, status, _originOf(note));
    return status == NoteStatus.draft ? json : markdown;
  }

  void _record(String id, Map<String, Object?> note, {String? client}) {
    _bump(id, _originOf(note), client);
  }

  /// Numbers a change to [id] and wakes the requests that wait for one.
  /// [client] is the tab that wrote it; null for the agent or the disk.
  void _bump(String id, String? origin, String? client) {
    _changes[id] = _Change(++_seq, origin, client);
    final waiting = _signal;
    _signal = Completer<void>();
    waiting.complete();
  }

  /// The bridge's project folder is the one that holds the notes folder.
  /// A note from an app that does not know its root gets it here, so the
  /// agent's text can print paths relative to it.
  void _fillProjectRoot(Map<String, Object?> note) {
    final app = note['app'];
    if (app is! Map<String, Object?>) return;
    final root = app['projectRoot'];
    if (root is String && root.isNotEmpty) return;
    app['projectRoot'] = this.root.parent.path;
  }

  Future<void> _removeFiles(
    Directory folder,
    String id, {
    Directory? keep,
  }) async {
    if (keep != null && keep.path == folder.path) return;
    for (final ext in ['md', 'json', 'png', _afterExt]) {
      final file = File('${folder.path}/$id.$ext');
      try {
        if (file.existsSync()) await file.delete();
      } on FileSystemException {
        // Gone already.
      }
    }
  }

  Future<Map<String, Object?>?> _readJson(Directory folder, String id) async {
    try {
      final decoded = jsonDecode(
        await File('${folder.path}/$id.json').readAsString(),
      );
      if (decoded is! Map<String, Object?>) return null;
      decoded['status'] = _statusOf(decoded, folder).name;
      return decoded;
    } on Object {
      // Missing, half-written by hand, or not JSON: not a note.
      return null;
    }
  }

  /// The note's status; a schema 1 note has none, and its folder says it.
  NoteStatus _statusOf(Map<String, Object?> json, Directory folder) =>
      NoteStatus.byName(json['status']) ??
      (folder.path == _resolved.path
          ? NoteStatus.resolved
          : folder.path == _drafts.path
          ? NoteStatus.draft
          : NoteStatus.submitted);

  static List<Object?> _messagesOf(Map<String, Object?> note) {
    final messages = note['messages'];
    return messages is List<Object?> ? messages : const <Object?>[];
  }

  static String? _originOf(Map<String, Object?> note) {
    final app = note['app'];
    if (app is! Map<String, Object?>) return null;
    final origin = app['origin'];
    return origin is String ? origin : null;
  }

  String _folderName(Directory folder) =>
      folder.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

  static String _pretty(Object? json) =>
      '${const JsonEncoder.withIndent('  ').convert(json)}\n';

  /// Writes [bytes] to a hidden temporary name in the same folder, then
  /// renames it. A rename within one folder is atomic, so an agent never
  /// reads a half-written note.
  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final name = file.uri.pathSegments.last;
    final temp = File('${file.parent.path}/.$name.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }
}

class _Entry {
  const _Entry(this.folder, this.status, this.origin);

  final Directory folder;
  final NoteStatus status;
  final String? origin;
}

class _Change {
  const _Change(this.seq, this.origin, this.client);

  final int seq;
  final String? origin;

  /// The tab that made the change; null for the agent, the disk or expiry.
  final String? client;
}

void _noLog(String line) {}
