import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, build step 2: the frame source, source levels,
/// `trace_detail`, the rebuild source and `get_trace` end to end.
///
/// `debugOnRebuildDirtyWidget` is one global slot: every test leaves it
/// null.
void main() {
  late PinPointController controller;
  final counter = GlobalKey<_CounterState>();

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> pumpApp(
    WidgetTester tester, {
    PinPointConfig config = const PinPointConfig(),
  }) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: config,
        home: Scaffold(body: _Counter(key: counter)),
      ),
    );
    await tester.pump();
  }

  void devTools(Element element, bool builtOnce) {}

  testWidgets('acceptance: with no Timeline, no watch and no trace_detail, '
      'debugOnRebuildDirtyWidget is null', (tester) async {
    await pumpApp(tester);
    expect(TraceSession.current, isNotNull);
    expect(debugOnRebuildDirtyWidget, isNull);

    final on = await toolResult(tester, controller, 'trace_detail', {
      'on': true,
    });
    expect(on['on'], isTrue);
    expect(on['rebuilds'], 'recorded');
    expect(on['running'], contains('rebuild'));
    expect(debugOnRebuildDirtyWidget, isNotNull);

    final off = await toolResult(tester, controller, 'trace_detail', {
      'on': false,
    });
    expect(off['on'], isFalse);
    expect(debugOnRebuildDirtyWidget, isNull);
  });

  testWidgets('acceptance: DevTools "track rebuilds" can turn on while only '
      'level 1 runs; then trace_detail shares the slot with it', (
    tester,
  ) async {
    await pumpApp(tester);
    // What DevTools does when tracking turns on: it asserts the slot is
    // null, then writes it (api-notes item 8).
    expect(debugOnRebuildDirtyWidget, isNull);
    var devToolsCalls = 0;
    void devTools(Element element, bool builtOnce) => devToolsCalls++;
    debugOnRebuildDirtyWidget = devTools;

    final on = await toolResult(tester, controller, 'trace_detail', {
      'on': true,
    });
    expect(on['on'], isTrue);
    expect(on['rebuilds'], contains('shared'));
    expect(on['running'], containsAll(<String>['rebuild', 'watch']));
    expect(
      recorder.lastOf(TraceKind.detailOn)!.data['reason'],
      'rebuild slot shared',
    );

    // Both get the counter's rebuild: DevTools' counts go on.
    final from = recorder.nextSeq;
    counter.currentState!.increment();
    await tester.pump();
    expect(devToolsCalls, greaterThan(0));
    expect(
      recorder.events.where(
        (e) =>
            e.seq >= from &&
            e.kind == TraceKind.build &&
            e.widget == '_Counter',
      ),
      hasLength(1),
    );

    await toolResult(tester, controller, 'trace_detail', {'on': false});
    // DevTools gets its slot back.
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('DevTools turning its tracking off while level 3 runs clears '
      'the slot; the hook goes back in and the lost frame is a gap', (
    tester,
  ) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    final hook = debugOnRebuildDirtyWidget;
    // DevTools turned its tracking off: it clears the slot.
    debugOnRebuildDirtyWidget = null;
    final lostFrom = recorder.nextSeq;
    counter.currentState!.increment();
    await tester.pump();
    expect(debugOnRebuildDirtyWidget, same(hook));
    expect(recorder.lastOf(TraceKind.detailOff), isNull);
    final lostTo = recorder.nextSeq - 1;
    expect(recorder.rebuildGaps(lostFrom, lostTo), isNotEmpty);

    // The next frame is recorded again.
    final from = recorder.nextSeq;
    counter.currentState!.increment();
    await tester.pump();
    expect(recorder.rebuildGaps(from, recorder.nextSeq - 1), isEmpty);
    expect(
      recorder.events.where(
        (e) =>
            e.seq >= from &&
            e.kind == TraceKind.build &&
            e.widget == '_Counter',
      ),
      hasLength(1),
    );
    await toolResult(tester, controller, 'trace_detail', {'on': false});
    expect(debugOnRebuildDirtyWidget, isNull);
  });

  testWidgets('a tool that writes over the hook while level 3 runs stops '
      'the rebuild source and keeps the slot', (tester) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    debugOnRebuildDirtyWidget = devTools;
    counter.currentState!.increment();
    await tester.pump();
    final lost = recorder.lastOf(TraceKind.detailOff)!;
    expect(lost.data['reason'], 'rebuild slot taken');
    final status = await toolResult(tester, controller, 'trace_detail', {
      'on': false,
    });
    expect(status['on'], isFalse);
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('the heat detector and the trace share one hook', (tester) async {
    await pumpApp(tester);
    controller.findings.trackRebuilds = true;
    await tester.pump();
    final hook = debugOnRebuildDirtyWidget;
    expect(hook, isNotNull);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    expect(debugOnRebuildDirtyWidget, same(hook));
    expect(controller.findings.rebuildsTakenOver, isFalse);
    await toolResult(tester, controller, 'trace_detail', {'on': false});
    // The detector still counts.
    expect(debugOnRebuildDirtyWidget, same(hook));
    controller.findings.trackRebuilds = false;
    await tester.pump();
    expect(debugOnRebuildDirtyWidget, isNull);
  });

  testWidgets('get_trace end to end: how many times the counter rebuilt, '
      'and a note for the time before detail.on', (tester) async {
    await pumpApp(tester);
    counter.currentState!.increment();
    await tester.pump();
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    for (var i = 0; i < 3; i++) {
      counter.currentState!.increment();
      await tester.pump();
    }
    final result = await toolResult(tester, controller, 'get_trace', {
      'kinds': ['build', 'detail'],
    });
    final lines = (result['lines']! as String).split('\n');
    // Each frame rebuilds the counter and its Text: one block, three
    // times.
    expect(lines, contains(endsWith('×3 of:')), reason: lines.join('\n'));
    expect(lines, contains(contains('build  _Counter (trace_detail_test')));
    expect(lines.first, contains('level 3 on: rebuild'));
    final notes = result['notes']! as List<Object?>;
    expect(notes.single, contains('rebuilds not recorded for seq 1-'));

    final frames = await toolResult(tester, controller, 'get_trace', {
      'kinds': ['frame'],
      'detail': 'full',
      'limit': 30,
    });
    // The three frames that rebuilt the counter; other frames rebuilt less.
    final counts = [
      for (final e
          in (frames['events']! as List<Object?>).cast<Map<String, Object?>>())
        (e['data']! as Map<String, Object?>)['builds'],
    ];
    expect(counts.where((n) => n is int && n >= 2), hasLength(3));
    await toolResult(tester, controller, 'trace_detail', {'on': false});
  });

  testWidgets('frames carry numbers, and an event inside a build gets the '
      'frame being drawn', (tester) async {
    await pumpApp(tester);
    final before = recorder.newest!.frame;
    counter.currentState!.recordOnNextBuild = true;
    counter.currentState!.increment();
    await tester.pump();
    final inBuild = recorder.lastOf('test.build')!;
    final frame = recorder.lastOf(TraceKind.frame)!;
    expect(inBuild.frame, before + 1);
    expect(frame.frame, before + 1);
    expect(frame.seq, greaterThan(inBuild.seq));
  });

  testWidgets('acceptance: with Pinpoint off no session or source exists, '
      'and with the recorder off get_trace says so', (tester) async {
    await pumpApp(tester, config: const PinPointConfig(enabled: false));
    expect(TraceSession.current, isNull);
    await pumpApp(
      tester,
      config: const PinPointConfig(trace: TraceConfig(enabled: false)),
    );
    expect(TraceSession.current, isNull);
    final answer = await runTool(tester, controller, 'get_trace');
    expect(answer['ok'], isFalse);
    expect(answer['error'], contains('flight recorder is off'));
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  bool recordOnNextBuild = false;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) {
    if (recordOnNextBuild) {
      recordOnNextBuild = false;
      TraceSession.current?.recorder.add('test.build');
    }
    return Text('$count');
  }
}
