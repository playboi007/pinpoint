// Plain Dart: `package:http` works in the browser and in the VM.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../bridge/bridge_protocol.dart';
import '../model/annotation.dart';
import '../model/tape.dart';
import 'http_sink.dart';
import 'pinpoint_sink.dart';

/// What [BridgeClient.changes] returned.
class BridgeChanges {
  const BridgeChanges({
    required this.cursor,
    required this.notes,
    required this.deleted,
    required this.reset,
  });

  /// Pass this as `since` next time.
  final String cursor;

  /// Notes that changed, as the bridge has them now.
  final List<Annotation> notes;

  /// Ids of deleted notes.
  final List<String> deleted;

  /// The bridge restarted since the last cursor: reload every note.
  final bool reset;
}

/// What the bridge answered to [BridgeClient.undo].
class UndoResult {
  const UndoResult({
    required this.undo,
    this.reverted = const <String>[],
    this.conflicts = const <String>[],
    this.reloaded = false,
    this.note,
  });

  /// `done`: the bridge put the files back. `requested`: it asked the
  /// agent to (no git, or a file changed since). `failed`: git failed, and
  /// it asked the agent as for `requested`.
  final String undo;

  /// The files that went back, relative to the git top level.
  final List<String> reverted;

  /// The files that no longer fit the patch (a `requested` answer).
  final List<String> conflicts;

  /// Whether the bridge hot reloaded the app after a `done` undo.
  final bool reloaded;

  /// The note as the bridge has it now: submitted again, with the user's
  /// message and the round marked.
  final Annotation? note;

  bool get isDone => undo == 'done';

  /// Whether the agent was asked to undo the changes.
  bool get isRequested => !isDone;
}

/// The app's side of the bridge, beside the [HttpSink] that posts notes:
/// it loads the pins, stores drafts and edits, and asks what changed.
///
/// Every call throws an [HttpSinkException] when the bridge does not
/// answer, or answers with an error.
class BridgeClient {
  BridgeClient(this.base, {this.timeout = const Duration(seconds: 5)});

  /// The bridge for [sinks], or null when there is none: [url] when set,
  /// else the address of the first [HttpSink] that posts to a bridge's
  /// `/annotations`.
  static BridgeClient? find({Uri? url, List<PinPointSink> sinks = const []}) {
    if (url != null) return BridgeClient(url.replace(path: '', query: ''));
    for (final sink in sinks) {
      if (sink is HttpSink && sink.url.path == annotationsPath) {
        return BridgeClient(
          Uri(
            scheme: sink.url.scheme,
            host: sink.url.host,
            port: sink.url.port,
          ),
        );
      }
    }
    return null;
  }

  /// For example `http://127.0.0.1:4747`.
  final Uri base;

  final Duration timeout;

  /// Replaces the HTTP client, for tests only: widget tests cannot open
  /// sockets. (No `@visibleForTesting`: `package:meta` is not a declared
  /// dependency, and this file stays free of Flutter.)
  static http.Client? debugClient;

  /// The statuses whose notes show as pins.
  static const Set<NoteStatus> pinStatuses = {
    NoteStatus.draft,
    NoteStatus.submitted,
    NoteStatus.inProgress,
    NoteStatus.fixed,
    NoteStatus.resolved,
    NoteStatus.rejected,
  };

  Uri _at(String path, [Map<String, String>? query]) => base.replace(
    path: path,
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// The notes to show as pins, written on pages of [origin] when given,
  /// and the cursor to poll [changes] from.
  Future<({String cursor, List<Annotation> notes})> load({
    String? origin,
  }) async {
    final json = await _send(
      'GET',
      _at(annotationsPath, {
        'status': [for (final s in pinStatuses) s.name].join(','),
        'origin': ?origin,
      }),
    );
    return (
      cursor: json['cursor'] is String ? json['cursor']! as String : '',
      notes: _notes(json['notes']),
    );
  }

  /// Stores [note] (a draft, or any note) with its image. [client] is the
  /// writing tab's id: its own `/changes` leaves this write out.
  Future<void> save(Annotation note, {String? client}) async {
    await _send(
      'POST',
      _at(annotationsPath, {'client': ?client}),
      body: note.toJson(includeScreenshotData: true),
    );
  }

  /// Changes the note [id] on the bridge. Returns it as the bridge has it.
  Future<Annotation?> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? message,
    String? client,
  }) async {
    final json = await _send(
      'PATCH',
      _at('$annotationsPath/$id', {'client': ?client}),
      body: {'status': ?status?.name, 'comment': ?comment, 'message': ?message},
    );
    return Annotation.fromJson(json);
  }

  /// Undoes the changes [changes] (ids such as `c1`, or `['*']` for all) of
  /// round [round] of note [id] (PLAN-v3 Milestone 20), with the user's
  /// [reason]. The bridge puts the files back when it can, hot reloads the
  /// app, and opens the note again; without git, or when a file changed
  /// since, it asks the agent instead. Waits for the reload, so it may take
  /// some seconds. Throws an [HttpSinkException] for a refusal (404, 409).
  Future<UndoResult> undo(
    String id,
    int round,
    List<String> changes, {
    String? reason,
    String? client,
  }) async {
    final json = await _send(
      'POST',
      _at('$annotationsPath/$id/$undoSegment', {'client': ?client}),
      body: {'round': round, 'changes': changes, 'reason': ?reason},
      timeout: const Duration(seconds: 60),
    );
    List<String> strings(Object? list) => [
      if (list is List<Object?>)
        for (final item in list)
          if (item is String) item,
    ];
    return UndoResult(
      undo: json['undo'] is String ? json['undo']! as String : 'requested',
      reverted: strings(json['reverted']),
      conflicts: strings(json['conflicts']),
      reloaded: json['reloaded'] == true,
      note: json['note'] is Map<String, Object?>
          ? Annotation.fromJson(json['note']! as Map<String, Object?>)
          : null,
    );
  }

  /// Deletes the note [id]. A note the bridge does not have is fine.
  Future<void> delete(String id, {String? client}) async {
    try {
      await _send('DELETE', _at('$annotationsPath/$id', {'client': ?client}));
    } on HttpSinkException catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  /// What changed since [cursor], for notes of [origin] when given.
  ///
  /// With [wait], the bridge holds the answer until there is a change, for
  /// at most [wait] (an older bridge answers at once). With [client], the
  /// bridge leaves out the changes that tab wrote itself. An [http.Client]
  /// passed in stays open: the caller closes it to end a held request.
  Future<BridgeChanges> changes(
    String cursor, {
    String? origin,
    Duration? wait,
    String? client,
    http.Client? connection,
  }) async {
    final json = await _send(
      'GET',
      _at(changesPath, {
        'since': cursor,
        'origin': ?origin,
        if (wait != null) 'wait': '${wait.inSeconds}',
        'client': ?client,
      }),
      client: connection,
      timeout: wait == null ? null : wait + const Duration(seconds: 10),
    );
    final notes = <Annotation>[];
    final deleted = <String>[];
    final list = json['changes'];
    for (final change in list is List<Object?> ? list : const <Object?>[]) {
      if (change is! Map<String, Object?>) continue;
      final id = change['id'];
      if (id is! String) continue;
      if (change['deleted'] == true) {
        deleted.add(id);
      } else if (change['note'] case final Map<String, Object?> note) {
        if (Annotation.fromJson(note) case final parsed?) notes.add(parsed);
      }
    }
    return BridgeChanges(
      cursor: json['cursor'] is String ? json['cursor']! as String : cursor,
      notes: notes,
      deleted: deleted,
      reset: json['reset'] == true,
    );
  }

  /// The app's long poll: the next agent command as `{id, tool, args}`, or
  /// null when none came within [wait].
  ///
  /// With [client], the request goes through it and it stays open: closing
  /// it ends a held poll at once.
  Future<Map<String, Object?>?> nextCommand({
    Duration wait = commandWait,
    http.Client? client,
  }) async {
    final json = await _send(
      'GET',
      _at(commandsPath, {'wait': '${wait.inSeconds}'}),
      client: client,
      timeout: wait + const Duration(seconds: 10),
    );
    final command = json['command'];
    return command is Map<String, Object?> ? command : null;
  }

  /// Hands the answer to the command [id] back to the bridge.
  Future<void> postCommandResult(String id, Map<String, Object?> answer) =>
      _send(
        'POST',
        _at('$commandsPath/$id/result'),
        body: answer,
        timeout: const Duration(seconds: 30),
      );

  /// Tells the bridge that the user turned agent control on or off. Off
  /// fails every command the app has not answered.
  Future<void> setAgentControl({required bool enabled}) =>
      _send('POST', _at('$commandsPath/control'), body: {'enabled': enabled});

  /// Stores [tape] and its bodies on the bridge (PLAN-v2 Milestone 15).
  /// Returns its summary as the bridge has it.
  Future<Map<String, Object?>> saveTape(Tape tape) => _send(
    'POST',
    _at(tapesPath),
    body: {'tape': tape.toJson(), 'bodies': tape.bodiesToJson()},
    timeout: const Duration(seconds: 60),
  );

  /// The tape [id] with its bodies, or null when the bridge has none.
  Future<Tape?> loadTape(String id) async {
    try {
      final json = await _send(
        'GET',
        _at('$tapesPath/$id'),
        timeout: const Duration(seconds: 60),
      );
      return Tape.fromJson(json['tape'], bodies: json['bodies']);
    } on HttpSinkException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The lines of the method around [line] of [file], as `{file, start,
  /// end, text}`, or null when the bridge has no such file or refuses the
  /// path (PLAN-v3 Milestone 21). [before] is how far up the method start
  /// is looked for.
  Future<({String file, int start, int end, String text})?> source(
    String file,
    int line, {
    int before = 15,
  }) async {
    final Map<String, Object?> json;
    try {
      json = await _send(
        'GET',
        _at(sourcePath, {'file': file, 'line': '$line', 'before': '$before'}),
      );
    } on HttpSinkException catch (error) {
      if (const {400, 403, 404}.contains(error.statusCode)) return null;
      rethrow;
    }
    final found = json['file'];
    final start = json['start'];
    final end = json['end'];
    final text = json['text'];
    if (found is String && start is int && end is int && text is String) {
      return (file: found, start: start, end: end, text: text);
    }
    return null;
  }

  /// Where the type [type] is declared, as `{file, line}`, or null when the
  /// bridge finds none (PLAN-v3 Milestone 21).
  Future<({String file, int line})?> declaration(String type) async {
    final Map<String, Object?> json;
    try {
      json = await _send('GET', _at(declarationPath, {'type': type}));
    } on HttpSinkException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 400) return null;
      rethrow;
    }
    final file = json['file'];
    final line = json['line'];
    return file is String && line is int ? (file: file, line: line) : null;
  }

  /// Where the replay run [run] is: `{state, step, of, first_difference,
  /// …}` as the player answers. The bridge's `replay` waits for it after a
  /// restart.
  Future<void> postRunStatus(String run, Map<String, Object?> status) =>
      _send('POST', _at('$runsPath/$run/status'), body: status);

  /// A batch of the run's events, as JSON (step 14).
  Future<void> postRunEvents(String run, List<Map<String, Object?>> events) =>
      _send(
        'POST',
        _at('$runsPath/$run/events'),
        body: {'events': events},
        timeout: const Duration(seconds: 30),
      );

  static List<Annotation> _notes(Object? list) => [
    for (final note in list is List<Object?> ? list : const <Object?>[])
      if (note is Map<String, Object?>) ?Annotation.fromJson(note),
  ];

  Future<Map<String, Object?>> _send(
    String method,
    Uri url, {
    Object? body,
    http.Client? client,
    Duration? timeout,
  }) async {
    // A client passed in belongs to the caller, who may close it to end a
    // held request.
    final owned = client == null && debugClient == null;
    final sender = client ?? debugClient ?? http.Client();
    final wait = timeout ?? this.timeout;
    final http.Response response;
    try {
      final request = http.Request(method, url);
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await http.Response.fromStream(
        await sender.send(request).timeout(wait),
      ).timeout(wait);
    } on TimeoutException {
      throw HttpSinkException('no answer from ${url.authority}');
    } on http.ClientException {
      throw HttpSinkException('cannot reach ${url.authority}');
    } finally {
      if (owned) sender.close();
    }
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      final error = decoded is Map<String, Object?> ? decoded['error'] : null;
      throw HttpSinkException(
        'HTTP $status: ${error is String ? error : 'no reason given'}',
        statusCode: status,
      );
    }
    return decoded is Map<String, Object?> ? decoded : const {};
  }
}
