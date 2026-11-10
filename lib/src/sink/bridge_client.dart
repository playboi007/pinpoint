// Plain Dart: `package:http` works in the browser and in the VM.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../bridge/bridge_protocol.dart';
import '../model/annotation.dart';
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

  /// Stores [note] (a draft, or any note) with its image.
  Future<void> save(Annotation note) async {
    await _send(
      'POST',
      _at(annotationsPath),
      body: note.toJson(includeScreenshotData: true),
    );
  }

  /// Changes the note [id] on the bridge. Returns it as the bridge has it.
  Future<Annotation?> update(
    String id, {
    NoteStatus? status,
    String? comment,
    String? message,
  }) async {
    final json = await _send(
      'PATCH',
      _at('$annotationsPath/$id'),
      body: {
        'status': ?status?.name,
        'comment': ?comment,
        'message': ?message,
      },
    );
    return Annotation.fromJson(json);
  }

  /// Deletes the note [id]. A note the bridge does not have is fine.
  Future<void> delete(String id) async {
    try {
      await _send('DELETE', _at('$annotationsPath/$id'));
    } on HttpSinkException catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  /// What changed since [cursor], for notes of [origin] when given.
  Future<BridgeChanges> changes(String cursor, {String? origin}) async {
    final json = await _send(
      'GET',
      _at(changesPath, {'since': cursor, 'origin': ?origin}),
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

  static List<Annotation> _notes(Object? list) => [
    for (final note in list is List<Object?> ? list : const <Object?>[])
      if (note is Map<String, Object?>) ?Annotation.fromJson(note),
  ];

  Future<Map<String, Object?>> _send(
    String method,
    Uri url, {
    Object? body,
  }) async {
    final client = debugClient ?? http.Client();
    final http.Response response;
    try {
      final request = http.Request(method, url);
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw HttpSinkException('no answer from ${url.authority}');
    } on http.ClientException {
      throw HttpSinkException('cannot reach ${url.authority}');
    } finally {
      if (debugClient == null) client.close();
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
