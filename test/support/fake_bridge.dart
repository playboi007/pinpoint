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

  /// When true, every request fails as if the bridge were stopped.
  bool offline = false;

  int _seq = 0;
  final Map<String, int> _changed = {};
  final Set<String> _deleted = {};

  int count(String request) => requests.where((r) => r == request).length;

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
    _changed[id] = ++_seq;
  }

  /// Answers [request] as the bridge would.
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    if (offline) throw http.ClientException('Connection refused');
    final query = request.url.queryParameters;
    final id = path.startsWith('/annotations/')
        ? path.substring('/annotations/'.length)
        : null;
    switch ((request.method, path)) {
      case ('GET', '/health'):
        return _json({'ok': true});
      case ('POST', '/annotations'):
        final note = jsonDecode(request.body) as Map<String, Object?>;
        (note['screenshot'] as Map<String, Object?>?)?.remove('data');
        note['status'] ??= 'submitted';
        notes[note['id']! as String] = note;
        _changed[note['id']! as String] = ++_seq;
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
        return _json({
          'cursor': '$_seq',
          'reset': false,
          'changes': [
            for (final MapEntry(key: id, value: seq) in _changed.entries)
              if (seq > since)
                _deleted.contains(id)
                    ? {'id': id, 'deleted': true}
                    : {
                        'id': id,
                        'status': notes[id]!['status'],
                        'note': notes[id],
                      },
          ],
        });
    }
    if (id != null) {
      final note = notes[id];
      if (note == null) return _json({'error': 'No note $id'}, 404);
      switch (request.method) {
        case 'PATCH':
          final body = jsonDecode(request.body) as Map<String, Object?>;
          for (final field in ['status', 'comment', 'intent']) {
            if (body[field] != null) note[field] = body[field];
          }
          _changed[id] = ++_seq;
          return _json(note);
        case 'DELETE':
          notes.remove(id);
          _deleted.add(id);
          _changed[id] = ++_seq;
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
