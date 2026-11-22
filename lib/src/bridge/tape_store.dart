// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so the
// bridge can run it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/tape.dart';

/// Why a tape was not stored.
class TapeStoreException implements Exception {
  const TapeStoreException(this.message, {this.status = 400});

  final String message;

  /// The HTTP status to answer with.
  final int status;

  @override
  String toString() => message;
}

/// Tapes on disk: `<dir>/tapes/<id>.json` and the bodies in
/// `<dir>/tapes/<id>/bodies/<n>.bin`.
///
/// A tape is personal data. `<dir>` (`.pinpoint/`) holds a
/// `.gitignore` of `*` from `setup`, which covers `tapes/` and `runs/`, and
/// the bridge serves them on loopback only (or to origins named with
/// `--allow-origin`).
class TapeStore {
  TapeStore(this.root);

  /// The notes folder, `.pinpoint/`.
  final Directory root;

  Directory get dir => Directory('${root.path}/tapes');

  File _json(String id) => File('${dir.path}/$id.json');
  Directory _bodies(String id) => Directory('${dir.path}/$id/bodies');

  /// Stores [tapeJson] (a `Tape.toJson`) and [bodies] (`bodiesToJson`).
  /// Returns its summary.
  Future<Map<String, Object?>> save(Object? tapeJson, Object? bodies) async {
    final tape = Tape.fromJson(tapeJson, bodies: bodies);
    if (tape == null) {
      throw const TapeStoreException('Not a tape: give {tape, bodies}');
    }
    // The id becomes a file name: a crafted id such as `../x` would reach
    // outside the folder.
    if (!tapeIdPattern.hasMatch(tape.id)) {
      throw TapeStoreException(
        'The tape id must match ${tapeIdPattern.pattern}',
      );
    }
    await dir.create(recursive: true);
    final folder = _bodies(tape.id);
    if (folder.existsSync()) await folder.delete(recursive: true);
    if (tape.bodies.isNotEmpty) await folder.create(recursive: true);
    for (final MapEntry(:key, :value) in tape.bodies.entries) {
      await File('${folder.path}/$key.bin').writeAsBytes(value);
    }
    final json = {...tape.toJson(), 'bytes': tape.bodyBytes};
    await _json(tape.id).writeAsString(jsonEncode(json));
    return tape.summary;
  }

  /// The tape [id], with its bodies when [withBodies]; null when there is
  /// none.
  Future<Tape?> read(String id, {bool withBodies = false}) async {
    if (!tapeIdPattern.hasMatch(id)) return null;
    final file = _json(id);
    if (!file.existsSync()) return null;
    final Object? json;
    try {
      json = jsonDecode(await file.readAsString());
    } on FormatException {
      return null;
    }
    final bodies = <String, Object?>{};
    if (withBodies) {
      final folder = _bodies(id);
      if (folder.existsSync()) {
        await for (final entry in folder.list()) {
          final name = entry.uri.pathSegments.last;
          if (entry is! File || !name.endsWith('.bin')) continue;
          bodies[name.substring(0, name.length - 4)] = base64Encode(
            await entry.readAsBytes(),
          );
        }
      }
    }
    return Tape.fromJson(json, bodies: bodies);
  }

  /// The summary of [id], with the size of its bodies on disk.
  Future<Map<String, Object?>?> summary(String id) async {
    final tape = await read(id);
    if (tape == null) return null;
    return {...tape.summary, 'bytes': await _bodyBytes(id)};
  }

  Future<int> _bodyBytes(String id) async {
    final folder = _bodies(id);
    if (!folder.existsSync()) return 0;
    var total = 0;
    await for (final entry in folder.list()) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  /// Every tape's summary, newest first.
  Future<List<Map<String, Object?>>> list() async {
    if (!dir.existsSync()) return const <Map<String, Object?>>[];
    final files = <(File, DateTime)>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        files.add((entry, await entry.lastModified()));
      }
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (file, _) in files)
        ?await summary(
          file.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), ''),
        ),
    ];
  }

  /// Deletes every tape saved before [cutoff], with its bodies: the
  /// bridge's `--ttl`. Returns the ids.
  Future<List<String>> expire(DateTime cutoff) async {
    if (!dir.existsSync()) return const <String>[];
    final gone = <String>[];
    await for (final entry in dir.list()) {
      final name = entry.uri.pathSegments.last;
      if (entry is! File || !name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - 5);
      if (!tapeIdPattern.hasMatch(id)) continue;
      if (!(await entry.lastModified()).isBefore(cutoff)) continue;
      await entry.delete();
      final folder = Directory('${dir.path}/$id');
      if (folder.existsSync()) await folder.delete(recursive: true);
      gone.add(id);
    }
    return gone;
  }

  /// The body [n] of tape [id], or null.
  Future<Uint8List?> body(String id, int n) async {
    if (!tapeIdPattern.hasMatch(id)) return null;
    final file = File('${_bodies(id).path}/$n.bin');
    return file.existsSync() ? file.readAsBytes() : null;
  }
}
