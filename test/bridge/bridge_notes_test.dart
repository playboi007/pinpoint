import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;

/// Milestone 8, build step 3: the bridge keeps one JSON file per note and
/// tells the app what changed.
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;

  Future<PinPointBridge> start() => PinPointBridge.start(
    dir: '${root.path}/.pinpoint',
    port: 0,
    allowedOrigins: const ['http://192.168.1.20:5000'],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_notes_');
    bridge = await start();
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Directory folder(String name) => Directory('${root.path}/.pinpoint/$name');
  List<String> names(String name) =>
      [for (final f in folder(name).listSync()) f.uri.pathSegments.last]
        ..sort();

  Future<(int, Object?)> call(
    String method,
    String path, {
    Object? body,
    String? origin = 'http://localhost:5000',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${bridge.port}$path'),
      );
      if (origin != null) request.headers.set('origin', origin);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> asMap(Object? json) => json! as Map<String, Object?>;

  List<String> ids(Object? json) => [
    for (final note in asMap(json)['notes']! as List<Object?>)
      asMap(note)['id']! as String,
  ];

  group('drafts', () {
    test('a draft goes to drafts/, with no .md for an agent to find', () async {
      final (status, body) = await call(
        'POST',
        '/annotations',
        body: note('pp_draft', status: 'draft', png: true),
      );
      expect(status, 201, reason: '$body');
      expect(asMap(body)['status'], 'draft');
      expect(names('drafts'), ['pp_draft.json', 'pp_draft.png']);
      expect(names('open'), isEmpty);
    });

    test('sent later, it moves to open/ and keeps its image', () async {
      await call(
        'POST',
        '/annotations',
        body: note('pp_draft', status: 'draft', png: true),
      );
      // As a restarted app sends it: the screenshot named, no image data.
      final (status, _) = await call(
        'POST',
        '/annotations',
        body: note('pp_draft', status: 'submitted'),
      );
      expect(status, 201);
      expect(names('drafts'), isEmpty);
      expect(names('open'), ['pp_draft.json', 'pp_draft.md', 'pp_draft.png']);
      final json = asMap(
        jsonDecode(
          File('${folder('open').path}/pp_draft.json').readAsStringSync(),
        ),
      );
      expect(asMap(json['screenshot'])['file'], 'pp_draft.png');
    });
  });

  group('GET /annotations', () {
    test('lists notes by status, oldest first', () async {
      await call('POST', '/annotations', body: note('pp_b', minute: 2));
      await call('POST', '/annotations', body: note('pp_a', minute: 1));
      await call(
        'POST',
        '/annotations',
        body: note('pp_c', minute: 3, status: 'draft'),
      );
      var (status, body) = await call('GET', '/annotations');
      expect(status, 200);
      expect(ids(body), ['pp_a', 'pp_b', 'pp_c']);
      expect(asMap(body)['cursor'], isA<String>());

      (_, body) = await call('GET', '/annotations?status=draft');
      expect(ids(body), ['pp_c']);
      (_, body) = await call('GET', '/annotations?status=submitted,draft');
      expect(ids(body), ['pp_a', 'pp_b', 'pp_c']);
    });

    // PLAN.md, Milestone 8, watch out: two apps poll one bridge. Notes are
    // keyed by the page's origin, so pins never show in the wrong tab.
    test('filters by the app origin', () async {
      await call(
        'POST',
        '/annotations',
        body: note('pp_five', origin: 'http://localhost:5000'),
      );
      await call(
        'POST',
        '/annotations',
        body: note('pp_six', origin: 'http://localhost:6000'),
      );
      final (_, body) = await call(
        'GET',
        '/annotations?origin=${Uri.encodeQueryComponent('http://localhost:6000')}',
      );
      expect(ids(body), ['pp_six']);
    });

    test('an unknown status is a 400', () async {
      final (status, body) = await call('GET', '/annotations?status=done');
      expect(status, 400);
      expect('$body', contains('done'));
    });

    test('a page from another machine may not read notes', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final (status, _) = await call(
        'GET',
        '/annotations',
        origin: 'https://evil.example',
      );
      expect(status, 403);
      final (allowed, _) = await call(
        'GET',
        '/annotations',
        origin: 'http://192.168.1.20:5000',
      );
      expect(allowed, 200);
    });

    test('a schema 1 note already on disk reads as submitted', () async {
      await bridge.close();
      File('${folder('open').path}/pp_old.json').writeAsStringSync(
        jsonEncode({'schema': 1, 'id': 'pp_old', 'comment': 'from M7'}),
      );
      bridge = await start();
      final (_, body) = await call('GET', '/annotations?status=submitted');
      expect(ids(body), ['pp_old']);
    });
  });

  group('PATCH /annotations/<id>', () {
    test('a status and a message move the note and rewrite its .md', () async {
      await call('POST', '/annotations', body: note('pp_a', png: true));
      final (status, body) = await call(
        'PATCH',
        '/annotations/pp_a',
        body: {'status': 'resolved', 'message': 'Not needed after all.'},
      );
      expect(status, 200, reason: '$body');
      expect(asMap(body)['status'], 'resolved');
      expect(names('open'), isEmpty);
      expect(names('resolved'), ['pp_a.json', 'pp_a.md', 'pp_a.png']);
      final md = File('${folder('resolved').path}/pp_a.md').readAsStringSync();
      expect(md, contains('Status: resolved'));
      expect(md, contains('- user ('));
      expect(md, contains('Not needed after all.'));
    });

    test('a draft comment can be edited', () async {
      await call('POST', '/annotations', body: note('pp_d', status: 'draft'));
      final (_, body) = await call(
        'PATCH',
        '/annotations/pp_d',
        body: {'comment': 'Better words'},
      );
      expect(asMap(body)['comment'], 'Better words');
      expect(asMap(body)['status'], 'draft');
    });

    test('refuses a bad id, an unknown note and a bad status', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      expect((await call('PATCH', '/annotations/..%2Fx', body: {})).$1, 400);
      expect(
        (await call(
          'PATCH',
          '/annotations/pp_none',
          body: {'status': 'fixed'},
        )).$1,
        404,
      );
      expect(
        (await call('PATCH', '/annotations/pp_a', body: {'status': 'done'})).$1,
        400,
      );
      expect(
        (await call('PATCH', '/annotations/pp_a', body: {'message': 3})).$1,
        400,
      );
    });
  });

  test('DELETE removes every file of the note', () async {
    await call('POST', '/annotations', body: note('pp_a', png: true));
    expect((await call('DELETE', '/annotations/pp_a')).$1, 200);
    expect(names('open'), isEmpty);
    expect((await call('DELETE', '/annotations/pp_a')).$1, 404);
  });

  group('GET /changes', () {
    Future<String> cursor() async =>
        asMap((await call('GET', '/annotations')).$2)['cursor']! as String;

    Future<Map<String, Object?>> changes(String since, {String? origin}) async {
      final query =
          'since=${Uri.encodeQueryComponent(since)}'
          '${origin == null ? '' : '&origin=${Uri.encodeQueryComponent(origin)}'}';
      final (status, body) = await call('GET', '/changes?$query');
      expect(status, 200);
      return asMap(body);
    }

    test('nothing since now', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final since = await cursor();
      final result = await changes(since);
      expect(result['changes'], isEmpty);
      expect(result['reset'], isFalse);
      expect(result['cursor'], since);
    });

    test('a status change, with the note, then a delete', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final since = await cursor();
      await call('PATCH', '/annotations/pp_a', body: {'status': 'inProgress'});
      var result = await changes(since);
      final change = asMap((result['changes']! as List<Object?>).single);
      expect(change['id'], 'pp_a');
      expect(change['status'], 'inProgress');
      expect(asMap(change['note'])['comment'], 'Fix it');

      final next = result['cursor']! as String;
      await call('DELETE', '/annotations/pp_a');
      result = await changes(next);
      expect(result['changes'], [
        {'id': 'pp_a', 'deleted': true},
      ]);
    });

    test('only notes of the origin asked for', () async {
      final since = await cursor();
      await call(
        'POST',
        '/annotations',
        body: note('pp_five', origin: 'http://localhost:5000'),
      );
      await call(
        'POST',
        '/annotations',
        body: note('pp_six', origin: 'http://localhost:6000'),
      );
      final result = await changes(since, origin: 'http://localhost:6000');
      expect(
        [for (final c in result['changes']! as List<Object?>) asMap(c)['id']],
        ['pp_six'],
      );
    });

    test('a note an agent moved to resolved/ by hand is resolved', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final since = await cursor();
      for (final ext in ['md', 'json']) {
        File('${folder('open').path}/pp_a.$ext')
            .renameSync('${folder('resolved').path}/pp_a.$ext');
      }
      final result = await changes(since);
      final change = asMap((result['changes']! as List<Object?>).single);
      expect(change['status'], 'resolved');
      final stored = asMap(
        jsonDecode(
          File('${folder('resolved').path}/pp_a.json').readAsStringSync(),
        ),
      );
      expect(stored['status'], 'resolved');
    });

    test('a cursor from an earlier run asks for a full reload', () async {
      final since = await cursor();
      await bridge.close();
      bridge = await start();
      expect((await changes(since))['reset'], isTrue);
      expect((await changes('nonsense'))['reset'], isTrue);
    });
  });

  // Acceptance (bridge side): "Restarting the app with the bridge running
  // restores all open pins." A restarted bridge has them too.
  test('a restarted bridge still has every note', () async {
    await call('POST', '/annotations', body: note('pp_a'));
    await call('POST', '/annotations', body: note('pp_b', status: 'draft'));
    await bridge.close();
    bridge = await start();
    final (_, body) = await call('GET', '/annotations');
    expect(ids(body), ['pp_a', 'pp_b']);
  });
}

/// A note of the current schema as the app sends it.
Map<String, Object?> note(
  String id, {
  String status = 'submitted',
  int minute = 0,
  String? origin = 'http://localhost:5000',
  bool png = false,
}) => {
  'schema': annotationSchema,
  'id': id,
  'createdAt': '2026-11-10T14:${minute.toString().padLeft(2, '0')}:00Z',
  'status': status,
  'intent': 'bug',
  'comment': 'Fix it',
  'app': {
    'buildMode': 'debug',
    'platform': 'web',
    'projectRoot': null,
    'origin': origin,
  },
  'page': {'route': '/'},
  'target': {
    'widget': 'Text',
    'source': {'file': 'lib/main.dart', 'line': 12, 'column': 5},
    'sourceUnavailable': false,
    'rect': {'x': 10, 'y': 20, 'w': 100, 'h': 30},
  },
  'anchor': {'file': 'lib/main.dart', 'line': 12, 'widget': 'Text'},
  'messages': const <Object?>[],
  'ancestors': const <Object?>[],
  'frameworkChain': const <Object?>[],
  'siblings': null,
  'subtree': null,
  'inherited': null,
  'screenshot': {
    'file': '$id.png',
    'pixelRatio': 1,
    'width': 1,
    'height': 1,
    if (png) 'data': _tinyPng,
  },
};

const String _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4b23wHwAGEQ'
    'Jq+GwfDQAAAABJRU5ErkJggg==';
