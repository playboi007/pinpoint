import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 3: the network events, without a
/// browser. The web hooks only turn `fetch` and XHR objects into these
/// calls; `test/trace/web/network_web_test.dart` runs them in Chrome.
void main() {
  tearDown(CauseZone.debugReset);

  NetRecorder net0({bool bodies = true, TraceRecorder? recorder}) =>
      NetRecorder(recorder ?? TraceRecorder(), bodies: bodies);

  test('a request and its answer: net.request, then net.response linked to '
      'it, with status, time, size and body hash', () {
    final net = net0();
    final call = net.request(
      via: 'fetch',
      method: 'post',
      url: 'https://api.test/items?page=2',
      body: utf8.encode('{"a":1}'),
    )!;
    expect(
      call.respond(
        status: 201,
        headers: {'content-type': 'application/octet-stream'},
      ),
      isFalse,
    );
    final events = net.recorder.events.toList();
    expect(
      [for (final e in events) e.kind],
      [TraceKind.netRequest, TraceKind.netResponse],
    );
    final request = events[0].data;
    expect(request['method'], 'POST');
    expect(request['url'], 'https://api.test/items?page=2');
    expect(request['size'], 7);
    expect(request['hash'], NetHash.of(utf8.encode('{"a":1}')));
    final response = events[1].data;
    expect(response['req'], events[0].seq);
    expect(response['status'], 201);
    expect(response['ms'], isA<int>());
    // Not text or JSON by its type: the body is not read.
    expect(response['body'], 'not read: application/octet-stream');
  });

  test('a JSON answer is read, hashed and kept for the tape', () {
    final net = net0();
    final call = net.request(via: 'xhr', method: 'GET', url: '/a')!;
    expect(
      call.respond(
        status: 200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
      isTrue,
    );
    call
      ..chunk(utf8.encode('{"items":'))
      ..chunk(utf8.encode('[]}'))
      ..end();
    final response = net.recorder.events.last;
    expect(response.data['size'], 12);
    expect(response.data['hash'], NetHash.of(utf8.encode('{"items":[]}')));
    expect(response.data['type'], 'application/json; charset=utf-8');
    expect(net.bodies.bodyOf(response.seq), utf8.encode('{"items":[]}'));
  });

  test('bodies off: no read, no hash, nothing kept', () {
    final net = net0(bodies: false);
    final call = net.request(via: 'fetch', method: 'GET', url: '/a')!;
    expect(
      call.respond(status: 200, headers: {'content-type': 'text/plain'}),
      isFalse,
    );
    final response = net.recorder.events.last;
    expect(response.data.containsKey('hash'), isFalse);
    expect(response.data['body'], 'not read: TraceConfig.bodies is false');
    expect(net.bodies.length, 0);
  });

  test('watch out for: a clone of a large or binary body is never made', () {
    final net = net0();
    final large = net.request(via: 'fetch', method: 'GET', url: '/big')!;
    expect(
      large.respond(
        status: 200,
        headers: {
          'content-type': 'text/plain',
          'content-length': '${NetRecorder.maxBody + 1}',
        },
      ),
      isFalse,
    );
    expect(
      net.recorder.events.last.data['body'],
      'not read: larger than 256 KB',
    );
    final image = net.request(via: 'fetch', method: 'GET', url: '/a.png')!;
    expect(
      image.respond(status: 200, headers: {'content-type': 'image/png'}),
      isFalse,
    );
    // A stream that never ends is text, but never read.
    final events = net.request(via: 'fetch', method: 'GET', url: '/sse')!;
    expect(
      events.respond(
        status: 200,
        headers: {'content-type': 'text/event-stream'},
      ),
      isFalse,
    );
  });

  test('a body larger than the limit keeps its hash and says truncated', () {
    final net = net0();
    final call = net.request(via: 'fetch', method: 'GET', url: '/long')!;
    call.respond(status: 200, headers: {'content-type': 'text/plain'});
    final chunk = List<int>.filled(100 * 1024, 0x61);
    for (var i = 0; i < 3; i++) {
      call.chunk(chunk);
    }
    call.end();
    final response = net.recorder.events.last;
    expect(response.data['size'], 300 * 1024);
    expect(response.data['truncated'], isTrue);
    expect(
      response.data['hash'],
      NetHash.of(List<int>.filled(300 * 1024, 0x61)),
    );
    expect(net.bodies.bodyOf(response.seq), hasLength(NetRecorder.maxBody));
  });

  test('a failed request gives net.error', () {
    final net = net0();
    net.request(via: 'xhr', method: 'GET', url: '/a')!.fail('timeout');
    final error = net.recorder.events.last;
    expect(error.kind, TraceKind.netError);
    expect(error.data['error'], 'timeout');
    expect(error.data['req'], net.recorder.events.first.seq);
  });

  test('the answer has the cause of the call, also when the browser reports '
      'it outside every zone', () async {
    final net = net0();
    final zone = CauseZone();
    late Zone binding;
    zone.run(() => binding = Zone.current);
    late NetCall call;
    binding.run(() {
      call = net.request(via: 'fetch', method: 'GET', url: '/a')!;
    });
    // A JS promise callback: no cause in the zone.
    await Future<void>.delayed(Duration.zero);
    expect(CauseZone.currentCause, isNull);
    call
      ..respond(status: 200, headers: const {})
      ..end();
    final events = net.recorder.events.toList();
    expect(events[0].cause, isNotNull);
    expect(events[1].cause, events[0].cause);
  });

  test('the body store is bounded by count and bytes', () {
    final store = NetBodies(maxCount: 3, maxBytes: 10);
    for (var i = 1; i <= 5; i++) {
      store.keep(i, List<int>.filled(4, i));
    }
    expect(store.length, 2);
    expect(store.bytes, lessThanOrEqualTo(10));
    expect(store.bodyOf(5), isNotNull);
    expect(store.bodyOf(1), isNull);
  });

  test('the hash is the same on every platform: FNV-1a, 32 bits', () {
    expect(NetHash.of(const []), '811c9dc5');
    expect(NetHash.of(utf8.encode('a')), 'e40c292c');
    expect(NetHash.of(utf8.encode('foobar')), 'bf9cf968');
  });

  test('compact lines: a loop of the same request folds', () {
    final net = net0();
    for (var i = 0; i < 4; i++) {
      net.request(via: 'fetch', method: 'GET', url: '/existing?type=faq')!
        ..respond(status: 200, headers: const {})
        ..end();
    }
    final lines = compactTrace(net.recorder.events.toList()).lines;
    expect(lines.first, contains('×4 of:'));
    expect(lines[1], contains('net.request  GET /existing?type=faq'));
    expect(lines[2], contains('net.response  200 GET /existing?type=faq'));
  });
}
