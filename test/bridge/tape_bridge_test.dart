import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/tape.dart';

/// PLAN-v2 Milestone 15, build step 2: tapes on the bridge. Plain `test`
/// over real loopback sockets (the widget binding fakes `HttpClient`).
void main() {
  late Directory root;
  late PinPointBridge bridge;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_tapes_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Future<(int, Object?)> http(
    String method,
    String path, {
    Object? body,
    String origin = 'http://localhost:5000',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${bridge.port}$path'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('origin', origin);
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  var rpc = 0;
  Future<String> tool(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final (status, answer) = await http(
      'POST',
      '/mcp',
      body: {
        'jsonrpc': '2.0',
        'id': ++rpc,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      },
    );
    expect(status, 200);
    final result =
        (answer! as Map<String, Object?>)['result']! as Map<String, Object?>;
    final content = result['content']! as List<Object?>;
    return [
      for (final c in content) (c! as Map<String, Object?>)['text'],
    ].join('\n');
  }

  Tape tape({String id = 'tp_20261113_100000_ab12'}) => Tape(
    id: id,
    kind: TapeKind.full,
    start: const TapeStart(t: 0, seq: 1, wallTime: '2026-11-13T10:00:00Z'),
    inputs: const [
      TapeInput(
        step: 1,
        seq: 4,
        t: 100,
        frame: 2,
        kind: 'input.pointer',
        widget: 'ElevatedButton',
        data: {'phase': 'down'},
        after: [0],
      ),
    ],
    net: const [
      NetExchange(
        n: 0,
        key: 'GET https://api.test/me -',
        method: 'GET',
        url: 'https://api.test/me?token=***',
        t: 1,
        status: 200,
        headers: {'set-cookie': '***'},
        ms: 30,
        answeredSeq: 3,
      ),
    ],
    marks: const [TapeMark(seq: 5, t: 120, text: 'here')],
    bodies: {0: Uint8List.fromList(utf8.encode('{"name":"Ada Secret"}'))},
  );

  test(
    'POST /tapes stores the tape and its bodies; GET gives them back',
    () async {
      final t = tape();
      final (status, summary) = await http(
        'POST',
        '/tapes',
        body: {'tape': t.toJson(), 'bodies': t.bodiesToJson()},
      );
      expect(status, 200, reason: '$summary');
      expect((summary! as Map)['kind'], 'full');
      final folder = '${root.path}/.pinpoint/tapes';
      expect(File('$folder/${t.id}.json').existsSync(), isTrue);
      expect(
        File('$folder/${t.id}/bodies/0.bin').readAsStringSync(),
        '{"name":"Ada Secret"}',
      );
      // The tape JSON on disk holds no body.
      expect(
        File('$folder/${t.id}.json').readAsStringSync(),
        isNot(contains('Ada Secret')),
      );

      final (got, json) = await http('GET', '/tapes/${t.id}');
      expect(got, 200);
      final again = Tape.fromJson(
        (json! as Map)['tape'],
        bodies: (json as Map)['bodies'],
      )!;
      expect(utf8.decode(again.bodies[0]!), '{"name":"Ada Secret"}');
      expect((await http('GET', '/tapes/tp_nothere_0000')).$1, 404);
    },
  );

  test('a crafted id never reaches outside the folder', () async {
    final t = tape(id: '../../evil');
    final (status, _) = await http(
      'POST',
      '/tapes',
      body: {'tape': t.toJson(), 'bodies': t.bodiesToJson()},
    );
    expect(status, 400);
    expect(File('${root.path}/evil.json').existsSync(), isFalse);
  });

  test(
    'watch out for: a tape is personal data; another origin is refused',
    () async {
      final t = tape();
      final (status, _) = await http(
        'POST',
        '/tapes',
        body: {'tape': t.toJson(), 'bodies': t.bodiesToJson()},
        origin: 'https://evil.example',
      );
      expect(status, 403);
      expect(
        (await http(
          'GET',
          '/tapes/${t.id}',
          origin: 'https://evil.example',
        )).$1,
        403,
      );
    },
  );

  test('acceptance: no masked header and no body appears in list_tapes or '
      'get_tape', () async {
    final t = tape();
    await http(
      'POST',
      '/tapes',
      body: {'tape': t.toJson(), 'bodies': t.bodiesToJson()},
    );
    final list = await tool('list_tapes');
    expect(list, contains(t.id));
    expect(list, contains('"bytes":21'));
    final one = await tool('get_tape', {'id': t.id});
    expect(one, contains('ElevatedButton'));
    expect(one, contains('here'));
    for (final text in [list, one]) {
      expect(text, isNot(contains('Ada Secret')));
      expect(text, isNot(contains(base64Encode(utf8.encode('{"name"')))));
    }
    expect(await tool('get_tape', {'id': 'tp_none_0000'}), contains('No tape'));
  });

  test('no tapes yet says how to get one', () async {
    expect(await tool('list_tapes'), contains('save_tape'));
  });
}
