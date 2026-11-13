import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/run_store.dart';

/// PLAN-v2 Milestone 15, build steps 5 and 7: replay runs on the bridge.
/// A plain Dart loop stands in for the app (and for the page that a full
/// replay restarted).
void main() {
  late Directory root;
  late PinPointBridge bridge;
  var nextId = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_runs_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Future<(int, Object?)> send(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${bridge.port}$path'),
      );
      request.headers.set('origin', 'http://localhost:5000');
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

  Future<String> tool(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final (status, body) = await send(
      'POST',
      '/mcp',
      body: {
        'jsonrpc': '2.0',
        'id': ++nextId,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      },
    );
    expect(status, 200);
    final result = (body! as Map)['result']! as Map;
    return [
      for (final c in result['content']! as List<Object?>) (c! as Map)['text'],
    ].join('\n');
  }

  Future<Map<String, Object?>> appTakesOne(Map<String, Object?> answer) async {
    final (_, body) = await send('GET', '/commands?wait=5');
    final command = (body! as Map)['command']! as Map<String, Object?>;
    await send('POST', '/commands/${command['id']}/result', body: answer);
    return command;
  }

  test('replay of a full tape: the bridge waits for the restarted page to '
      'report the run', () async {
    await send('POST', '/commands/control', body: {'enabled': true});
    final answer = tool('replay', {'tape': 'tp_full_0000'});
    final command = await appTakesOne({
      'ok': true,
      'result': {'run': 'run_test_0001', 'state': 'restarting'},
    });
    expect(command['tool'], 'replay');
    // The new page, a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final (status, _) = await send(
      'POST',
      '/runs/run_test_0001/status',
      body: {
        'run': 'run_test_0001',
        'state': 'done',
        'step': 4,
        'of': 4,
        'first_difference': null,
      },
    );
    expect(status, 200);
    final text = await answer;
    expect(text, contains('"state":"done"'));
    expect(text, contains('run_test_0001'));
  });

  test('acceptance: the run of a replay is readable with get_trace({run}) '
      'from the bridge, whatever the page did since', () async {
    await send(
      'POST',
      '/runs/run_test_0002/events',
      body: {
        'events': [
          {'seq': 10, 't': 5, 'frame': 1, 'kind': 'replay.start'},
          {
            'seq': 11,
            't': 9,
            'frame': 2,
            'kind': 'input.pointer',
            'widget': 'ElevatedButton',
            'data': {'phase': 'down', 'by': 'agent'},
          },
          {
            'seq': 12,
            't': 30,
            'frame': 3,
            'kind': 'route',
            'data': {'from': '/', 'to': '/form'},
          },
        ],
      },
    );
    await send('POST', '/runs/run_test_0002/status', body: {'state': 'done'});
    final file = File('${root.path}/.pinpoint/runs/run_test_0002.jsonl');
    expect(file.readAsLinesSync(), hasLength(3));
    final text = await tool('get_trace', {'run': 'run_test_0002'});
    expect(text, contains('/form'));
    expect(text, contains('ElevatedButton'));
    final routes = await tool('get_trace', {
      'run': 'run_test_0002',
      'kinds': ['route'],
    });
    expect(routes, isNot(contains('ElevatedButton')));
    expect(
      await tool('get_trace', {'run': 'run_none_0000'}),
      contains('No run'),
    );
  });

  test('a crafted run id never becomes a path', () async {
    final (status, _) = await send(
      'POST',
      '/runs/..%2F..%2Fx/status',
      body: {'state': 'done'},
    );
    expect(status, anyOf(400, 404));
  });

  test('the newest 20 runs are kept', () async {
    final store = RunStore(Directory('${root.path}/.pinpoint'));
    for (var i = 0; i < 23; i++) {
      await store.setStatus('run_keep_${i.toString().padLeft(4, '0')}', {
        'state': 'done',
      });
      // File times have a coarse grain on some systems.
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    final runs = await store.list();
    expect(runs.length, 20);
    expect(await store.status('run_keep_0000'), isNull);
    expect(await store.status('run_keep_0022'), isNotNull);
  });
}
