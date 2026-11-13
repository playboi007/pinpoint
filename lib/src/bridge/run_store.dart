// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so the
// bridge can run it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/tape.dart' show runIdPattern;
import '../model/trace_event.dart';

/// Replay runs on disk (PLAN-v2 Milestone 15, step 14): the events in
/// `<dir>/runs/<id>.jsonl` and the last status in `<dir>/runs/<id>.json`.
/// A page reload clears the app's memory, so the bridge is where a run
/// lives. The newest [keep] runs are kept.
class RunStore {
  RunStore(this.root, {this.keep = 20});

  /// The notes folder, `.pinpoint/`.
  final Directory root;
  final int keep;

  Directory get dir => Directory('${root.path}/runs');

  File _events(String id) => File('${dir.path}/$id.jsonl');
  File _status(String id) => File('${dir.path}/$id.json');

  final Map<String, List<Completer<Map<String, Object?>>>> _waiting =
      <String, List<Completer<Map<String, Object?>>>>{};

  /// Whether [id] can be a run id (a file name).
  static bool valid(String id) => runIdPattern.hasMatch(id);

  /// Adds [events] (`TraceEvent.toJson` maps) to the run [id].
  Future<void> addEvents(String id, List<Object?> events) async {
    await _create(id);
    final lines = StringBuffer();
    for (final event in events) {
      if (event is Map<String, Object?>) lines.writeln(jsonEncode(event));
    }
    await _events(id).writeAsString('$lines', mode: FileMode.append);
  }

  /// Sets the run's status and wakes whoever waits for it.
  Future<void> setStatus(String id, Map<String, Object?> status) async {
    await _create(id);
    await _status(id).writeAsString(jsonEncode(status));
    for (final waiter
        in _waiting.remove(id) ?? const <Completer<Map<String, Object?>>>[]) {
      if (!waiter.isCompleted) waiter.complete(status);
    }
  }

  Future<void> _create(String id) async {
    await dir.create(recursive: true);
    if (_status(id).existsSync() || _events(id).existsSync()) return;
    await _status(id).writeAsString(jsonEncode({'run': id, 'state': 'new'}));
    await _prune();
  }

  /// Keeps the newest [keep] runs.
  Future<void> _prune() async {
    final runs = <String, DateTime>{};
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final id = name.replaceFirst(RegExp(r'\.jsonl?$'), '');
      final at = await entry.lastModified();
      final known = runs[id];
      if (known == null || at.isAfter(known)) runs[id] = at;
    }
    if (runs.length <= keep) return;
    final oldest = runs.keys.toList()
      ..sort((a, b) => runs[a]!.compareTo(runs[b]!));
    for (final id in oldest.take(runs.length - keep)) {
      for (final file in [_events(id), _status(id)]) {
        if (file.existsSync()) await file.delete();
      }
    }
  }

  /// The last status of [id], or null.
  Future<Map<String, Object?>?> status(String id) async {
    if (!valid(id)) return null;
    final file = _status(id);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  /// The next status of [id] set after now, or null after [timeout].
  Future<Map<String, Object?>?> nextStatus(
    String id, {
    Duration timeout = const Duration(seconds: 240),
  }) {
    final waiter = Completer<Map<String, Object?>>();
    (_waiting[id] ??= []).add(waiter);
    return waiter.future
        .timeout(
          timeout,
          onTimeout: () {
            _waiting[id]?.remove(waiter);
            return <String, Object?>{};
          },
        )
        .then((status) => status.isEmpty ? null : status);
  }

  /// The events of [id], or null when there is no such run.
  Future<List<TraceEvent>?> events(String id) async {
    if (!valid(id)) return null;
    final file = _events(id);
    if (!file.existsSync()) {
      return _status(id).existsSync() ? const <TraceEvent>[] : null;
    }
    return TraceEvent.parseJsonl(await file.readAsString());
  }

  /// Every run's last status, newest first.
  Future<List<Map<String, Object?>>> list() async {
    if (!dir.existsSync()) return const [];
    final files = <(File, DateTime)>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        files.add((entry, await entry.lastModified()));
      }
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final (file, _) in files)
        ?await status(file.uri.pathSegments.last.replaceFirst('.json', '')),
    ];
  }
}
