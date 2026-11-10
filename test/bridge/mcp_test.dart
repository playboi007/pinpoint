import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/mcp_server.dart';
import 'package:pinpoint/src/bridge/png_resize.dart';

/// Milestone 8, build step 4: the MCP tools, tested with a scripted JSON-RPC
/// client over HTTP before any real agent connects (PLAN.md, how to
/// verify).
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  var nextId = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_mcp_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Directory folder(String name) => Directory('${root.path}/.pinpoint/$name');
  List<String> names(String name) =>
      [for (final f in folder(name).listSync()) f.uri.pathSegments.last]
        ..sort();

  /// One HTTP request to `/mcp`, as an MCP client sends it.
  Future<(int, Object?)> raw(
    String method, {
    Object? body,
    String? text,
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${bridge.port}/mcp'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('accept', 'application/json, text/event-stream')
        ..set('mcp-protocol-version', '2025-06-18');
      if (origin != null) request.headers.set('origin', origin);
      if (text != null) request.write(text);
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final answer = await utf8.decodeStream(response);
      return (response.statusCode, answer.isEmpty ? null : jsonDecode(answer));
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> rpc(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final id = ++nextId;
    final (status, body) = await raw(
      'POST',
      body: {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params},
    );
    expect(status, 200, reason: '$body');
    final answer = body! as Map<String, Object?>;
    expect(answer['id'], id);
    return answer;
  }

  Future<Map<String, Object?>> tool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final answer = await rpc('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    expect(answer['error'], isNull, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  List<Map<String, Object?>> contentOf(Map<String, Object?> result) => [
    for (final c in result['content']! as List<Object?>)
      c! as Map<String, Object?>,
  ];

  String textOf(Map<String, Object?> result) => [
    for (final c in contentOf(result))
      if (c['type'] == 'text') c['text'],
  ].join('\n');

  List<Map<String, Object?>> imagesOf(Map<String, Object?> result) => [
    for (final c in contentOf(result))
      if (c['type'] == 'image') c,
  ];

  Future<void> post(Map<String, Object?> note) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}/annotations'),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(note));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 201);
    } finally {
      client.close(force: true);
    }
  }

  test('a scripted session: initialize, list tools, call each tool', () async {
    final wide = encodePng(
      RawImage(1600, 400, 4, Uint8List(1600 * 400 * 4)..fillRange(0, 4, 255)),
    );
    await post(note('pp_sent', png: wide));
    await post(note('pp_draft', status: 'draft'));

    final init = await rpc('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'test', 'version': '1'},
    });
    final result = init['result']! as Map<String, Object?>;
    expect(result['protocolVersion'], '2025-06-18');
    expect((result['serverInfo']! as Map)['name'], 'pinpoint');
    expect((result['capabilities']! as Map)['tools'], isNotNull);

    // The notification after initialize: no answer owed.
    final (status, body) = await raw(
      'POST',
      body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    );
    expect(status, 202);
    expect(body, isNull);

    final tools = (await rpc('tools/list'))['result']! as Map<String, Object?>;
    expect(
      [for (final t in tools['tools']! as List<Object?>) (t! as Map)['name']],
      ['list_notes', 'get_note', 'update_note'],
    );

    // Acceptance: draft notes never appear in list_notes.
    for (final status in ['open', 'all', 'submitted']) {
      final listed = textOf(await tool('list_notes', {'status': status}));
      expect(listed, contains('pp_sent'), reason: status);
      expect(listed, isNot(contains('pp_draft')), reason: status);
    }
    final drafts = await tool('list_notes', {'status': 'draft'});
    expect(drafts['isError'], isTrue);
    final hidden = await tool('get_note', {'id': 'pp_draft'});
    expect(hidden['isError'], isTrue);
    expect(textOf(hidden), isNot(contains('Fix it')));
    final untouched = await tool('update_note', {
      'id': 'pp_draft',
      'status': 'resolved',
    });
    expect(untouched['isError'], isTrue);
    expect(names('drafts'), ['pp_draft.json']);

    // get_note: compact has no image; standard has one, at most 800 wide.
    final compact = await tool('get_note', {
      'id': 'pp_sent',
      'detail': 'compact',
    });
    expect(imagesOf(compact), isEmpty);
    expect(textOf(compact).length, lessThan(600));
    final standard = await tool('get_note', {'id': 'pp_sent'});
    final image = imagesOf(standard).single;
    expect(image['mimeType'], 'image/png');
    final decoded = decodePng(base64Decode(image['data']! as String))!;
    expect(decoded.width, mcpMaxImageWidth);
    expect(decoded.height, 200);
    expect(textOf(standard), contains('Source: lib/main.dart:12:5'));

    // update_note: the files move, the .md says so, the app's feed too.
    final since = await cursor(bridge);
    final updated = await tool('update_note', {
      'id': 'pp_sent',
      'status': 'resolved',
      'message': 'Gave the label room.',
    });
    expect(updated['isError'], isFalse);
    expect(textOf(updated), contains('Note pp_sent is resolved.'));
    expect(names('open'), isEmpty);
    expect(names('resolved'), ['pp_sent.json', 'pp_sent.md', 'pp_sent.png']);
    final md = File('${folder('resolved').path}/pp_sent.md').readAsStringSync();
    expect(md, contains('Status: resolved'));
    expect(md, contains('- agent ('));
    expect(md, contains('Gave the label room.'));
    final changes = await bridge.store.changes(since);
    expect(changes.changes.single['status'], 'resolved');
    expect(textOf(await tool('list_notes', {})), 'No open notes.');
  });

  test('protocol errors', () async {
    final unknown = await rpc('resources/list');
    expect((unknown['error']! as Map)['code'], -32601);

    final badTool = await rpc('tools/call', {'name': 'rm_rf', 'arguments': {}});
    expect((badTool['error']! as Map)['code'], -32602);

    final noId = await rpc('tools/call', {'name': 'get_note', 'arguments': {}});
    expect((noId['error']! as Map)['code'], -32602);

    final (parseStatus, parse) = await raw('POST', text: '{nope');
    expect(parseStatus, 400);
    expect(((parse! as Map)['error']! as Map)['code'], -32700);

    final (getStatus, _) = await raw('GET');
    expect(getStatus, 405, reason: 'no server-sent event stream');
  });

  test('an older protocol version is answered in kind; an unknown one gets '
      'the newest', () async {
    var answer = await rpc('initialize', {'protocolVersion': '2024-11-05'});
    expect((answer['result']! as Map)['protocolVersion'], '2024-11-05');
    answer = await rpc('initialize', {'protocolVersion': '1999-01-01'});
    expect((answer['result']! as Map)['protocolVersion'], '2025-06-18');
  });

  test('a batch gets one answer per request', () async {
    final (status, body) = await raw(
      'POST',
      body: [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      ],
    );
    expect(status, 200);
    expect([for (final a in body! as List<Object?>) (a! as Map)['id']], [1, 2]);
  });

  test('a page from another machine may not call the tools', () async {
    final (status, _) = await raw(
      'POST',
      body: {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      origin: 'https://evil.example',
    );
    expect(status, 403);
  });
}

Future<String> cursor(PinPointBridge bridge) async =>
    (await bridge.store.changes(null)).cursor;

Map<String, Object?> note(
  String id, {
  String status = 'submitted',
  Uint8List? png,
}) => {
  'schema': 2,
  'id': id,
  'createdAt': '2026-11-10T14:00:00Z',
  'status': status,
  'intent': 'bug',
  'comment': 'Fix it',
  'app': {'buildMode': 'debug', 'platform': 'web', 'origin': null},
  'page': {'route': '/'},
  'target': {
    'widget': 'Text',
    'source': {'file': 'lib/main.dart', 'line': 12, 'column': 5},
    'sourceUnavailable': false,
    'rect': {'x': 10, 'y': 20, 'w': 100, 'h': 30},
  },
  'messages': const <Object?>[],
  'ancestors': const <Object?>[],
  'frameworkChain': const <Object?>[],
  if (png != null)
    'screenshot': {
      'file': '$id.png',
      'pixelRatio': 1,
      'width': 1600,
      'height': 400,
      'data': base64Encode(png),
    },
};
