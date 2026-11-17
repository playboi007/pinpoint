@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/tape/net_matcher.dart';
import 'package:pinpoint/src/trace/sources/network_source.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 15, build step 3, in Chrome:
/// `flutter test --platform chrome test/tape/web`.
///
/// Before the source is installed, `fetch` and `XMLHttpRequest.send` are
/// wrapped in counters: the "server". A served answer must never reach
/// them. The URLs are on `.invalid`, so a request that did leave the page
/// would fail.
void main() {
  late HookRegistry hooks;
  late TraceRecorder recorder;
  late NetworkSource source;
  late _Server server;

  const matcher = NetMatcher();
  const api = 'https://api.test.invalid';

  NetExchange exchange(
    int n,
    String path, {
    int status = 200,
    String type = 'application/json',
    String method = 'GET',
  }) => NetExchange(
    n: n,
    key: matcher.key(method, '$api$path', null),
    method: method,
    url: '$api$path',
    t: n,
    status: status,
    headers: {'content-type': type, 'set-cookie': '***'},
    ms: 5,
  );

  Tape tape(List<(NetExchange, String)> answers) => Tape(
    id: 'tp_web_0000',
    kind: TapeKind.full,
    start: const TapeStart(t: 0, seq: 1, wallTime: 'w'),
    net: [for (final (e, _) in answers) e],
    bodies: {
      for (final (e, body) in answers)
        e.n: Uint8List.fromList(utf8.encode(body)),
    },
  );

  setUp(() {
    server = _Server()..install();
    hooks = HookRegistry();
    recorder = TraceRecorder();
    source = NetworkSource(hooks: hooks)..start(recorder);
  });

  tearDown(() {
    source.stop();
    hooks.dispose();
    server.uninstall();
  });

  test('acceptance: with unmatched fail, a fetch is served from the tape and '
      'no request leaves the page', () async {
    final replay = NetReplay(
      tape([(exchange(0, '/items', status: 201), '{"items":[1]}')]),
    );
    source.replay = replay;
    final response = await BrowserClient().get(Uri.parse('$api/items'));
    expect(response.statusCode, 201);
    expect(response.body, '{"items":[1]}');
    expect(response.headers['content-type'], 'application/json');
    // A masked cookie is not set again.
    expect(response.headers.containsKey('set-cookie'), isFalse);
    expect(server.hits, isEmpty);
    expect(replay.wasDelivered(0), isTrue);
    // The replay's own run records the answer like any other.
    await _until(() => recorder.lastOf(TraceKind.netResponse) != null);
    expect(recorder.lastOf(TraceKind.netResponse)!.data['status'], 201);
  });

  test('acceptance: the nth fetch with a key gets the nth answer', () async {
    source.replay = NetReplay(
      tape([(exchange(0, '/n'), 'first'), (exchange(1, '/n'), 'second')]),
    );
    final client = BrowserClient();
    expect((await client.get(Uri.parse('$api/n'))).body, 'first');
    expect((await client.get(Uri.parse('$api/n'))).body, 'second');
    expect(server.hits, isEmpty);
  });

  test('a fetch with no answer fails like a network error and records '
      'replay.unmatched', () async {
    source.replay = NetReplay(tape([]));
    await expectLater(
      BrowserClient().get(Uri.parse('$api/missing')),
      throwsA(isA<http.ClientException>()),
    );
    expect(server.hits, isEmpty);
    expect(recorder.lastOf(TraceKind.replayUnmatched), isNotNull);
    await _until(() => recorder.lastOf(TraceKind.netError) != null);
  });

  test('unmatched passthrough sends the request to the server', () async {
    source.replay = NetReplay(tape([]), unmatched: Unmatched.passthrough);
    final url = _blobUrl(utf8.encode('live'), 'text/plain');
    expect((await BrowserClient().get(Uri.parse(url))).body, 'live');
    expect(server.hits, [url]);
  });

  test('acceptance: an XHR is served with the tape\'s status, headers and '
      'body, and no request leaves the page', () async {
    final replay = NetReplay(
      tape([(exchange(0, '/x', status: 404, type: 'text/plain'), 'not here')]),
    );
    source.replay = replay;
    final xhr = await _xhr('GET', '$api/x');
    expect(_s(xhr['status']), '404');
    expect(_s(xhr['responseText']), 'not here');
    expect(_s(xhr['responseURL']), '$api/x');
    expect(
      _s(xhr.callMethod<JSAny?>('getResponseHeader'.toJS, 'Content-Type'.toJS)),
      'text/plain',
    );
    expect(server.realSends, isEmpty);
    // Our loadend listener is added at send, after the app's.
    await _until(() => replay.wasDelivered(0));
    await _until(() => recorder.lastOf(TraceKind.netResponse) != null);
    expect(recorder.lastOf(TraceKind.netResponse)!.data['status'], 404);
  });

  test('an XHR with no answer fails with a network error', () async {
    source.replay = NetReplay(tape([]));
    final failed = Completer<String>();
    final xhr = (globalContext['XMLHttpRequest']! as JSFunction)
        .callAsConstructor<JSObject>();
    xhr.callMethod<JSAny?>('open'.toJS, 'GET'.toJS, '$api/none'.toJS);
    for (final type in ['error', 'load']) {
      xhr.callMethod<JSAny?>(
        'addEventListener'.toJS,
        type.toJS,
        ((JSAny? _) {
          if (!failed.isCompleted) failed.complete(type);
        }).toJS,
      );
    }
    xhr.callMethod<JSAny?>('send'.toJS);
    expect(await failed.future, 'error');
    expect(server.realSends, isEmpty);
  });

  test('acceptance (network part): ending the replay gives the network '
      'back', () async {
    source.replay = NetReplay(tape([]));
    source.replay = null;
    final url = _blobUrl(utf8.encode('back'), 'text/plain');
    expect((await BrowserClient().get(Uri.parse(url))).body, 'back');
    expect(server.hits, [url]);
  });
}

/// Counters in front of the browser's `fetch` and `XMLHttpRequest.send`,
/// installed before the source, so the source's "original" is the
/// counter.
class _Server {
  final List<String> hits = <String>[];

  /// Sends of XHRs opened on a URL that is not a blob or Pinpoint's
  /// failure scheme.
  final List<String> realSends = <String>[];

  JSAny? _fetch;
  JSAny? _open;
  JSAny? _send;

  JSObject get _proto =>
      (globalContext['XMLHttpRequest']! as JSObject)['prototype']! as JSObject;

  void install() {
    _fetch = globalContext['fetch'];
    final fetch = _fetch! as JSFunction;
    globalContext['fetch'] = ((JSAny? input, [JSAny? init]) {
      hits.add(_s(input));
      return fetch.callAsFunction(globalContext, input, init);
    }).toJS;
    _open = _proto['open'];
    _send = _proto['send'];
    final open = _open! as JSFunction;
    final send = _send! as JSFunction;
    _proto['open'] = ((JSObject self, JSAny? method, JSAny? url, [JSAny? a]) {
      self['__pinpointTestUrl'] = url;
      return a == null
          ? open.callAsFunction(self, method, url)
          : open.callAsFunction(self, method, url, a);
    }).toJSCaptureThis;
    _proto['send'] = ((JSObject self, [JSAny? body]) {
      final url = _s(self['__pinpointTestUrl']);
      if (!url.startsWith('blob:') && !url.startsWith('pinpoint-replay:')) {
        realSends.add(url);
      }
      return send.callAsFunction(self, body);
    }).toJSCaptureThis;
  }

  void uninstall() {
    globalContext['fetch'] = _fetch;
    _proto['open'] = _open;
    _proto['send'] = _send;
  }
}

String _s(JSAny? value) =>
    value == null ? '' : '${value.dartify()}'.replaceAll('.0', '');

String _blobUrl(List<int> bytes, String type) {
  final blob = (globalContext['Blob']! as JSFunction)
      .callAsConstructor<JSObject>(
        [Uint8List.fromList(bytes).toJS].toJS,
        {'type': type}.jsify(),
      );
  return (globalContext['URL']! as JSObject)
      .callMethod<JSString>('createObjectURL'.toJS, blob)
      .toDart;
}

Future<JSObject> _xhr(String method, String url) {
  final done = Completer<JSObject>();
  final xhr = (globalContext['XMLHttpRequest']! as JSFunction)
      .callAsConstructor<JSObject>();
  xhr.callMethod<JSAny?>('open'.toJS, method.toJS, url.toJS);
  xhr.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'loadend'.toJS,
    ((JSAny? _) => done.complete(xhr)).toJS,
  );
  xhr.callMethod<JSAny?>('send'.toJS);
  return done.future;
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'timed out');
}
