import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/agent/agent_control.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';

/// The agent's commands wait until the app stops drawing, and frames drawn
/// by Pinpoint count as the app moving. So the agent layer never animates
/// when control turns on or while a command runs: the chip changes fill and
/// text instead.
void main() {
  late AgentControl agent;

  setUp(() => agent = AgentControl());
  tearDown(() => agent.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: SizedBox.expand(
        child: AgentLayer(agent: agent, origin: () => Offset.zero),
      ),
    ),
  );

  testWidgets('turning control on draws the chip and nothing moves', (
    tester,
  ) async {
    await pump(tester);
    agent.enabled = true;
    await tester.pump();
    expect(find.text('AGENT CONTROL ON · ESC STOPS'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('while a command runs, the chip says so and nothing moves', (
    tester,
  ) async {
    final done = Completer<Map<String, Object?>>();
    agent.runner = (tool, args, cancel) => done.future;
    agent.enabled = true;
    await pump(tester);
    final answer = agent.run('tap', const {});
    await tester.pump();
    expect(find.text('AGENT DRIVING · TAP · ESC STOPS'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);

    done.complete({'ok': true});
    await answer;
    await tester.pump();
    expect(find.text('AGENT CONTROL ON · ESC STOPS'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
