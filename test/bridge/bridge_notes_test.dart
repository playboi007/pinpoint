import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/tmp_bin.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;
import 'package:pinpoint/src/model/tape.dart';

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
  List<String> names(String name) => [
    for (final f in folder(name).listSync())
      f.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
  ]..sort();

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
      expect(md, contains('pp_a (bug, resolved)'));
      expect(md, contains('- user: Not needed after all.'));
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

  group('DELETE moves the note to tmp/', () {
    final png = Uint8List.fromList(const [137, 80, 78, 71]);

    Map<String, Object?> withTape(String id, String tapeId) => {
      ...note(id, png: true),
      'tape': {'id': tapeId, 'kind': 'full'},
    };

    Future<void> saveTape(String id) => bridge.tapes.save(
      Tape(
        id: id,
        kind: TapeKind.full,
        start: const TapeStart(t: 0, seq: 1, wallTime: 'w'),
        bodies: {0: Uint8List.fromList(utf8.encode('{}'))},
      ).toJson(),
      {'0': base64Encode(utf8.encode('{}'))},
    );

    test('every file goes into one tmp/<id>__<stamp>/ folder', () async {
      await call('POST', '/annotations', body: note('pp_a', png: true));
      await bridge.store.saveAfter('pp_a', png);
      expect(names('open'), [
        'pp_a.after.png',
        'pp_a.json',
        'pp_a.md',
        'pp_a.png',
      ]);
      final since = asMap((await call('GET', '/annotations')).$2)['cursor'];

      expect((await call('DELETE', '/annotations/pp_a')).$1, 200);

      expect(names('open'), isEmpty);
      final entries = names('tmp');
      expect(entries, hasLength(1));
      expect(entries.single, matches(RegExp(r'^pp_a__\d{8}T\d{6}Z$')));
      expect(TmpBin.stampOf(entries.single), isNotNull);
      expect(names('tmp/${entries.single}'), [
        'pp_a.after.png',
        'pp_a.json',
        'pp_a.md',
        'pp_a.png',
      ]);
      // Gone for the app: list, load, and /changes.
      expect(ids((await call('GET', '/annotations')).$2), isEmpty);
      expect((await call('GET', '/annotations/pp_a')).$1, 404);
      expect(await bridge.store.read('pp_a'), isNull);
      final changes = asMap(
        (await call(
          'GET',
          '/changes?since=${Uri.encodeQueryComponent('$since')}',
        )).$2,
      );
      expect(changes['changes'], [
        {'id': 'pp_a', 'deleted': true},
      ]);
      // A second delete: no note any more.
      expect((await call('DELETE', '/annotations/pp_a')).$1, 404);
    });

    test('a draft goes to tmp/ too', () async {
      await call(
        'POST',
        '/annotations',
        body: note('pp_d', status: 'draft', png: true),
      );
      await call('DELETE', '/annotations/pp_d');
      expect(names('drafts'), isEmpty);
      expect(names('tmp/${names('tmp').single}'), ['pp_d.json', 'pp_d.png']);
    });

    test('the same id deleted twice gives two entries', () async {
      for (var i = 0; i < 2; i++) {
        await call('POST', '/annotations', body: note('pp_a', png: true));
        expect((await call('DELETE', '/annotations/pp_a')).$1, 200);
      }
      final entries = names('tmp');
      expect(entries, hasLength(2));
      for (final entry in entries) {
        expect(entry, startsWith('pp_a__'));
        expect(names('tmp/$entry'), ['pp_a.json', 'pp_a.md', 'pp_a.png']);
      }
    });

    test('its tape moves too when no other note uses it', () async {
      await saveTape('tp_only_0001');
      await call(
        'POST',
        '/annotations',
        body: withTape('pp_a', 'tp_only_0001'),
      );
      await call('DELETE', '/annotations/pp_a');
      expect(names('tapes'), isEmpty);
      final entry = names('tmp').single;
      expect(names('tmp/$entry'), contains('tapes'));
      expect(names('tmp/$entry/tapes'), ['tp_only_0001', 'tp_only_0001.json']);
      expect(names('tmp/$entry/tapes/tp_only_0001/bodies'), ['0.bin']);
    });

    test('its tape stays when another note uses it', () async {
      await saveTape('tp_both_0001');
      await call(
        'POST',
        '/annotations',
        body: withTape('pp_a', 'tp_both_0001'),
      );
      // The other note is a draft, so the check covers every folder.
      await call(
        'POST',
        '/annotations',
        body: {...withTape('pp_b', 'tp_both_0001'), 'status': 'draft'},
      );
      await call('DELETE', '/annotations/pp_a');
      expect(names('tapes'), ['tp_both_0001', 'tp_both_0001.json']);
      expect(names('tmp/${names('tmp').single}'), isNot(contains('tapes')));
      // Now the last user of the tape goes: the tape follows.
      await call('DELETE', '/annotations/pp_b');
      expect(names('tapes'), isEmpty);
    });
  });

  group('the tmp/ flush', () {
    final t0 = DateTime.utc(2026, 11, 20, 12);

    Directory entry(String name) =>
        Directory('${folder('tmp').path}/$name')..createSync(recursive: true);

    test('removes an entry 61 min old, keeps one 59 min old', () async {
      entry(
        'pp_old__${TmpBin.stamp(t0.subtract(const Duration(minutes: 61)))}',
      );
      entry(
        'pp_new__${TmpBin.stamp(t0.subtract(const Duration(minutes: 59)))}',
      );
      entry('pp_edge__${TmpBin.stamp(t0.subtract(tmpKeep))}');
      expect(await bridge.flushTmp(now: t0), 2);
      expect(names('tmp'), [
        'pp_new__${TmpBin.stamp(t0.subtract(const Duration(minutes: 59)))}',
      ]);
      expect(await bridge.flushTmp(now: t0), 0);
    });

    test('an unreadable name uses the modification time', () async {
      // Dart cannot set a folder's time, so the entries are files here.
      folder('tmp').createSync(recursive: true);
      File('${folder('tmp').path}/odd_name')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(t0.subtract(const Duration(hours: 3)));
      File('${folder('tmp').path}/fresh_name')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(t0);
      expect(await bridge.flushTmp(now: t0), 1);
      expect(names('tmp'), ['fresh_name']);
    });

    test('does nothing on an empty or missing folder', () async {
      folder('tmp').createSync(recursive: true);
      expect(await bridge.flushTmp(now: t0), 0);
      folder('tmp').deleteSync(recursive: true);
      expect(await bridge.flushTmp(now: t0), 0);
    });

    test('runs on a timer that close() cancels', () async {
      expect(bridge.tmpFlushActive, isTrue);
      await bridge.close();
      expect(bridge.tmpFlushActive, isFalse);
      // tearDown closes it again: that must be harmless.
    });

    test('flushes at start what is already old', () async {
      await bridge.close();
      entry('pp_old__${TmpBin.stamp(DateTime.now().subtract(tmpKeep * 2))}');
      bridge = await start();
      // The first flush runs without being awaited: wait for it.
      await bridge.store.list(); // queued behind the start flush
      expect(names('tmp'), isEmpty);
    });
  });

  group('sync and tmp/', () {
    test(
      'sync never reads tmp/ as notes; a hand-restored note returns',
      () async {
        await call('POST', '/annotations', body: note('pp_a', png: true));
        await call('DELETE', '/annotations/pp_a');
        await bridge.store.sync();
        expect(ids((await call('GET', '/annotations')).$2), isEmpty);

        // The manual undo: move the files back into open/.
        final entry = Directory('${folder('tmp').path}/${names('tmp').single}');
        final since = asMap((await call('GET', '/annotations')).$2)['cursor'];
        for (final file in entry.listSync().whereType<File>()) {
          file.renameSync(
            '${folder('open').path}/${file.uri.pathSegments.last}',
          );
        }
        await bridge.store.sync();
        expect(ids((await call('GET', '/annotations')).$2), ['pp_a']);
        final changes = asMap(
          (await call(
            'GET',
            '/changes?since=${Uri.encodeQueryComponent('$since')}',
          )).$2,
        );
        expect((changes['changes']! as List<Object?>).length, 1);
      },
    );
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
        File(
          '${folder('open').path}/pp_a.$ext',
        ).renameSync('${folder('resolved').path}/pp_a.$ext');
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

  // PLAN-v3 Milestone 19, steps 1 and 2: `GET /changes` can be held until
  // something changes, and a tab is not told about its own writes.
  group('GET /changes, held (long poll)', () {
    Future<String> cursor() async =>
        asMap((await call('GET', '/annotations')).$2)['cursor']! as String;

    /// One request, and how long the bridge took to answer it.
    Future<(Map<String, Object?>, Duration)> ask(
      String since, {
      int? wait,
      String? client,
    }) async {
      final clock = Stopwatch()..start();
      final query = {
        'since': since,
        'origin': 'http://localhost:5000',
        if (wait != null) 'wait': '$wait',
        'client': ?client,
      };
      final (status, body) = await call(
        'GET',
        Uri(path: '/changes', queryParameters: query).toString(),
      );
      expect(status, 200);
      return (asMap(body), clock.elapsed);
    }

    List<Object?> found(Map<String, Object?> result) => [
      for (final c in result['changes']! as List<Object?>) asMap(c)['id'],
    ];

    test('answers at once when a change is already there', () async {
      final since = await cursor();
      await call('POST', '/annotations', body: note('pp_a'));
      final (result, took) = await ask(since, wait: 20);
      expect(found(result), ['pp_a']);
      expect(took, lessThan(const Duration(seconds: 2)));
    });

    test('answers at once on a reset', () async {
      final (result, took) = await ask('nonsense', wait: 20);
      expect(result['reset'], isTrue);
      expect(took, lessThan(const Duration(seconds: 2)));
    });

    test('answers as a change comes, not at the end of the wait', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final since = await cursor();
      final pending = ask(since, wait: 20);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await call('PATCH', '/annotations/pp_a', body: {'status': 'inProgress'});
      final (result, took) = await pending;
      expect(found(result), ['pp_a']);
      expect(took, lessThan(const Duration(seconds: 3)));
    });

    test('answers empty when the wait ends with no change', () async {
      final since = await cursor();
      final (result, took) = await ask(since, wait: 1);
      expect(result['changes'], isEmpty);
      expect(result['reset'], isFalse);
      expect(result['cursor'], since);
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
      expect(took, lessThan(const Duration(seconds: 4)));
    });

    test('a note moved on disk during the wait is seen within about a '
        'second', () async {
      await call('POST', '/annotations', body: note('pp_a'));
      final since = await cursor();
      final pending = ask(since, wait: 20);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final ext in ['md', 'json']) {
        File(
          '${folder('open').path}/pp_a.$ext',
        ).renameSync('${folder('resolved').path}/pp_a.$ext');
      }
      final (result, took) = await pending;
      expect(found(result), ['pp_a']);
      expect(took, lessThan(const Duration(seconds: 3)));
    });

    test('a wait above 25 seconds is capped, and a bad one is none', () {
      expect(changesWait, const Duration(seconds: 25));
      expect(changesWaitOf('60'), changesWait);
      expect(changesWaitOf('25'), changesWait);
      expect(changesWaitOf('7'), const Duration(seconds: 7));
      expect(changesWaitOf('0'), Duration.zero);
      expect(changesWaitOf('-3'), Duration.zero);
      expect(changesWaitOf('soon'), Duration.zero);
      expect(changesWaitOf(null), Duration.zero);
    });

    test('no wait: the old answer, at once', () async {
      final since = await cursor();
      final (result, took) = await ask(since);
      expect(result['changes'], isEmpty);
      expect(took, lessThan(const Duration(seconds: 1)));
    });

    test('a tab does not get its own writes back; others and the agent '
        'do', () async {
      final since = await cursor();
      await call('POST', '/annotations?client=tab_a', body: note('pp_a'));
      await call(
        'PATCH',
        '/annotations/pp_a?client=tab_a',
        body: {'comment': 'Edited'},
      );
      expect(found((await ask(since, client: 'tab_a')).$1), isEmpty);
      expect(found((await ask(since, client: 'tab_b')).$1), ['pp_a']);
      expect(found((await ask(since)).$1), ['pp_a']);

      // The agent (no client id) changes it: every tab hears of it.
      await call('PATCH', '/annotations/pp_a', body: {'status': 'fixed'});
      expect(found((await ask(since, client: 'tab_a')).$1), ['pp_a']);
      expect(found((await ask(since, client: 'tab_b')).$1), ['pp_a']);

      // A delete by tab_a is left out for tab_a only.
      final next = await cursor();
      await call('DELETE', '/annotations/pp_a?client=tab_a');
      expect(found((await ask(next, client: 'tab_a')).$1), isEmpty);
      expect(found((await ask(next, client: 'tab_b')).$1), ['pp_a']);
    });

    test('a held request is not woken by its own tab\'s write', () async {
      final since = await cursor();
      final pending = ask(since, wait: 1, client: 'tab_a');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await call('POST', '/annotations?client=tab_a', body: note('pp_a'));
      final (result, took) = await pending;
      expect(result['changes'], isEmpty);
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
    });

    test('a held request ends when the bridge stops', () async {
      final since = await cursor();
      final pending = ask(since, wait: 20);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stopped = Stopwatch()..start();
      await bridge.close();
      await pending.then<void>((_) {}, onError: (Object _) {});
      expect(stopped.elapsed, lessThan(const Duration(seconds: 3)));
      bridge = await start();
    });
  });

  test('the bridge fills app.projectRoot when the app sent none', () async {
    await call('POST', '/annotations', body: note('pp_a'));
    await call(
      'POST',
      '/annotations',
      body: note('pp_b')
        ..['app'] = {
          'buildMode': 'debug',
          'platform': 'web',
          'projectRoot': '/x/app',
        },
    );
    Map<String, Object?> app(String id) => asMap(
      asMap(
        jsonDecode(File('${folder('open').path}/$id.json').readAsStringSync()),
      )['app'],
    );
    expect(app('pp_a')['projectRoot'], root.path);
    expect(app('pp_b')['projectRoot'], '/x/app', reason: 'the app wins');
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
