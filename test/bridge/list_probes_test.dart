import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/probe_scan.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;

/// PLAN-v2 Milestone 13, step 7: `list_probes`, and `update_note` warns
/// while probe lines remain. Plain `test`: the widget binding fakes
/// `HttpClient`.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  var nextId = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_probes_');
    await File(
      '${root.path}/lib/screens/existing.dart',
    ).create(recursive: true);
    await File('${root.path}/lib/screens/existing.dart').writeAsString(
      [
        'void ensureLoaded(String type) {',
        "  PinPoint.probe('existing.ensureLoaded', {'type': type});",
        '}',
      ].join('\n'),
    );
    await File('${root.path}/lib/main.dart').writeAsString('void main() {}\n');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Future<Object?> send(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${bridge.port}$path'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('accept', 'application/json, text/event-stream');
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> tool(String name, Map<String, Object?> args) async {
    final answer =
        await send('POST', '/mcp', {
              'jsonrpc': '2.0',
              'id': ++nextId,
              'method': 'tools/call',
              'params': {'name': name, 'arguments': args},
            })
            as Map<String, Object?>;
    final result = answer['result']! as Map<String, Object?>;
    return [
      for (final c in result['content']! as List<Object?>)
        (c! as Map<String, Object?>)['text'],
    ].join('\n');
  }

  test('findProbes lists each PinPoint.probe line under lib/', () async {
    final probes = await findProbes(root);
    expect(probes.single.file, 'lib/screens/existing.dart');
    expect(probes.single.line, 2);
    expect(probes.single.text, startsWith('PinPoint.probe('));
  });

  test('list_probes names the file and line', () async {
    final text = await tool('list_probes', {});
    expect(text, contains('1 PinPoint.probe line in lib/'));
    expect(text, contains('lib/screens/existing.dart:2'));
  });

  test('update_note with status fixed warns while a probe remains, and not '
      'after it is gone', () async {
    await send('POST', '/annotations', _note('pp_a'));
    final warned = await tool('update_note', {'id': 'pp_a', 'status': 'fixed'});
    expect(warned, contains('Note pp_a is fixed'));
    expect(warned, contains('Warning: 1 PinPoint.probe line is still in lib/'));
    expect(warned, contains('lib/screens/existing.dart:2'));

    await File('${root.path}/lib/screens/existing.dart').writeAsString('\n');
    final clean = await tool('update_note', {
      'id': 'pp_a',
      'status': 'fixed',
      'message': 'Removed the probe',
    });
    expect(clean, isNot(contains('Warning')));
    // In progress: no warning, probes are expected then.
    await File(
      '${root.path}/lib/a.dart',
    ).writeAsString("PinPoint.probe('a');\n");
    final working = await tool('update_note', {
      'id': 'pp_a',
      'status': 'inProgress',
    });
    expect(working, isNot(contains('Warning')));
  });
}

Map<String, Object?> _note(String id) => {
  'schema': annotationSchema,
  'id': id,
  'createdAt': '2026-11-13T10:00:00Z',
  'status': 'submitted',
  'intent': 'bug',
  'comment': 'Loads twice',
  'app': {'buildMode': 'debug', 'platform': 'web', 'origin': null},
  'page': {'route': '/'},
  'target': {
    'widget': 'Text',
    'source': {'file': 'lib/main.dart', 'line': 1, 'column': 1},
    'sourceUnavailable': false,
    'rect': {'x': 0, 'y': 0, 'w': 10, 'h': 10},
  },
  'messages': const <Object?>[],
  'ancestors': const <Object?>[],
};
