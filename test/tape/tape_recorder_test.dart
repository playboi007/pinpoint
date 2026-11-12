import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/tape/net_matcher.dart';
import 'package:pinpoint/src/tape/tape_recorder.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 15, build step 2: the tape recorder, plain Dart. It
/// keeps inputs and exchanges since app start apart from the ring buffer.
void main() {
  tearDown(CauseZone.debugReset);

  late int now;
  late TraceRecorder recorder;
  late TapeRecorder tapes;
  late NetRecorder net;

  TapeStart startAt({required int t, required int seq}) =>
      TapeStart(t: t, seq: seq, wallTime: 'now', url: 'http://app/#/x');

  void setUpWith({
    int maxBodyBytes = TapeRecorder.defaultMaxBodyBytes,
    int maxEvents = 20000,
    bool bodies = true,
  }) {
    now = 0;
    recorder = TraceRecorder(clock: () => now, maxEvents: maxEvents);
    tapes = TapeRecorder(
      recorder,
      maxBodyBytes: maxBodyBytes,
      bodiesRead: bodies,
      appStart: const TapeStart(t: 0, seq: 1, wallTime: 'start'),
    )..start();
    net = NetRecorder(recorder, bodies: bodies, tap: tapes);
  }

  void tap(String phase, {int x = 10, int y = 20, String? by}) => recorder.add(
    TraceKind.pointer,
    widget: 'ElevatedButton',
    data: {'phase': phase, 'x': x, 'y': y, 'by': ?by},
  );

  void request(String url, String body, {int status = 200}) {
    final call = net.request(via: 'fetch', method: 'GET', url: url)!;
    now += 5;
    if (call.respond(
      status: status,
      headers: {'content-type': 'application/json', 'set-cookie': 'secret'},
    )) {
      call
        ..chunk(utf8.encode(body))
        ..end();
    }
  }

  test('a full tape from app start holds inputs, exchanges, marks and '
      'routes, with after', () {
    setUpWith();
    request('https://api.test/a?token=t1', '{"a":1}');
    now = 100;
    tap('down');
    tap('up');
    recorder.add(TraceKind.route, data: {'from': '/', 'to': '/form'});
    now = 200;
    recorder.add(TraceKind.text, data: {'value': 'hi', 'length': 2});
    recorder.add(TraceKind.mark, data: {'text': 'here', 'by': 'user'});
    request('https://api.test/a?token=t2', '{"a":2}');
    tap('down');

    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.kind, TapeKind.full);
    expect(tape.partial, isFalse);
    expect(tape.start.wallTime, 'start');
    expect([for (final i in tape.inputs) i.step], [1, 2, 3, 4]);
    expect(tape.inputs.first.after, [0]);
    expect(tape.inputs.last.after, [0, 1]);
    expect(tape.net, hasLength(2));
    // Two requests with the same key (the token leaves it): nth 1 and 2.
    expect(tape.net[0].key, tape.net[1].key);
    expect([tape.net[0].nth, tape.net[1].nth], [1, 2]);
    expect(utf8.decode(tape.bodies[1]!), '{"a":2}');
    expect(tape.marks.single.text, 'here');
    expect(tape.routes, ['/form']);
  });

  test('acceptance (part): masked headers stay masked and no body is in '
      'the tape JSON', () {
    setUpWith();
    request('https://api.test/a?token=t1', '{"secret":"body"}');
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    final json = jsonEncode(tape.toJson());
    expect(json, isNot(contains('"body"')));
    expect(json, isNot(contains('t1')));
    expect(tape.net.single.headers['set-cookie'], '***');
  });

  test('the agent\'s synthetic input is not recorded into a tape (watch '
      'out for: tagged agent)', () {
    setUpWith();
    tap('down', by: 'agent');
    tap('up', by: 'agent');
    recorder.add(TraceKind.text, data: {'value': 'x', 'by': 'agent'});
    tap('down');
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.inputs, hasLength(1));
  });

  test('a segment from the last mark starts there and leaves out what came '
      'before', () {
    setUpWith();
    request('https://api.test/a', '{}');
    now = 50;
    tap('down');
    now = 100;
    final mark = recorder.add(TraceKind.mark, data: {'text': 'm'});
    now = 150;
    tap('up');
    request('https://api.test/b', '{}');
    final tape = tapes.save(since: TapeSince.parse('mark'), startAt: startAt);
    expect(tape.kind, TapeKind.segment);
    expect(tape.start.seq, mark.seq);
    expect(tape.start.t, 100);
    expect(tape.start.url, 'http://app/#/x');
    expect(tape.inputs.single.data['phase'], 'up');
    expect(tape.net.single.url, 'https://api.test/b');
    expect(tape.net.single.n, 0);
  });

  test('since: seconds back, and mark:N names the Nth mark', () {
    setUpWith();
    recorder.add(TraceKind.mark, data: {'text': 'one'});
    now = 1000;
    tap('down');
    now = 5000;
    recorder.add(TraceKind.mark, data: {'text': 'two'});
    tap('up');
    now = 6000;
    expect(
      tapes.save(since: TapeSince.parse('3s'), startAt: startAt).inputs,
      hasLength(1),
    );
    expect(
      tapes.save(since: TapeSince.parse(3), startAt: startAt).inputs,
      hasLength(1),
    );
    expect(
      tapes.save(since: TapeSince.parse('mark:1'), startAt: startAt).inputs,
      hasLength(2),
    );
    expect(() => TapeSince.parse('mark:9').markIndex, returnsNormally);
    expect(
      () => tapes.save(since: TapeSince.parse('mark:9'), startAt: startAt),
      throwsFormatException,
    );
    expect(() => TapeSince.parse('soon'), throwsFormatException);
  });

  test('acceptance: a tape over the body limit says it is partial and is '
      'saved as a segment', () {
    setUpWith(maxBodyBytes: 100);
    request('https://api.test/1', 'x' * 60);
    now = 10;
    tap('down');
    request('https://api.test/2', 'y' * 60); // pushes body 1 out
    now = 20;
    tap('up');
    expect(tapes.canSaveFull, isFalse);
    expect(tapes.startsAgo, isNotNull);
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.kind, TapeKind.segment);
    expect(tape.partial, isTrue);
    expect(tape.partialReason, contains('bodies over'));
    expect(tape.partialReason, contains('tape starts'));
    // It starts after the answer whose body was dropped.
    expect(tape.net.single.url, 'https://api.test/2');
    expect([for (final i in tape.inputs) i.data['phase']], ['down', 'up']);
  });

  test('with bodies off there are no full tapes and no answers to serve', () {
    setUpWith(bodies: false);
    request('https://api.test/a', '{}');
    tap('down');
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.kind, TapeKind.segment);
    expect(tape.bodiesRead, isFalse);
    expect(tape.partial, isFalse);
    expect(tape.bodies, isEmpty);
    expect(
      NetReplay(tape).answer(method: 'GET', url: 'https://api.test/a'),
      isA<PassAnswer>(),
    );
  });

  test('watch out for: an event stream is marked unsupported', () {
    setUpWith();
    final call = net.request(via: 'fetch', method: 'GET', url: 'u')!;
    call.respond(status: 200, headers: {'content-type': 'text/event-stream'});
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.net.single.unsupported, 'event stream');
  });

  test('a failed request keeps its error', () {
    setUpWith();
    net.request(via: 'fetch', method: 'GET', url: 'u')!.fail('offline');
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.net.single.error, 'offline');
    expect(tape.net.single.answeredSeq, isNotNull);
  });

  test('inputs survive when the ring buffer drops them', () {
    setUpWith(maxEvents: 10);
    tap('down');
    for (var i = 0; i < 50; i++) {
      recorder.add(TraceKind.frame);
    }
    expect(recorder.partial, isTrue);
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.kind, TapeKind.full);
    expect(tape.inputs, hasLength(1));
  });

  test('clear drops the stores at once; a full tape is then impossible', () {
    setUpWith();
    tap('down');
    request('https://api.test/a', '{}');
    tapes.clear();
    expect(tapes.bodyBytes, 0);
    expect(tapes.canSaveFull, isFalse);
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.inputs, isEmpty);
    expect(tape.net, isEmpty);
  });

  test('while a replay runs, nothing is recorded into a tape', () {
    setUpWith();
    tapes.replaying = true;
    tap('down');
    request('https://api.test/a', '{}');
    tapes.replaying = false;
    final tape = tapes.save(since: TapeSince.start, startAt: startAt);
    expect(tape.inputs, isEmpty);
    expect(tape.kind, TapeKind.segment);
    expect(tape.partialReason, contains('replay'));
  });

  test('size estimate grows with bodies and inputs', () {
    setUpWith();
    final empty = tapes.estimatedBytes;
    request('https://api.test/a', 'z' * 1000);
    tap('down');
    expect(tapes.estimatedBytes, greaterThan(empty + 1000));
  });
}
