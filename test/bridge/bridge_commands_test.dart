import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/agent_tools.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;

/// Milestone 12, build step 1: the command channel over real loopback
/// sockets. A plain Dart loop stands in for the app's long poll, and a
/// scripted JSON-RPC client stands in for the agent.
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  var nextId = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_commands_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${bridge.port}$path');

  Future<(int, Object?)> send(
    String method,
    String path, {
    Object? body,
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, url(path));
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

  Future<Map<String, Object?>> tool(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final (status, body) = await send(
      'POST',
      '/mcp',
      body: {
        'jsonrpc': '2.0',
        'id': ++nextId,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      },
    );
    expect(status, 200);
    final answer = body! as Map<String, Object?>;
    expect(answer['error'], isNull, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  String textOf(Map<String, Object?> result) => [
    for (final c in result['content']! as List<Object?>)
      if (c case {'type': 'text', 'text': final String text}) text,
  ].join('\n');

  /// The app's side: polls once, answers with [answer].
  Future<Map<String, Object?>> appTakesOne(
    Map<String, Object?> Function(Map<String, Object?> command) answer,
  ) async {
    final (status, body) = await send('GET', '/commands?wait=5');
    expect(status, 200);
    final command = (body! as Map<String, Object?>)['command']!;
    final cmd = command as Map<String, Object?>;
    final (posted, _) = await send(
      'POST',
      '/commands/${cmd['id']}/result',
      body: answer(cmd),
      origin: 'http://localhost:5000',
    );
    expect(posted, 200);
    return cmd;
  }

  test('the agent tool list has the Milestone 12 tools', () async {
    final (_, body) = await send(
      'POST',
      '/mcp',
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
    );
    final tools = ((body! as Map)['result']! as Map)['tools']! as List<Object?>;
    final names = [for (final t in tools) (t! as Map)['name']];
    expect(names, containsAll(<String>[...agentToolNames]));
    expect(agentToolNames, containsAll(<String>['get_screen', 'tap']));
  });

  test('get_screen end to end: queued by the tool, taken by the long poll, '
      'answered by the app', () async {
    // The app polls first, as it does when control is on.
    final app = appTakesOne(
      (command) => {
        'ok': true,
        'result': {
          'route': '/',
          'viewport': {'width': 800, 'height': 600},
          'echo': command['args'],
        },
      },
    );
    // Let the poll arrive before the tool call.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final result = await tool('get_screen', {'limit': 5});
    final command = await app;
    expect(command['tool'], 'get_screen');
    expect(result['isError'], isFalse);
    final text = textOf(result);
    expect(jsonDecode(text), {
      'route': '/',
      'viewport': {'width': 800, 'height': 600},
      'echo': {'limit': 5},
    });
  });

  test('with control off, every driving tool says so and nothing is '
      'queued', () async {
    for (final name in agentToolNames) {
      final result = await tool(name, {'handle': 'h1', 'id': 'pp_x'});
      expect(result['isError'], isTrue, reason: name);
      expect(
        textOf(result),
        anyOf(
          startsWith('agent control is disabled'),
          // verify_note looks up its note first.
          startsWith('No note pp_x'),
        ),
        reason: name,
      );
    }
    expect(bridge.commands.pendingCount, 0);
  });

  test('the app turning control off ends a waiting tool call', () async {
    final poll = send('GET', '/commands?wait=5');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The poll takes the tap, but the user turns control off before the
    // app answers.
    final call = tool('tap', {'handle': 'h1'});
    final (_, taken) = await poll;
    expect(((taken! as Map)['command']! as Map)['tool'], 'tap');
    final (status, _) = await send(
      'POST',
      '/commands/control',
      body: {'enabled': false},
    );
    expect(status, 200);
    final result = await call;
    expect(result['isError'], isTrue);
    expect(textOf(result), startsWith('agent control is disabled'));
  });

  test('a poll from a page on another machine is refused', () async {
    final (status, body) = await send(
      'GET',
      '/commands?wait=0',
      origin: 'http://evil.example',
    );
    expect(status, 403);
    expect((body! as Map)['error'], contains('refused'));
    expect(bridge.commands.connected, isFalse);
  });

  test('an empty poll answers null after its wait', () async {
    final (status, body) = await send('GET', '/commands?wait=0');
    expect(status, 200);
    expect((body! as Map)['command'], isNull);
  });

  test('a result for an unknown command is 404', () async {
    final (status, _) = await send(
      'POST',
      '/commands/c99/result',
      body: {'ok': true},
    );
    expect(status, 404);
  });

  test('the image of an answer comes back as MCP image content', () async {
    final app = appTakesOne(
      (command) => {
        'ok': true,
        'result': {
          'width': 1,
          'height': 1,
          // A 1 x 1 PNG.
          'png':
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
              'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        },
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final result = await tool('screenshot');
    await app;
    final content = result['content']! as List<Object?>;
    expect([for (final c in content) (c! as Map)['type']], ['text', 'image']);
    expect(textOf(result), isNot(contains('iVBOR')));
  });

  test('inspect comes back as note text at the asked detail', () async {
    final note = {
      'id': 'pp_inspect',
      'comment': '',
      'target': {
        'widget': 'ElevatedButton',
        'description': 'ElevatedButton',
        'source': {'file': 'lib/home.dart', 'line': 12, 'column': 5},
        'rect': {'x': 10, 'y': 20, 'w': 100, 'h': 40},
        'constraints': 'BoxConstraints(0.0<=w<=800.0, 0.0<=h<=600.0)',
        'properties': {'onPressed': 'Closure'},
      },
      'ancestors': [
        {
          'widget': 'Column',
          'source': {'file': 'lib/home.dart', 'line': 10, 'column': 3},
        },
      ],
      'subtree': 'ElevatedButton\n  Text "Save"',
    };
    for (final (detail, has, hasNot) in [
      ('compact', 'Source: lib/home.dart:12:5', 'Enclosing:'),
      ('standard', 'Enclosing: Column (lib/home.dart:10:3)', 'Subtree:'),
      ('full', 'Subtree:', 'Comment:'),
    ]) {
      final app = appTakesOne(
        (command) => {
          'ok': true,
          'result': {'handle': 'h1', 'detail': detail, 'note': note},
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = await tool('inspect', {'handle': 'h1', 'detail': detail});
      await app;
      final text = textOf(result);
      expect(text, startsWith('h1: ElevatedButton'), reason: detail);
      expect(text, contains(has), reason: detail);
      expect(text, isNot(contains(hasNot)), reason: detail);
    }
  });

  test('verify_note sends the note to the app, stores the result and the '
      'after screenshot, and keeps the status', () async {
    final (posted, _) = await send(
      'POST',
      '/annotations',
      body: {
        'schema': annotationSchema,
        'id': 'pp_v',
        'status': 'fixed',
        'createdAt': '2026-11-11T10:00:00.000Z',
        'intent': 'bug',
        'comment': 'The row overflows at 360',
        'page': {'route': '/zoo'},
        'anchor': {'file': 'lib/zoo.dart', 'line': 20, 'widget': 'Row'},
        'environment': {
          'viewport': {'width': 360, 'height': 800},
        },
        'checks': [
          {'type': 'no_overflow'},
        ],
      },
    );
    expect(posted, 201);

    late Map<String, Object?> sent;
    final app = appTakesOne((command) {
      sent = command['args']! as Map<String, Object?>;
      return {
        'ok': true,
        'result': {
          'id': 'pp_v',
          'passed': false,
          'found': 'lib/zoo.dart:22',
          'checks': [
            {
              'type': 'no_overflow',
              'passed': false,
              'message': 'Row overflows by 72 px on the right',
            },
          ],
          'png': _onePixelPng,
        },
      };
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final result = await tool('verify_note', {'id': 'pp_v'});
    await app;

    final note = sent['note']! as Map<String, Object?>;
    expect(note['anchor'], {
      'file': 'lib/zoo.dart',
      'line': 20,
      'widget': 'Row',
    });
    expect(note['checks'], [
      {'type': 'no_overflow'},
    ]);
    expect(note['environment'], isNotNull);
    expect((note['page']! as Map)['route'], '/zoo');

    expect(result['isError'], isFalse);
    final text = textOf(result);
    expect(text, contains('Checks failed (0 of 1 passed)'));
    expect(text, contains('FAIL no_overflow: Row overflows by 72 px'));
    final content = result['content']! as List<Object?>;
    expect([for (final c in content) (c! as Map)['type']], ['text', 'image']);

    final stored = await bridge.store.read('pp_v');
    expect(stored!['status'], 'fixed', reason: 'the user accepts, not this');
    final verification = stored['verification']! as Map<String, Object?>;
    expect(verification['passed'], isFalse);
    expect(verification['after'], 'pp_v.after.png');
    expect(verification['checks'], hasLength(1));
    expect(
      (stored['messages']! as List<Object?>).cast<Map<String, Object?>>().last,
      containsPair('from', 'pinpoint'),
    );
    final open = Directory('${root.path}/.pinpoint/open');
    expect(File('${open.path}/pp_v.after.png').existsSync(), isTrue);
    final md = File('${open.path}/pp_v.md').readAsStringSync();
    expect(md, contains('Verification: failed (0 of 1 checks passed'));

    // The after image moves with the note.
    await tool('update_note', {'id': 'pp_v', 'status': 'resolved'});
    final resolved = Directory('${root.path}/.pinpoint/resolved');
    expect(File('${resolved.path}/pp_v.after.png').existsSync(), isTrue);
    expect(File('${open.path}/pp_v.after.png').existsSync(), isFalse);
  });

  test(
    'verify_note of a draft or an unknown note never reaches the app',
    () async {
      final result = await tool('verify_note', {'id': 'pp_nope'});
      expect(result['isError'], isTrue);
      expect(textOf(result), startsWith('No note pp_nope'));
    },
  );

  test(
    'stress_matrix thumbnails are written as files, not sent as images',
    () async {
      final app = appTakesOne(
        (command) => {
          'ok': true,
          'result': {
            'runs': [
              {
                'run': 1,
                'label': 'width 320',
                'findings': 1,
                'png': _onePixelPng,
              },
              {
                'run': 2,
                'label': 'width 768',
                'findings': 0,
                'png': _onePixelPng,
              },
            ],
            'findings': [
              {
                'kind': 'overflow',
                'summary': 'Row overflows by 92 px on the right',
                'runs': [1],
              },
            ],
            'drafts': ['pp_draft'],
          },
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = await tool('stress_matrix');
      await app;
      final content = result['content']! as List<Object?>;
      expect([for (final c in content) (c! as Map)['type']], ['text']);
      final text = textOf(result);
      expect(text, isNot(contains('iVBOR')));
      final json = jsonDecode(text) as Map<String, Object?>;
      final runs = (json['runs']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(runs.first['thumbnail'], '.pinpoint/stress/run_1.png');
      final stress = Directory('${root.path}/.pinpoint/stress');
      expect(
        [for (final f in stress.listSync()) f.uri.pathSegments.last]..sort(),
        ['run_1.png', 'run_2.png'],
      );
    },
  );
}

/// A 1 x 1 PNG.
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
