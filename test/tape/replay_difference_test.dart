import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/tape/tape_player.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/agent_host.dart';

/// PLAN-v2 Milestone 15, build step 6: differences from the tape (step 13)
/// and holds (step 15).
void main() {
  late PinPointController controller;
  late AgentBridge bridge;
  var target = '/a';

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
    target = '/a';
  });

  tearDown(() {
    TapePlayer.debugReset();
    controller.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      agentApp(
        controller: controller,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pushNamed(target),
                child: const Text('Go'),
              ),
            ),
          ),
        ),
        routes: {
          '/a': (_) => const Scaffold(body: Text('A')),
          '/b': (_) => const Scaffold(body: Text('B')),
        },
      ),
    );
    await tester.pump();
  }

  Future<Tape> record(WidgetTester tester) async {
    TraceSession.current!.mark();
    await tester.tap(find.text('Go'));
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    final answer = await drive(
      tester,
      controller.agent.run('save_tape', {'since': 'mark'}),
    );
    final id = (answer['result']! as Map)['id']! as String;
    // Back home, as the user would be before a replay.
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    return Tape.fromJson(bridge.notes.tapes[id]!['tape'])!;
  }

  Future<Map<String, Object?>> replay(
    WidgetTester tester,
    Tape tape, [
    Map<String, Object?> args = const {},
  ]) async {
    bridge.notes.tapes[tape.id] = {
      'tape': tape.toJson(),
      'bodies': tape.bodiesToJson(),
    };
    controller.agent.enabled = true;
    final answer = await drive(
      tester,
      controller.agent.run('replay', {'tape': tape.id, ...args}),
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  testWidgets('first_difference names the step at which the route order '
      'left the tape, and the replay goes on', (tester) async {
    await pumpApp(tester);
    final tape = await record(tester);
    expect(tape.routes, ['/a']);
    target = '/b'; // the code now goes elsewhere
    final result = await replay(tester, tape);
    expect(result['state'], 'done');
    final difference = result['first_difference']! as Map;
    expect(difference['what'], 'route');
    expect(difference['expected'], '/a');
    expect(difference['got'], '/b');
    expect(difference['step'], anyOf(isA<int>(), 'end'));
    await bridge.shutdown(tester);
  });

  testWidgets('fewer requests than the tape is a difference, not an error: '
      'the replay finishes', (tester) async {
    await pumpApp(tester);
    final recorded = await record(tester);
    // The tape made a request the app (after a fix) no longer makes.
    final tape = Tape(
      id: recorded.id,
      kind: recorded.kind,
      start: recorded.start,
      inputs: recorded.inputs,
      marks: recorded.marks,
      routes: recorded.routes,
      net: const [
        NetExchange(
          n: 0,
          key: 'GET https://api.test/again -',
          method: 'GET',
          url: 'https://api.test/again',
          t: 0,
          status: 200,
          size: 2,
        ),
      ],
      bodies: {0: utf8.encode('{}')},
    );
    final result = await replay(tester, tape);
    expect(result['state'], 'done');
    expect(result['first_difference'], {
      'step': 'end',
      'what': 'request',
      'expected': 'GET https://api.test/again -',
      'got': null,
    });
    expect(result['requests'], {'tape': 1, 'asked': 0});
    await bridge.shutdown(tester);
  });

  testWidgets('until step:N holds after step N; stop_replay ends it',
      (tester) async {
    await pumpApp(tester);
    final tape = await record(tester);
    final held = await replay(tester, tape, {'until': 'step:1'});
    expect(held['state'], 'held');
    expect(held['step'], 1);
    final stopped = await drive(
      tester,
      controller.agent.run('stop_replay', const {}),
    );
    expect((stopped['result']! as Map)['state'], 'stopped');
    expect(TapePlayer.current, isNull);
    await bridge.shutdown(tester);
  });

  testWidgets('until names a mark the tape lacks: an error before anything '
      'runs', (tester) async {
    await pumpApp(tester);
    final tape = await record(tester);
    bridge.notes.tapes[tape.id] = {'tape': tape.toJson(), 'bodies': {}};
    controller.agent.enabled = true;
    final answer = await drive(
      tester,
      controller.agent.run('replay', {'tape': tape.id, 'until': 'mark:5'}),
    );
    expect(answer['ok'], isFalse);
    expect('${answer['error']}', contains('mark:5'));
    expect(TapePlayer.current, isNull);
    await bridge.shutdown(tester);
  });
}
