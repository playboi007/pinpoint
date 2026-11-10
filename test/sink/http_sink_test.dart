import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 7, build step 3: the HTTP sink, against a fake client.
void main() {
  final note = Annotation(
    id: 'pp_20261110_143205_a1f3',
    createdAt: DateTime.utc(2026, 11, 10, 14, 32, 5),
    intent: AnnotationIntent.bug,
    comment: 'Too tight',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
    screenshot: ScreenshotInfo(
      file: 'pp_20261110_143205_a1f3.png',
      pixelRatio: 1,
      width: 1,
      height: 1,
      png: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]),
    ),
  );
  final url = Uri.parse('http://127.0.0.1:4747/annotations');

  test('posts the note as JSON with the screenshot as base64', () async {
    late http.Request seen;
    final sink = HttpSink(
      url,
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"id":"x"}', 201);
      }),
    );
    await sink.send(note);

    expect(seen.method, 'POST');
    expect(seen.url, url);
    expect(seen.headers['content-type'], startsWith('application/json'));
    final body = jsonDecode(seen.body) as Map<String, Object?>;
    expect(
      body,
      jsonDecode(jsonEncode(note.toJson(includeScreenshotData: true))),
    );
    expect(
      (body['screenshot']! as Map<String, Object?>)['data'],
      base64Encode(note.screenshot!.png!),
    );
  });

  test('any 2xx status is a success', () async {
    for (final status in [200, 201, 204]) {
      final sink = HttpSink(
        url,
        client: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(sink.send(note), completes, reason: '$status');
    }
  });

  test('throws on any other status, with the bridge\'s reason', () async {
    final sink = HttpSink(
      url,
      client: MockClient(
        (_) async => http.Response('{"error":"Unsupported schema 2"}', 400),
      ),
    );
    await expectLater(
      sink.send(note),
      throwsA(
        isA<HttpSinkException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having(
              (e) => e.message,
              'message',
              contains('Unsupported schema 2'),
            ),
      ),
    );
    for (final status in [301, 404, 413, 500]) {
      final failing = HttpSink(
        url,
        client: MockClient((_) async => http.Response('nope', status)),
      );
      await expectLater(
        failing.send(note),
        throwsA(isA<HttpSinkException>()),
        reason: '$status',
      );
    }
  });

  test('a refused connection says which address and how to start the '
      'bridge', () async {
    final sink = HttpSink(
      url,
      client: MockClient(
        (request) async =>
            throw http.ClientException('Connection refused', request.url),
      ),
    );
    await expectLater(
      sink.send(note),
      throwsA(
        isA<HttpSinkException>().having(
          (e) => e.toString(),
          'text',
          allOf(contains('127.0.0.1:4747'), contains('pinpoint:bridge')),
        ),
      ),
    );
  });

  test('gives up after its timeout, 5 seconds by default', () async {
    expect(HttpSink(url).timeout, const Duration(seconds: 5));
    final never = Completer<http.Response>();
    final sink = HttpSink(
      url,
      timeout: const Duration(milliseconds: 20),
      client: MockClient((_) => never.future),
    );
    await expectLater(
      sink.send(note),
      throwsA(
        isA<HttpSinkException>().having(
          (e) => e.message,
          'message',
          contains('no answer'),
        ),
      ),
    );
  });

  group('HttpSink.bridge', () {
    test('points at the local bridge on the configured port', () {
      final sink = HttpSink.bridge();
      expect(sink.url, Uri.parse('http://127.0.0.1:4747/annotations'));
      expect(sink.name, 'bridge');
      expect(
        HttpSink.bridge(port: 4848).url,
        Uri.parse('http://127.0.0.1:4848/annotations'),
      );
    });

    test('health is a sibling of the notes path', () {
      expect(
        HttpSink.bridge().healthUrl,
        Uri.parse('http://127.0.0.1:4747/health'),
      );
      expect(
        HttpSink(Uri.parse('http://h:1/pinpoint/annotations')).healthUrl,
        Uri.parse('http://h:1/pinpoint/health'),
      );
    });
  });

  group('isReachable', () {
    test('true only on 200 from the health path', () async {
      Uri? asked;
      final up = HttpSink(
        url,
        client: MockClient((request) async {
          asked = request.url;
          return http.Response('{"ok":true}', 200);
        }),
      );
      expect(await up.isReachable(), isTrue);
      expect(asked, Uri.parse('http://127.0.0.1:4747/health'));

      final broken = HttpSink(
        url,
        client: MockClient((_) async => http.Response('', 500)),
      );
      expect(await broken.isReachable(), isFalse);
    });

    test('false when refused or silent', () async {
      final refused = HttpSink(
        url,
        client: MockClient(
          (request) async => throw http.ClientException('refused', request.url),
        ),
      );
      expect(await refused.isReachable(), isFalse);

      final silent = HttpSink(
        url,
        client: MockClient((_) => Completer<http.Response>().future),
      );
      expect(
        await silent.isReachable(timeout: const Duration(milliseconds: 20)),
        isFalse,
      );
    });
  });
}
