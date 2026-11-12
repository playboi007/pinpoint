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
      'level 1 runs; then trace_detail says the slot is taken', (tester) async {
    await pumpApp(tester);
    // What DevTools does when tracking turns on: it asserts the slot is
    // null, then writes it (api-notes item 8).
    expect(debugOnRebuildDirtyWidget, isNull);
    debugOnRebuildDirtyWidget = devTools;

    final on = await toolResult(tester, controller, 'trace_detail', {
      'on': true,
    });
    expect(on['on'], isTrue);
    expect(on['rebuilds'], contains('rebuild slot taken'));
    expect(on['running'], isNot(contains('rebuild')));
    // The other level 3 sources still start.
    expect(on['running'], contains('watch'));
    expect(debugOnRebuildDirtyWidget, same(devTools));
    final detailOn = recorder.lastOf(TraceKind.detailOn)!;
    expect(detailOn.data['reason'], 'rebuild slot taken');

    await toolResult(tester, controller, 'trace_detail', {'on': false});
    // DevTools keeps its slot.
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('a slot DevTools takes while level 3 runs stops the rebuild '
      'source and is left to DevTools', (tester) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    // DevTools turned its tracking off: it clears the slot.
    debugOnRebuildDirtyWidget = null;
    counter.currentState!.increment();
    await tester.pump();
    final lost = recorder.lastOf(TraceKind.detailOff)!;
    expect(lost.data['reason'], 'rebuild slot taken');
    final status = await toolResult(tester, controller, 'trace_detail', {
      'on': false,
    });
    expect(status['on'], isFalse);
    expect(debugOnRebuildDirtyWidget, isNull);
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
