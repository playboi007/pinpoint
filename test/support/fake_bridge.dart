import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The bridge's HTTP routes in memory, for widget tests: the widget binding
/// fakes `HttpClient`, so a real bridge cannot be reached from them.
///
/// It keeps notes as JSON, numbers every change like the real store, and
/// records every request.
class FakeBridge {
  late final http.Client client = MockClient(handle);

  /// Notes by id, as the bridge stores them (no image data).
  final Map<String, Map<String, Object?>> notes = {};

  /// Every request, as `METHOD /path`.
  final List<String> requests = <String>[];

  /// Every request's URL, for the query a test checks.
  final List<Uri> urls = <Uri>[];

  /// When true, every request fails as if the bridge were stopped.
  bool offline = false;

  /// When true, `GET /changes?wait=…` is held until a change comes or
  /// [releasePolls] says the wait is over, as the real bridge does. Else
  /// it answers at once, as a bridge that does not know `wait`.
  bool longPoll = false;

  int _seq = 0;
  final Map<String, int> _changed = {};

  /// The `client` query of the last write to each note; absent for the
  /// agent's changes.
  final Map<String, String> _changedBy = {};

  /// Made by the request that holds, so it belongs to the test's zone: a
  /// completer made in `setUp` would not wake a fake-async continuation.
  Completer<void>? _wake;
  int _releases = 0;

  /// Ends every held `/changes` request with what it has (an empty answer
  /// when nothing changed): the wait ran out.
  void releasePolls() {
    _releases++;
    _wakeHolders();
  }

  void _wakeHolders() {
    final waiting = _wake;
    _wake = null;
    waiting?.complete();
  }

  void _touch(String id, {String? client}) {
    _changed[id] = ++_seq;
    if (client == null) {
      _changedBy.remove(id);
    } else {
      _changedBy[id] = client;
    }
    _wakeHolders();
  }

  List<Map<String, Object?>> _since(int since, String? client) => [
    for (final MapEntry(key: id, value: seq) in _changed.entries)
      if (seq > since && (client == null || _changedBy[id] != client))
        _deleted.contains(id)
            ? {'id': id, 'deleted': true}
            : {'id': id, 'status': notes[id]!['status'], 'note': notes[id]},
  ];
  final Set<String> _deleted = {};

  /// Tapes as the app posted them: `{tape, bodies}` by id.
  final Map<String, Map<String, Object?>> tapes = {};

  /// Events of replay runs, by run id, and their last status.
  final Map<String, List<Map<String, Object?>>> runEvents = {};
  final Map<String, Map<String, Object?>> runStatus = {};

  int count(String request) => requests.where((r) => r == request).length;

  /// What `verify_note` stores: the result, and Pinpoint's message.
  void agentVerify(String id, {required bool passed}) {
    final note = notes[id]!;
    note['verification'] = {
      'at': '2026-11-10T15:00:00Z',
      'passed': passed,
      'checks': [
        {'type': 'visible', 'passed': passed},
      ],
    };
    note['messages'] = [
      ...(note['messages'] as List<Object?>? ?? const []),
      {
        'at': '2026-11-10T15:00:00Z',
        'from': 'pinpoint',
        'text': 'Checks ${passed ? 'passed' : 'failed'}',
      },
    ];
    _touch(id);
  }

  /// What the agent does through `update_note`.
  void agentUpdate(String id, String status, {String? message}) {
    final note = notes[id]!;
    note['status'] = status;
    if (message != null) {
      note['messages'] = [
        ...(note['messages'] as List<Object?>? ?? const []),
        {'at': '2026-11-10T15:00:00Z', 'from': 'agent', 'text': message},
      ];
    }
    _touch(id);
  }

  /// Answers [request] as the bridge would.
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    urls.add(request.url);
    if (offline) throw http.ClientException('Connection refused');
    final query = request.url.queryParameters;
    final id = path.startsWith('/annotations/')
        ? path.substring('/annotations/'.length)
        : null;
    if (path == '/tapes' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final tape = body['tape']! as Map<String, Object?>;
      tapes[tape['id']! as String] = body;
      return _json({
        'id': tape['id'],
        'kind': tape['kind'],
        'inputs': (tape['inputs']! as List<Object?>).length,
        'requests': (tape['net']! as List<Object?>).length,
      });
    }
    if (path.startsWith('/tapes/') && request.method == 'GET') {
      final tape = tapes[path.substring('/tapes/'.length)];
      return tape == null ? _json({'error': 'No tape'}, 404) : _json(tape);
    }
    final run = RegExp(r'^/runs/([^/]+)/(events|status)$').firstMatch(path);
    if (run != null && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      if (run[2] == 'events') {
        (runEvents[run[1]!] ??= []).addAll(
          (body['events']! as List<Object?>).cast<Map<String, Object?>>(),
        );
      } else {
        runStatus[run[1]!] = body;
      }
      return _json({'ok': true});
    }
    switch ((request.method, path)) {
      case ('GET', '/health'):
        return _json({'ok': true});
      case ('POST', '/annotations'):
        final note = jsonDecode(request.body) as Map<String, Object?>;
        (note['screenshot'] as Map<String, Object?>?)?.remove('data');
        note['status'] ??= 'submitted';
        notes[note['id']! as String] = note;
        _touch(note['id']! as String, client: query['client']);
        return _json({'id': note['id']}, 201);
      case ('GET', '/annotations'):
        final statuses = query['status']?.split(',').toSet();
        return _json({
          'cursor': '$_seq',
          'notes': [
            for (final note in notes.values)
              if (statuses == null || statuses.contains(note['status'])) note,
          ],
        });
      case ('GET', '/changes'):
        final since = int.tryParse(query['since'] ?? '');
        if (since == null) return _json({'cursor': '$_seq', 'reset': true});
        final client = query['client'];
        var found = _since(since, client);
        if (longPoll && query['wait'] != null) {
          final released = _releases;
          while (found.isEmpty && _releases == released) {
            await (_wake ??= Completer<void>()).future;
            found = _since(since, client);
          }
        }
        return _json({'cursor': '$_seq', 'reset': false, 'changes': found});
    }
    if (id != null) {
      final note = notes[id];
      if (note == null) return _json({'error': 'No note $id'}, 404);
      switch (request.method) {
        case 'PATCH':
          final body = jsonDecode(request.body) as Map<String, Object?>;
          // As NoteStore.update: back to submitted after the agent worked
          // the note is a reopen.
          if (body['status'] == 'submitted' &&
              note['status'] != 'submitted' &&
              note['status'] != 'draft') {
            note.remove('verification');
            note['reopened'] = ((note['reopened'] as int?) ?? 0) + 1;
          }
          for (final field in ['status', 'comment', 'intent']) {
            if (body[field] != null) note[field] = body[field];
          }
          if (body['message'] case final String text) {
            note['messages'] = [
              ...(note['messages'] as List<Object?>? ?? const []),
              {'at': '2026-11-10T15:00:00Z', 'from': 'user', 'text': text},
            ];
          }
          _touch(id, client: query['client']);
          return _json(note);
        case 'DELETE':
          notes.remove(id);
          _deleted.add(id);
          _touch(id, client: query['client']);
          return _json({'id': id, 'deleted': true});
      }
    }
    return _json({'error': 'Not found'}, 404);
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}
