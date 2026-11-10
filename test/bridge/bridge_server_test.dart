import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';

/// Milestone 7, build step 2: the bridge as a plain Dart program, tested
/// over real loopback sockets before any Flutter code calls it.
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  late List<String> log;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_bridge_');
    log = <String>[];
    bridge = await PinPointBridge.start(
      dir: '${root.path}/.pinpoint',
      port: 0,
      log: log.add,
    );
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${bridge.port}$path');
  Directory open() => Directory('${root.path}/.pinpoint/open');
  Directory resolved() => Directory('${root.path}/.pinpoint/resolved');
  List<String> names(Directory dir) => [
    for (final f in dir.listSync()) f.path.split(Platform.pathSeparator).last,
  ]..sort();

  /// A real POST, as a browser would send it after the preflight.
  Future<(int, String, HttpHeaders)> post(
    Object? body, {
    String path = annotationsPath,
    String? origin = 'http://localhost:5000',
    String contentType = 'application/json',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url(path));
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (origin != null) request.headers.set('origin', origin);
      request.add(body is List<int> ? body : utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text, response.headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> send(String method, String path) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, url(path));
      final response = await request.close();
      await response.drain<void>();
      return response;
    } finally {
      client.close(force: true);
    }
  }

  group('acceptance', () {
    test(
      'a preflight OPTIONS request gets 204 with the three headers',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final request = await client.openUrl('OPTIONS', url(annotationsPath));
        request.headers
          ..set('origin', 'http://localhost:5000')
          ..set('access-control-request-method', 'POST')
          ..set('access-control-request-headers', 'content-type');
        final response = await request.close();
        await response.drain<void>();

        expect(response.statusCode, 204);
        final headers = response.headers;
        expect(headers.value('access-control-allow-origin'), '*');
        expect(
          headers.value('access-control-allow-methods'),
          'POST, GET, OPTIONS',
        );
        expect(headers.value('access-control-allow-headers'), 'content-type');
      },
    );

    test('one note creates the .md, .json and .png, and the JSON holds no '
        'base64', () async {
      final note = sampleNote(png: tinyPng);
      final (status, body, _) = await post(note);

      expect(status, 201, reason: body);
      expect(jsonDecode(body), {
        'id': sampleId,
        'markdown': '${root.path}/.pinpoint/open/$sampleId.md',
      });
      expect(names(open()), [
        '$sampleId.json',
        '$sampleId.md',
        '$sampleId.png',
      ]);
      final stored = File('${open().path}/$sampleId.json').readAsStringSync();
      expect(stored, isNot(contains(base64Encode(tinyPng))));
      final json = jsonDecode(stored) as Map<String, Object?>;
      final shot = json['screenshot']! as Map<String, Object?>;
      expect(shot.containsKey('data'), isFalse);
      expect(shot['file'], '$sampleId.png');
      expect(File('${open().path}/$sampleId.png').readAsBytesSync(), tinyPng);
      expect(
        File('${open().path}/$sampleId.md').readAsStringSync(),
        markdownFromJson(json),
        reason: 'the .md is the formatter run on the stored JSON',
      );
    });

    test(
      'it listens on loopback only, so another machine is refused',
      () async {
        expect(bridge.address.isLoopback, isTrue);
        final lan = [
          for (final interface in await NetworkInterface.list())
            for (final address in interface.addresses)
              if (!address.isLoopback && !address.isLinkLocal) address,
        ];
        if (lan.isEmpty) {
          markTestSkipped('no network address to try from');
          return;
        }
        // A connection to this machine's network address is what a second
        // device would make. Nothing listens there.
        for (final address in lan) {
          await expectLater(
            Socket.connect(
              address,
              bridge.port,
              timeout: const Duration(seconds: 2),
            ),
            throwsA(isA<SocketException>()),
            reason: '$address',
          );
        }
      },
    );
  });

  group('responses', () {
    test('every response repeats Access-Control-Allow-Origin', () async {
      for (final (method, path, status) in [
        ('GET', healthPath, 200),
        ('GET', '/nothing', 404),
        ('DELETE', annotationsPath, 405),
      ]) {
        final response = await send(method, path);
        expect(response.statusCode, status, reason: '$method $path');
        expect(
          response.headers.value('access-control-allow-origin'),
          '*',
          reason: '$method $path',
        );
      }
      final (status, _, headers) = await post({'schema': 2});
      expect(status, 400);
      expect(headers.value('access-control-allow-origin'), '*');
    });

    test('GET /health returns 200', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(url(healthPath))).close();
      expect(response.statusCode, 200);
      expect(jsonDecode(await utf8.decodeStream(response)), {
        'ok': true,
        'schema': 1,
      });
    });

    test('prints one line per note with the path to its .md', () async {
      await post(sampleNote());
      final lines = [
        for (final line in log)
          if (line.contains(sampleId)) line,
      ];
      expect(lines, hasLength(1));
      expect(
        lines.single,
        contains('${root.path}/.pinpoint/open/$sampleId.md'),
      );
    });
  });

  group('watch out for', () {
    test('the id must match ^[a-z0-9_]+\$, so a crafted id never writes '
        'outside .pinpoint/', () async {
      for (final id in <Object?>[
        '../evil',
        '../../escape',
        'pp/x',
        r'pp\x',
        'PP_UPPER',
        'pp.x',
        '',
        'a' * 65,
        7,
        null,
      ]) {
        final (status, body, _) = await post(sampleNote(id: id));
        expect(status, 400, reason: '$id: $body');
      }
      expect(names(open()), isEmpty);
      expect(names(root), ['.pinpoint'], reason: 'nothing beside the folder');
      expect(names(Directory('${root.path}/.pinpoint')), [
        '.gitignore',
        'open',
        'resolved',
      ]);
    });

    test('a body over 10 MB gets 413', () async {
      final big = Uint8List(maxBodyBytes + 1);
      final (status, _, _) = await post(big);
      expect(status, 413);
      expect(names(open()), isEmpty);
    });

    test('a chunked body that grows past 10 MB gets 413', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(url(annotationsPath));
      request.headers.contentType = ContentType.json;
      request.headers.chunkedTransferEncoding = true;
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i <= maxBodyBytes ~/ chunk.length; i++) {
        request.add(chunk);
      }
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 413);
    });

    test('files are written under a temporary name, so none is left '
        'behind', () async {
      await post(sampleNote(png: tinyPng));
      await post(sampleNote(png: tinyPng));
      expect(names(open()).where((n) => n.startsWith('.')), isEmpty);
      expect(names(open()), hasLength(3));
    });

    test('the preflight allows a private network request', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.openUrl('OPTIONS', url(annotationsPath));
      request.headers
        ..set('origin', 'http://localhost:5000')
        ..set('access-control-request-method', 'POST')
        ..set('access-control-request-private-network', 'true');
      final response = await request.close();
      await response.drain<void>();
      expect(
        response.headers.value('access-control-allow-private-network'),
        'true',
      );
    });

    test('a port in use fails with a message that names the flag', () async {
      await expectLater(
        PinPointBridge.start(
          dir: '${root.path}/.pinpoint',
          port: bridge.port,
          log: log.add,
        ),
        throwsA(
          isA<BridgeStartException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('${bridge.port}'),
              contains('--port'),
              contains('PINPOINT_BRIDGE_PORT'),
            ),
          ),
        ),
      );
    });
  });

  group('rejects', () {
    test('any schema but 1', () async {
      final (status, body, _) = await post({...sampleNote(), 'schema': 2});
      expect(status, 400);
      expect(body, contains('schema'));
      expect(names(open()), isEmpty);
    });

    test('a body that is not a JSON object', () async {
      expect((await post(utf8.encode('{nope'))).$1, 400);
      expect((await post([1, 2])).$1, 400);
      expect((await post(const [0xff, 0xfe])).$1, 400);
      expect(names(open()), isEmpty);
    });

    test('a body that is not JSON by its content type', () async {
      final (status, _, _) = await post(
        sampleNote(),
        contentType: 'text/plain',
      );
      expect(status, 415);
      expect(names(open()), isEmpty);
    });

    test('a screenshot that is not base64 PNG', () async {
      for (final data in <Object>[
        'not base64!',
        base64Encode([1, 2, 3]),
        5,
      ]) {
        final note = sampleNote();
        (note['screenshot']! as Map<String, Object?>)['data'] = data;
        final (status, body, _) = await post(note);
        expect(status, 400, reason: '$data: $body');
      }
      expect(names(open()), isEmpty);
    });

    test('a note from a page that is not on this machine', () async {
      // Any web page the browser has open can POST to localhost. The notes
      // go to a coding agent, so only the app's own (local) pages may.
      for (final origin in [
        'https://evil.example',
        'http://192.168.1.20:5000',
        'null',
      ]) {
        final (status, body, _) = await post(sampleNote(), origin: origin);
        expect(status, 403, reason: origin);
        expect(body, contains('--allow-origin'));
      }
      expect(names(open()), isEmpty);
      expect(log.where((l) => l.contains('--allow-origin')), isNotEmpty);
    });

    test('a note that is already resolved', () async {
      File('${resolved().path}/$sampleId.md').writeAsStringSync('done');
      final (status, _, _) = await post(sampleNote());
      expect(status, 409);
      expect(names(open()), isEmpty);
    });
  });

  group('accepts', () {
    test('notes from local pages and from curl', () async {
      for (final origin in [
        'http://localhost:5000',
        'http://127.0.0.1:8080',
        'http://[::1]:3000',
        'https://app.localhost',
        null,
      ]) {
        final (status, body, _) = await post(sampleNote(), origin: origin);
        expect(status, 201, reason: '$origin: $body');
      }
    });

    test('an origin named with --allow-origin', () async {
      await bridge.close();
      bridge = await PinPointBridge.start(
        dir: '${root.path}/.pinpoint',
        port: 0,
        allowedOrigins: const ['http://192.168.1.20:5000'],
        log: log.add,
      );
      final (ok, _, _) = await post(
        sampleNote(),
        origin: 'http://192.168.1.20:5000',
      );
      expect(ok, 201);
      final (refused, _, _) = await post(
        sampleNote(),
        origin: 'http://192.168.1.21:5000',
      );
      expect(refused, 403);
    });

    test('the same note again, replacing its files', () async {
      await post(sampleNote(png: tinyPng));
      final (status, _, _) = await post({
        ...sampleNote(),
        'comment': 'Second try',
      });
      expect(status, 201);
      expect(names(open()), [
        '$sampleId.json',
        '$sampleId.md',
      ], reason: 'the old image does not belong to the new note');
      expect(
        File('${open().path}/$sampleId.md').readAsStringSync(),
        contains('Comment: Second try'),
      );
    });

    test('the fixture used by the curl check in PLAN.md', () async {
      final fixture = jsonDecode(
        File('test/fixtures/note.json').readAsStringSync(),
      );
      final (status, body, _) = await post(fixture);
      expect(status, 201, reason: body);
      expect(names(open()), hasLength(3));
    });
  });

  test('the folder ignores itself in git', () {
    expect(
      File('${root.path}/.pinpoint/.gitignore').readAsStringSync().trim(),
      '*',
    );
  });
}

const String sampleId = 'pp_20261110_143205_a1f3';

/// The smallest valid PNG: one transparent pixel.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4b23wHwAGEQ'
  'Jq+GwfDQAAAABJRU5ErkJggg==',
);

/// A schema 1 note as JSON, as the HTTP sink sends it.
Map<String, Object?> sampleNote({Object? id = sampleId, Uint8List? png}) => {
  'schema': 1,
  'id': id,
  'createdAt': '2026-11-10T14:32:05Z',
  'intent': 'improve',
  'comment': 'Label truncates at narrow widths',
  'app': {'buildMode': 'debug', 'platform': 'web', 'projectRoot': null},
  'page': {'route': '/orders/:id'},
  'target': {
    'widget': 'Text',
    'source': {'file': 'lib/widgets/save_bar.dart', 'line': 42, 'column': 18},
    'sourceUnavailable': false,
  },
  'ancestors': const <Object?>[],
  'frameworkChain': const <Object?>[],
  'siblings': null,
  'subtree': null,
  'inherited': null,
  'screenshot': {
    'file': 'whatever.png',
    'pixelRatio': 1,
    'width': 1,
    'height': 1,
    if (png != null) 'data': base64Encode(png),
  },
};
