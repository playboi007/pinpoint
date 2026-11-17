import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/tape.dart';

/// PLAN-v2 Milestone 15, build step 1: what a tape holds, plain Dart.
void main() {
  Tape sample({bool partial = false}) => Tape(
    id: 'tp_20261113_100000_ab12',
    name: 'form',
    kind: TapeKind.full,
    start: const TapeStart(
      t: 0,
      seq: 1,
      wallTime: '2026-11-13T10:00:00Z',
      url: 'http://localhost:8080/#/form',
      width: 800,
      height: 600,
      pixelRatio: 2,
      locale: 'en-US',
      environment: {'textScale': 1.0},
      storage: {
        'local': {'theme': 'dark'},
      },
    ),
    inputs: [
      TapeInput(
        step: 1,
        seq: 5,
        t: 100,
        frame: 3,
        kind: 'input.pointer',
        widget: 'ElevatedButton',
        data: const {'phase': 'down', 'x': 10, 'y': 20},
        after: const [0],
      ),
    ],
    net: [
      const NetExchange(
        n: 0,
        key: 'GET https://api.test/a -',
        nth: 1,
        method: 'GET',
        url: 'https://api.test/a',
        t: 10,
        status: 200,
        headers: {'content-type': 'application/json'},
        ms: 40,
        hash: 'abcd0123',
        size: 2,
        answeredSeq: 4,
      ),
    ],
    marks: const [TapeMark(seq: 9, t: 300, text: 'wrong here', by: 'user')],
    routes: const ['/', '/form'],
    partial: partial,
    partialReason: partial ? 'bodies over 20 MB' : null,
    bodies: {0: Uint8List.fromList(utf8.encode('{}'))},
  );

  test('round trip through JSON keeps every part', () {
    final tape = sample();
    final again = Tape.fromJson(jsonDecode(jsonEncode(tape.toJson())))!;
    expect(again.toJson(), tape.toJson());
    expect(again.start.storage, {
      'local': {'theme': 'dark'},
    });
    expect(again.inputs.single.after, [0]);
    expect(again.net.single.answeredSeq, 4);
    expect(again.marks.single.text, 'wrong here');
  });

  test('bodies travel apart from the tape, as base64 by order number', () {
    final tape = sample();
    expect(jsonEncode(tape.toJson()), isNot(contains('e30=')));
    final bodies = tape.bodiesToJson();
    expect(bodies, {'0': base64Encode(utf8.encode('{}'))});
    final again = Tape.fromJson(tape.toJson(), bodies: bodies)!;
    expect(utf8.decode(again.bodies[0]!), '{}');
  });

  test('a broken tape reads as null', () {
    expect(Tape.fromJson(null), isNull);
    expect(Tape.fromJson({'id': 'x'}), isNull);
  });

  test('summary counts inputs, requests, marks and bytes', () {
    final summary = sample().summary;
    expect(summary['kind'], 'full');
    expect(summary['inputs'], 1);
    expect(summary['requests'], 1);
    expect(summary['marks'], 1);
    expect(summary['bytes'], 2);
    expect(summary.containsKey('partial'), isFalse);
    expect(sample(partial: true).summary['partial'], 'bodies over 20 MB');
  });

  test('after: the answers that arrived before each input, by seq', () {
    const net = [
      NetExchange(
        n: 0,
        key: 'a',
        method: 'GET',
        url: 'a',
        t: 0,
        answeredSeq: 3,
      ),
      NetExchange(
        n: 1,
        key: 'b',
        method: 'GET',
        url: 'b',
        t: 0,
        answeredSeq: 8,
      ),
      NetExchange(n: 2, key: 'c', method: 'GET', url: 'c', t: 0),
    ];
    expect(answeredBefore(2, net), isEmpty);
    expect(answeredBefore(4, net), [0]);
    expect(answeredBefore(9, net), [0, 1]);
  });

  test('a tape id matches the pattern the bridge accepts', () {
    final id = newTapeId(DateTime.utc(2026, 11, 13, 10, 0, 1));
    expect(tapeIdPattern.hasMatch(id), isTrue, reason: id);
    expect(id, startsWith('tp_20261113_100001_'));
    expect(tapeIdPattern.hasMatch('../x'), isFalse);
    expect(runIdPattern.hasMatch(newRunId(DateTime.utc(2026))), isTrue);
  });
}
