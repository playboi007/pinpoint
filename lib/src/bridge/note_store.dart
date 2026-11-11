// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it. Never exported from pinpoint.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/annotation.dart' show NoteMessage, NoteStatus;
import '../sink/markdown_formatter.dart';
import 'bridge_protocol.dart';

/// Why a store operation was refused, with the HTTP status that says so.
class StoreException implements Exception {
  const StoreException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

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
/// ```
///
/// The folders are the file inbox of Milestone 7: an agent without MCP
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

  /// Changes with each run, so a cursor from an earlier run is detected.
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

  Directory get _drafts => Directory('${root.path}/drafts');

  /// The folder an agent reads: `<dir>/open/`.
  Directory get openDir => Directory('${root.path}/open');

  Directory get _resolved => Directory('${root.path}/resolved');

  /// The cursor for "now".
  String get cursor => '$_epoch:$_seq';

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
  /// [png], replacing any earlier copy of the note. Returns the path of the
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
  }) => _serial(() async {
    final id = note['id']! as String;
    final status = NoteStatus.byName(note['status']) ?? NoteStatus.submitted;
    note['status'] = status.name;
    final old = _index[id];
    final resolvedByHand =
        File('${_resolved.path}/$id.md').existsSync() ||
        File('${_resolved.path}/$id.json').existsSync();
    if ((old != null && old.folder.path == _resolved.path) || resolvedByHand) {
      throw StoreException(HttpStatus.conflict, 'Note $id is already resolved');
    }
    // A resend keeps the replies the bridge has, unless it brings its own.
    if (old != null && _messagesOf(note).isEmpty) {
      final stored = await _readJson(old.folder, id);
      if (stored != null) note['messages'] = stored['messages'] ?? const [];
    }
    final file = await _write(id, note, png: png, keepPng: keepPng);
    _record(id, note);
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
  /// Throws a [StoreException] (404) for an unknown note.
  Future<Map<String, Object?>> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? intent,
    String? message,
    String from = 'user',
    Map<String, Object?>? verification,
  }) => _serial(() async {
    final entry = _index[id];
    final note = entry == null ? null : await _readJson(entry.folder, id);
    if (entry == null || note == null) {
      throw StoreException(HttpStatus.notFound, 'No note $id');
    }
    if (status != null) note['status'] = status.name;
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
    _record(id, note);
    return note;
  });

  /// Deletes note [id]'s files. Returns whether there was a note.
  Future<bool> delete(String id) => _serial(() async {
    final entry = _index.remove(id);
    if (entry == null) return false;
    await _removeFiles(entry.folder, id);
    _changes[id] = _Change(++_seq, entry.origin);
    return true;
  });

  /// What changed after [since] (a [cursor]), for notes of [origin] when
  /// given. Reads the folders first, so files an agent moved by hand count.
  Future<StoreChanges> changes(String? since, {String? origin}) async {
    await sync();
    return _serial(() async {
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
  }

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
        if (_loaded) _changes[id] = _Change(++_seq, _originOf(json));
      }
    }
    for (final id in _index.keys.toList()) {
      if (seen.contains(id)) continue;
      final gone = _index.remove(id)!;
      _changes[id] = _Change(++_seq, gone.origin);
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
      await _writeAtomic(markdown, utf8.encode(markdownFromJson(note)));
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

  void _record(String id, Map<String, Object?> note) {
    _changes[id] = _Change(++_seq, _originOf(note));
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
  const _Change(this.seq, this.origin);

  final int seq;
  final String? origin;
}

void _noLog(String line) {}
