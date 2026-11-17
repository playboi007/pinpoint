import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/agent_host.dart';

/// PLAN-v2 Milestone 15, build step 2: `save_tape` in the app. The tape
/// goes to the bridge with its bodies; the tool answers its summary only.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      agentApp(controller: controller, home: const _Form()),
    );
    await tester.pump();
  }

  testWidgets('save_tape stores a full tape of what the user did, and '
      'answers no body', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('field')), 'Ada');
    await tester.pump();
    await tester.tap(find.text('Submit'));
    // The anchor is filled from a zero timer after the event; only a pump
    // with a duration fires it in a widget test.
    await tester.pump(Duration.zero);

    final answer = await drive(
      tester,
      controller.agent.run('save_tape', {'name': 'form'}),
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    final summary = answer['result']! as Map<String, Object?>;
    expect(summary['kind'], 'full');
    expect(summary.containsKey('bodies'), isFalse);

    final stored = bridge.notes.tapes[summary['id']]!;
    final tape = Tape.fromJson(stored['tape'])!;
    expect(tape.name, 'form');
    final kinds = [
      for (final i in tape.inputs) '${i.kind}:${i.data['phase'] ?? ''}',
    ];
    expect(kinds, containsAllInOrder(['input.pointer:down', 'input.text:']));
    expect(kinds.last, 'input.pointer:up');
    final down = tape.inputs.lastWhere((i) => i.data['phase'] == 'down');
    // The tap on Submit carries its anchor, for a replay after a layout
    // change.
    expect(down.data['anchor'], isNotNull);
    expect(down.data['fx'], isNotNull);
    expect(tape.start.width, isNotNull);
    await bridge.shutdown(tester);
  });

  testWidgets('save_tape since a mark that does not exist is an error the '
      'agent can act on', (tester) async {
    await pumpApp(tester);
    final answer = await drive(
      tester,
      controller.agent.run('save_tape', {'since': 'mark'}),
    );
    expect(answer['ok'], isFalse);
    expect('${answer['error']}', contains('no mark yet'));
    await bridge.shutdown(tester);
  });

  testWidgets('Clear recording drops the tape stores at once', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Submit'));
    await tester.pump();
    final session = TraceSession.current!;
    expect(session.saveTape().inputs, isNotEmpty);
    session.clearRecording();
    expect(session.saveTape().inputs, isEmpty);
    expect(session.tapes.canSaveFull, isFalse);
    await bridge.shutdown(tester);
  });
}

class _Form extends StatelessWidget {
  const _Form();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const TextField(key: Key('field')),
        ElevatedButton(onPressed: () {}, child: const Text('Submit')),
      ],
    ),
  );
}
