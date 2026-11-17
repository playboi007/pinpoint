import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/agent_tools.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/timeline_panel.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/trace_causes.dart';

import '../support/trace_host.dart';
import '../support/tweak_host.dart' show selectForTweak;

/// PLAN-v2 Milestone 14, build step 7: the `why` and `caused_by` tools in
/// the app, through the agent's command path. `flutter test` has its own
/// zone, so there are no causes here (watch out for); these tests check
/// the tool shapes, the errors and that nothing breaks.
void main() {
  late PinPointController controller;
  final counter = GlobalKey<_CounterState>();

  setUp(() => controller = PinPointController());
  tearDown(() {
    TimelinePanel.open.value = false;
    controller.dispose();
    CauseZone.debugReset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        home: Scaffold(body: _Counter(key: counter)),
      ),
    );
    await tester.pump();
  }

  test('the bridge offers why and caused_by, with the post-frame limit in '
      "why's description", () {
    expect(agentToolNames, containsAll(<String>['why', 'caused_by']));
    final why = agentTools.firstWhere((t) => t['name'] == 'why');
    expect(why['description'], contains(whyLimits));
  });

  testWidgets('why answers a chain, and says there are no causes', (
    tester,
  ) async {
    await pumpApp(tester);
    recorder.add(TraceKind.probe, data: const {'name': 'x'});
    final result = await toolResult(tester, controller, 'why', {
      'seq': recorder.newest!.seq,
    });
    expect(result['chain'], isA<List<Object?>>());
    expect(result['hint'], contains('PinPoint.run'));
  });

  testWidgets('why on a seq that is gone is an error the agent can act on', (
    tester,
  ) async {
    await pumpApp(tester);
    final answer = await runTool(tester, controller, 'why', {'seq': 999999});
    expect(answer['ok'], isFalse);
    expect('${answer['error']}', contains('not held'));
    final missing = await runTool(tester, controller, 'why');
    expect('${missing['error']}', contains('seq'));
  });

  testWidgets('caused_by counts the rebuilds of the widget\'s subtree', (
    tester,
  ) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    for (var i = 0; i < 3; i++) {
      counter.currentState!.increment();
      await tester.pump();
    }
    final result = await toolResult(tester, controller, 'caused_by', {
      'target': {'type': '_Counter'},
      'since': '30s',
    });
    final counts = result['counts']! as Map<String, Object?>;
    expect(counts['rebuilds'], greaterThanOrEqualTo(3));
    expect(result['summary'], contains('rebuilds'));
    expect(result['widget'], '_Counter');
    await toolResult(tester, controller, 'trace_detail', {'on': false});
  });

  testWidgets('the Timeline puts events under their cause', (tester) async {
    await pumpApp(tester);
    CauseZone().run(() {});
    final tap = CauseZone.newCause(CauseKind.pointer)!;
    final other = CauseZone.newCause(CauseKind.message)!;
    recorder
      ..add(TraceKind.pointer, data: const {'phase': 'down'}, cause: tap)
      ..add(TraceKind.message, data: const {'origin': 'x'}, cause: other);
    final request = recorder.add(
      TraceKind.netRequest,
      data: const {'method': 'GET'},
      cause: tap,
    );
    await tester.tap(find.byKey(TimelinePanel.buttonKey));
    await tester.pump();
    final header = find.byKey(TimelinePanel.causeKey(tap.id));
    expect(header, findsOneWidget);
    expect(
      find.descendant(of: header, matching: find.textContaining('pointer')),
      findsOneWidget,
    );
    // Both events of the tap sit under one header, the message under its
    // own.
    expect(find.byKey(TimelinePanel.causeKey(other.id)), findsOneWidget);
    final tapTop = tester.getTopLeft(header).dy;
    final otherTop = tester
        .getTopLeft(find.byKey(TimelinePanel.causeKey(other.id)))
        .dy;
    final requestTop = tester
        .getTopLeft(find.byKey(TimelinePanel.rowKey(request.seq)))
        .dy;
    expect(requestTop, greaterThan(tapTop));
    expect(otherTop, greaterThan(requestTop));
    controller.stop();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the Info tab says what the picked widget caused in the last '
      '5 s', (tester) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    counter.currentState!.increment();
    await tester.pump();
    await selectForTweak(
      tester,
      controller,
      find.byType(_Counter),
      openTab: false,
    );
    await tester.tap(find.byKey(InfoPanel.infoTabKey));
    await tester.pump();
    final caused = find.byKey(InfoPanel.causedKey);
    await tester.ensureVisible(caused);
    expect(
      find.descendant(of: caused, matching: find.textContaining('rebuilds')),
      findsOneWidget,
    );
    await toolResult(tester, controller, 'trace_detail', {'on': false});
    controller.stop();
    await tester.pump(const Duration(seconds: 2));
  });
}

// Appended tests use the same app.
class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) => Text('$count');
}
