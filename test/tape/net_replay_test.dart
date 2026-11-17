import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/tape/net_matcher.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/net_record.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 15, build step 3: what the network source decides
/// during a replay, without a browser. The web hooks only turn the answer
/// into a `Response` or a blob XHR; `test/tape/web/` runs them in Chrome.
void main() {
  tearDown(CauseZone.debugReset);

  const matcher = NetMatcher();
  Tape tape() => Tape(
    id: 'tp_test_0000',
    kind: TapeKind.full,
    start: const TapeStart(t: 0, seq: 1, wallTime: 'w'),
    net: [
      NetExchange(
        n: 0,
        key: matcher.key('GET', 'https://api.test/items', null),
        method: 'GET',
        url: 'https://api.test/items',
        t: 0,
        status: 200,
        ms: 20,
        size: 2,
      ),
    ],
    bodies: {0: Uint8List.fromList(utf8.encode('[]'))},
  );

  test('no replay: every request reaches the network', () {
    final net = NetRecorder(TraceRecorder());
    expect(
      net.replayAnswer(method: 'GET', url: 'https://api.test/items'),
      isNull,
    );
  });

  test('a request the tape knows is served; one it does not know fails and '
      'records replay.unmatched', () {
    final recorder = TraceRecorder();
    final net = NetRecorder(recorder)..replay = NetReplay(tape());
    expect(
      net.replayAnswer(method: 'GET', url: 'https://api.test/items'),
      isA<ServeAnswer>(),
    );
    final missing = net.replayAnswer(
      method: 'GET',
      url: 'https://api.test/other?token=abc',
    );
    expect(missing, isA<FailAnswer>());
    final event = recorder.lastOf(TraceKind.replayUnmatched)!;
    expect(event.data['then'], 'fail');
    // Masked like every recorded URL (rule 16).
    expect(event.data['url'], 'https://api.test/other?token=***');
  });

  test('rule 14: the bridge is never answered from a tape', () {
    final net = NetRecorder(
      TraceRecorder(),
      ignoreOrigins: {'http://127.0.0.1:4747'},
    )..replay = NetReplay(tape());
    expect(
      net.replayAnswer(method: 'GET', url: 'http://127.0.0.1:4747/commands'),
      isNull,
    );
  });

  test('Pinpoint\'s own work is never answered from a tape', () async {
    final net = NetRecorder(TraceRecorder())..replay = NetReplay(tape());
    CauseZone().run(() {});
    final answer = await CauseZone.internal(
      () async =>
          net.replayAnswer(method: 'GET', url: 'https://api.test/items'),
    );
    expect(answer, isNull);
  });
}
