import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/timeline_panel.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, steps 9 and 11: marks and the Timeline.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() {
    TimelinePanel.open.value = false;
    controller.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      traceApp(controller: controller, home: const _Screen()),
    );
    await tester.pump();
  }

  testWidgets('M while picking makes a mark; the agent marks with text, and '
      'get_trace reads from the last mark', (tester) async {
    await pumpApp(tester);
    controller.startPicking();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    final byUser = recorder.lastOf(TraceKind.mark)!;
    expect(byUser.data['by'], 'user');
    controller.stop();
    await tester.pump();

    final mark = await toolResult(tester, controller, 'mark', {
      'text': 'the list is empty here',
    });
    expect(mark['seq'], greaterThan(byUser.seq));
    PinPoint.probe('after', {'n': 1});
    final lines = await traceLines(tester, controller, {
      'since': 'mark',
      'kinds': ['mark', 'probe'],
    });
    expect(lines.first, contains('mark  "the list is empty here" by agent'));
    expect(lines.last, contains('probe  after n=1'));
    // M in idle stays with the app.
    final before = recorder.nextSeq;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(
      recorder.events.where((e) => e.seq >= before && e.kind == TraceKind.mark),
      isEmpty,
    );
  });

  testWidgets('the Timeline holds level 3 while open, groups by frame, '
      'filters by kind, and a click flashes the widget', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(TimelinePanel.buttonKey));
    await tester.pump();
    expect(find.byKey(TimelinePanel.panelKey), findsOneWidget);
    expect(TraceSession.current!.demands, contains(TraceDemand.timeline));
    expect(debugOnRebuildDirtyWidget, isNotNull);

    // A change in the app while the Timeline is open: picking traps
    // pointers, so the change comes from code.
    tester.state<_ScreenState>(find.byType(_Screen)).increment();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final build = recorder.lastOf(TraceKind.build)!;
    final row = find.byKey(TimelinePanel.rowKey(build.seq));
    expect(row, findsOneWidget);
    // Frame headers show the recorder's own time.
    expect(find.textContaining(RegExp(r'^f\d+ .*rec \d')), findsWidgets);

    await tester.tap(row);
    await tester.pump();
    expect(controller.agent.flash.value, isNotNull);

    await tester.tap(find.byKey(TimelinePanel.chipKey(TraceKind.build)));
    await tester.pump();
    expect(row, findsNothing);

    await tester.tap(find.byKey(TimelinePanel.closeKey));
    await tester.pump();
    expect(TraceSession.current!.demands, isEmpty);
    expect(debugOnRebuildDirtyWidget, isNull);
    controller.stop();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a mark from the Timeline can be named', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(TimelinePanel.buttonKey));
    await tester.pump();
    await tester.tap(find.byKey(TimelinePanel.markKey));
    await tester.pump();
    final mark = recorder.lastOf(TraceKind.mark)!;
    await tester.tap(find.byTooltip('Name this mark'));
    await tester.pump();
    await tester.enterText(
      find.byKey(TimelinePanel.nameKey(mark.seq)),
      'empty list',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(mark.data['text'], 'empty list');
    expect(find.text('empty list'), findsOneWidget);
    // Going idle closes the Timeline and lets level 3 go.
    controller.stop();
    await tester.pump();
    expect(TimelinePanel.open.value, isFalse);
    expect(debugOnRebuildDirtyWidget, isNull);
  });
}

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  int count = 0;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('count $count')));
}
