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
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/sources/network_source.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 3, in Chrome:
/// `flutter test --platform chrome test/trace/web`.
///
/// Blob URLs stand in for the local test server the plan names: same
/// origin, real `fetch` and XHR, real headers and a real body stream.
void main() {
  late HookRegistry hooks;
  late TraceRecorder recorder;
  late NetworkSource source;

  setUp(() {
    hooks = HookRegistry();
    recorder = TraceRecorder();
    source = NetworkSource(hooks: hooks)..start(recorder);
    CauseZone().run(() {});
  });

  tearDown(() {
    source.stop();
    hooks.dispose();
    CauseZone.debugReset();
  });

  List<TraceEvent> net() => [
    for (final e in recorder.events)
      if (e.kind.startsWith('net.')) e,
  ];

  test('acceptance: a fetch from package:http gives net.request and '
      'net.response with the cause of the call', () async {
    final body = utf8.encode('{"items":[1,2,3]}');
    final url = _blobUrl(body, 'application/json');
    TraceCause? cause;
    final response = await CauseZone.enter(CauseKind.pointer, () {
      cause = CauseZone.currentCause;
      return BrowserClient().get(Uri.parse(url));
    });
    expect(response.body, '{"items":[1,2,3]}');
    await _until(() => net().length == 2 && net()[1].data['hash'] != null);
    final [request, answer] = net();
    expect(request.kind, TraceKind.netRequest);
    expect(request.data['via'], 'fetch');
    expect(request.data['method'], 'GET');
    expect(request.cause, cause!.id);
    expect(answer.kind, TraceKind.netResponse);
    expect(answer.cause, cause!.id);
    expect(answer.data['status'], 200);
    expect(answer.data['req'], request.seq);
    expect(answer.data['hash'], NetHash.of(body));
    expect(answer.data['size'], body.length);
  });

  test('acceptance: an XHR gives net.request and net.response with the '
      'cause of the call', () async {
    final url = _blobUrl(utf8.encode('plain text'), 'text/plain');
    TraceCause? cause;
    final xhr = await CauseZone.enter(CauseKind.pointer, () {
      cause = CauseZone.currentCause;
      return _xhr('GET', url, headers: {'x-test': '1'});
    });
    expect(_s(xhr['responseText']), 'plain text');
    await _until(() => net().length == 2);
    final [request, answer] = net();
    expect(request.data['via'], 'xhr');
    expect(request.cause, cause!.id);
    expect((request.data['headers']! as Map)['x-test'], '1');
    expect(answer.cause, cause!.id);
    expect(answer.data['status'], 200);
    expect(answer.data['hash'], NetHash.of(utf8.encode('plain text')));
  });

  test("acceptance: the app's response is the same with the source on and "
      'off: status, headers, body bytes, stream behaviour', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(70000, (i) => 0x41 + i % 26),
    );
    final url = _blobUrl(bytes, 'text/plain');
    Future<Map<String, Object?>> viaHttp() async {
      final streamed = await BrowserClient().send(
        http.Request('GET', Uri.parse(url)),
      );
      final chunks = <List<int>>[];
      await streamed.stream.forEach(chunks.add);
      return {
        'status': streamed.statusCode,
        'headers': streamed.headers,
        'bytes': [for (final c in chunks) ...c],
        'done': true,
      };
    }

    Future<Map<String, Object?>> viaXhr() async {
      final xhr = await _xhr('GET', url, type: 'arraybuffer');
      return {
        'status': _s(xhr['status']),
        'headers': _s(xhr.callMethod<JSAny?>('getAllResponseHeaders'.toJS)),
        'bytes': (xhr['response']! as JSArrayBuffer).toDart.asUint8List(),
      };
    }

    final on = [await viaHttp(), await viaXhr()];
    source.stop();
    final off = [await viaHttp(), await viaXhr()];
    expect(on, off);
    expect((on[0]['bytes']! as List<int>).length, bytes.length);
  });

  test('the app gets the very promise and response object of the '
      "browser's fetch", () async {
    source.stop();
    hooks.dispose();
    final saved = globalContext['fetch'];
    final response = (globalContext['Response']! as JSFunction)
        .callAsConstructor<JSObject>('hi'.toJS);
    JSAny? made;
    globalContext['fetch'] = ((JSAny? input, [JSAny? init]) {
      made = (globalContext['Promise']! as JSObject).callMethod<JSAny?>(
        'resolve'.toJS,
        response,
      );
      return made;
    }).toJS;
    try {
      hooks = HookRegistry();
      source = NetworkSource(hooks: hooks)..start(recorder);
      final promise = globalContext.callMethod<JSPromise<JSAny?>>(
        'fetch'.toJS,
        'https://example.test/a'.toJS,
      );
      expect(promise.strictEquals(made).toDart, isTrue);
      final value = await promise.toDart;
      expect(value.strictEquals(response).toDart, isTrue);
      // Ours read a clone; the app's body is still unread.
      expect((response['bodyUsed']! as JSBoolean).toDart, isFalse);
    } finally {
      source.stop();
      globalContext['fetch'] = saved;
    }
  });

  test('stop gives fetch and the XHR methods back', () {
    source.stop();
    hooks.dispose();
    final fetch = globalContext['fetch'];
    final proto =
        (globalContext['XMLHttpRequest']! as JSObject)['prototype']!
            as JSObject;
    final open = proto['open'];
    final send = proto['send'];
    hooks = HookRegistry();
    source = NetworkSource(hooks: hooks)..start(recorder);
    expect(globalContext['fetch'].strictEquals(fetch).toDart, isFalse);
    source.stop();
    expect(globalContext['fetch'].strictEquals(fetch).toDart, isTrue);
    expect(proto['open'].strictEquals(open).toDart, isTrue);
    expect(proto['send'].strictEquals(send).toDart, isTrue);
  });

  test('open with two arguments stays async', () {
    final url = _blobUrl(utf8.encode('x'), 'text/plain');
    final xhr = (globalContext['XMLHttpRequest']! as JSFunction)
        .callAsConstructor<JSObject>();
    xhr.callMethod<JSAny?>('open'.toJS, 'GET'.toJS, url.toJS);
    xhr.callMethod<JSAny?>('send'.toJS);
    // A sync XHR would be done (4) here.
    expect(_s(xhr['readyState']), isNot('4'));
  });

  test('a failed fetch gives net.error with the cause of the call', () async {
    TraceCause? cause;
    await CauseZone.enter(CauseKind.pointer, () async {
      cause = CauseZone.currentCause;
      try {
        await BrowserClient().get(Uri.parse('http://127.0.0.1:9/none'));
      } catch (_) {}
    });
    await _until(() => net().length == 2);
    expect(net()[1].kind, TraceKind.netError);
    expect(net()[1].cause, cause!.id);
  });
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

Future<JSObject> _xhr(
  String method,
  String url, {
  Map<String, String> headers = const {},
  String? type,
}) {
  final done = Completer<JSObject>();
  final xhr = (globalContext['XMLHttpRequest']! as JSFunction)
      .callAsConstructor<JSObject>();
  xhr.callMethod<JSAny?>('open'.toJS, method.toJS, url.toJS);
  if (type != null) xhr['responseType'] = type.toJS;
  for (final MapEntry(:key, :value) in headers.entries) {
    xhr.callMethod<JSAny?>('setRequestHeader'.toJS, key.toJS, value.toJS);
  }
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
